// P5 Inbound Engine: the fast path.
//
// Rules this function exists to keep:
//   1. The submission is written down BEFORE anything that can fail.
//   2. The browser gets its answer in well under a second.
//   3. The acknowledgement goes out afterwards, in the background, so a slow
//      mail server can never make the form look broken.
//   4. Nothing here touches enrichment. An enrichment outage cannot affect
//      the acknowledgement, by construction rather than by error handling.
//
// Public (verify_jwt off): a form page has no login. Admin modes need ?key=.
//
// Replace the SMTP host/credentials with your own provider before deploying.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import nodemailer from "npm:nodemailer@6.9.16";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const PASSWORD = Deno.env.get("SMTP_PASSWORD") ?? "";
const SMTP_HOST = Deno.env.get("SMTP_HOST") ?? "mail.example.com";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...CORS, "Content-Type": "application/json" } });

async function setting(key: string) {
  const { data } = await db.from("inbound_settings").select("value").eq("key", key).maybeSingle();
  return data?.value ?? null;
}

async function sha256(s: string) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 32);
}

// Test mode: only addresses on the allowlist may ever receive mail.
// Shared with the P4 sequencer, so one allowlist governs the whole system.
async function mayEmail(email: string) {
  if ((await setting("test_mode")) !== "on") return true;
  const { data } = await db.from("seq_test_allowlist").select("*");
  const target = email.toLowerCase();
  return (data ?? []).some((row: Record<string, unknown>) =>
    Object.values(row).some((v) => typeof v === "string" && v.toLowerCase() === target));
}

async function sendAck(submissionId: number, email: string, firstName: string | null) {
  const started = new Date().toISOString();
  try {
    if (!PASSWORD) throw new Error("SMTP_PASSWORD secret is not set");
    if (!(await mayEmail(email))) {
      await db.rpc("inbound_log", { p_sub: submissionId, p_step: "ack_send", p_started: started,
        p_outcome: "blocked_test_mode", p_error: null });
      return;
    }
    const from_email = (await setting("ack_from_email")) ?? "you@example.com";
    const from_name = (await setting("ack_from_name")) ?? "Your Name";
    const hello = firstName ? `Hi ${firstName},` : "Hi,";

    await nodemailer
      .createTransport({ host: SMTP_HOST, port: 465, secure: true,
        auth: { user: from_email, pass: PASSWORD } })
      .sendMail({
        from: { name: from_name, address: from_email },
        to: email,
        subject: "Got your message",
        text: `${hello}\n\nThanks for getting in touch. Your message has arrived and someone will come back to you.\n\nIf anything is urgent, just reply to this email.\n\n${from_name}`,
      });
    await db.rpc("inbound_mark_ack", { p_id: submissionId, p_ok: true, p_started: started });
  } catch (e) {
    const err = String((e as any)?.response ?? (e as Error)?.message ?? e).slice(0, 500);
    await db.rpc("inbound_mark_ack", { p_id: submissionId, p_ok: false, p_error: err, p_started: started });
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const url = new URL(req.url);
  const mode = url.searchParams.get("mode");

  // ---- admin modes ----
  if (mode) {
    const adminKey = await setting("admin_key");
    if (!adminKey || url.searchParams.get("key") !== adminKey) return json({ ok: false, error: "forbidden" }, 403);

    if (mode === "check") {
      if (!PASSWORD) return json({ ok: false, error: "SMTP_PASSWORD secret is not set" });
      try {
        const from_email = (await setting("ack_from_email")) ?? "you@example.com";
        await nodemailer.createTransport({ host: SMTP_HOST, port: 465, secure: true,
          auth: { user: from_email, pass: PASSWORD } }).verify();
        return json({ ok: true, smtp: "login ok" });
      } catch (e) { return json({ ok: false, error: String((e as Error).message ?? e).slice(0, 300) }); }
    }

    // The safety net: retries failed acknowledgements, and rescues any that
    // never went out at all (the function died after writing the row).
    if (mode === "sweep_acks") {
      const { data: due, error } = await db.rpc("inbound_due_acks", { p_max: 10 });
      if (error) return json({ ok: false, error: error.message }, 500);
      for (const row of (due ?? []) as any[]) {
        await sendAck(row.submission_id, row.email, row.first_name);
      }
      return json({ ok: true, swept: (due ?? []).length });
    }
    return json({ ok: false, error: "unknown mode" }, 400);
  }

  // ---- the form itself ----
  if (req.method !== "POST") return json({ ok: false, error: "POST only" }, 405);

  let payload: Record<string, unknown> = {};
  try {
    const ct = req.headers.get("content-type") ?? "";
    if (ct.includes("application/json")) payload = await req.json();
    else payload = Object.fromEntries((await req.formData()).entries()) as Record<string, unknown>;
  } catch {
    payload = {};  // an unreadable body is still a submission; the row proves someone tried
  }

  const ip = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ?? "";
  const ipHash = ip ? await sha256(ip + "|p5") : null;   // never store the raw address

  const { data, error } = await db.rpc("inbound_capture", {
    p_payload: payload, p_ip_hash: ipHash,
    p_user_agent: (req.headers.get("user-agent") ?? "").slice(0, 300),
  });

  if (error) return json({ ok: false, error: "could not record submission" }, 500);

  const r = data as any;

  // Answer first, then send. The person is not kept waiting for SMTP.
  if (r.ack_possible) {
    EdgeRuntime.waitUntil(sendAck(r.submission_id, r.email, r.first_name));
  }

  return json({ ok: true, received: true, reference: r.submission_id });
});
