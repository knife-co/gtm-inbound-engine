# GTM Inbound Engine

The inbound half of a go-to-market system: a form submission is captured,
scored on two independent axes, routed, handed to a named owner with a clock
on it, and — if sales rejects it — fed back into how the next lead is scored.

Built on Postgres (Supabase) with one Edge Function. Projects **P5** and **P6**
of a longer GTM engineering roadmap; P1–P4 cover outbound sourcing,
enrichment, buying signals and email deliverability.

---

## Status, stated plainly

**This is a portfolio piece, not a live business.** It has never processed a
real submission. Everything mechanical is tested and holds — the gates, the
exit routes, the SLA timer, the decay curve, the refusal guards, the feedback
loop. Everything that counts what real people did is unmeasured, and the
reporting layer says so rather than reporting zero.

Running `p6_metrics('real')` today returns "not measurable" for every rate,
with a sample size of 0. That is deliberate: **an empty funnel is unknown, not
zero per cent.**

---

## The flow

```
form submission
  │
  ├─ inbound_capture()          write the row FIRST, then validate
  │                             acknowledgement sent in the background
  │
  ├─ inbound_decide()           gates → fit score → intent score → tier → owner
  │
  ├─ mql_evaluate()             combined = fit × engagement, calibrated by
  │                             the segment's past accept/reject decisions
  │                             → handoff with a 15-minute clock
  │
  ├─ mql_respond()              owner accepts or rejects, with a reason
  │                             → feeds mql_calibration() → changes the next score
  │
  └─ nurture_enroll()           high fit, low engagement → a slow track that
     nurture_exit_sweep()       seven different things can pull you out of
```

---

## Six decisions worth defending

**1. The submission is written down before anything that can fail.**
Validation, the acknowledgement, enrichment, scoring and routing all happen
after the row exists. A malformed email, an empty request body, a missing
field — all leave a row a human can rescue. The form never returns an error
for bad content, because that just means the person leaves and you have
nothing.

**2. The acknowledgement cannot be delayed by an enrichment outage.**
Not through error handling — through ordering. The capture function never
calls enrichment at all. That happens a minute later, somewhere else. There is
nothing to recover because there is nothing to break.

**3. Fit and intent are scored separately and never blended.**
A perfect-fit company that is just browsing and a badly-fitting company that
wants to buy today land on the same blended score and need opposite treatment.
Two axes keep the routing readable and the reason explainable.

**4. Unknown fit is not low fit.**
When the company could not be looked up, a fit of 15 means "we never checked",
not "we checked and it is poor". An early version routed a maximum-intent lead
to self-serve because its enrichment had failed — a provider outage quietly
downgrading hot leads. Unverified facts still score 0; the routing no longer
pretends we looked.

**5. The combined score multiplies rather than adds.**
`fit × engagement`, so a zero on either axis zeroes the result. Adding would
give a perfect-fit company nobody has heard from a score of 50 — half marks
for existing — and put it in front of a salesperson.

| fit | engagement | multiplied | if we had added |
|----:|-----------:|-----------:|----------------:|
| 50 | 40 | **100** | 100 |
| 50 | 0 | **0** | 50 |
| 0 | 40 | **0** | 50 |

**6. "Nobody is available" is an answer, not a failure.**
The owner picker falls through an available owner → a capped fallback chain →
a shared queue with no working hours → and, failing even that, returns no
owner *with a recorded reason*, so routing still finishes and the gap is
visible rather than silent.

---

## The feedback loop

The part most inbound systems leave out. The owner answers each handoff with
accepted or rejected, and **a rejection must carry a reason** — the reason is
the only thing that feeds the loop. Reasons are classified by whether they
indicate the *fit score* was wrong (`not_icp`, `no_budget`) or something else
entirely (`wrong_person` means the company was fine and the contact was not).

`mql_calibration()` turns those decisions into a per-segment multiplier, with
two safeguards:

- **It refuses to move on a small sample.** A 100% accept rate drawn from two
  leads changes nothing until there are enough decisions to mean something.
  The minimum is a setting, not a constant.
- **The multiplier is clamped to 0.7–1.3**, so no amount of feedback can zero
  or double a segment on its own.

Verified end to end: 15 identically shaped leads were handed over, the owner
accepted 4 and rejected 8, and a 16th lead with *exactly* the same fit,
engagement and answers then scored **54 instead of 70**.

---

## Engagement decay

Intent is what someone said once. Engagement is what they keep doing, and it
fades. The decay shape deliberately mirrors the signal decay in P3, so the
system has one decay idea rather than two.

One link click, scored at seven ages — full value for 3 days, then halving
every 14, zero past the 90-day stop:

| days ago | 0 | 3 | 10 | 17 | 31 | 60 | 95 |
|---|---|---|---|---|---|---|---|
| worth (of 15) | 15 | 15 | 11 | 8 | 4 | 1 | 0 |

**Email opens are deliberately not tracked.** Apple's Mail Privacy Protection
loads the tracking pixel whether or not a human read the message, so a large
share of "opens" are machines. The policy table keeps `email_open` as a row
with weight 0 and `tracked = false`, so the decision is written down in the
system rather than implied by its absence.

---

## Keeping test data out of the reporting

Every submission, handoff and nurture member carries an `is_test` flag: **test
by default, real only by arriving through the public form.** Without it, the
roughly 100 rows generated during testing would be counted as results.

That guard earned itself immediately. The reporting layer's first run reported
a **37.5% unsubscribe rate** marked as "measured" — drawn entirely from a dry
run to the author's own addresses, where the unsubscribe link had been clicked
*on purpose* to test it. The query had no test filter: the exact mistake the
layer existed to prevent, sitting inside the layer. Fixed to count only
campaigns not in test mode.

`p6_metrics('real')` is the honest report. `p6_metrics('test')` runs the
identical queries over test rows, which proves the queries work rather than
that the system is empty.

---

## Layout

```
schema/
  01_tables.sql                      tables, indexes, row level security
  02_seed.sql                        settings, decay policy, rejection reasons
  03_functions_inbound.sql           capture, acknowledgement, owner picker, scoring
  04_functions_engagement_nurture.sql  decay scoring, nurture enrol and exit
  05_functions_mql_metrics.sql       combined score, handoff, feedback loop, reporting
functions/
  inbound-capture/index.ts           the public endpoint (Supabase Edge Function)
form/
  index.html                         a static intake form, no build step
docs/
  DECISIONS.md                       what was tried, changed, and why
  TESTING.md                         every verification run and its result
```

## Setup

1. Run the files in `schema/` in order against a Postgres database. They expect
   a few tables from earlier projects (`dead_letter`, `free_email_domains`,
   `account_enrichment`, `icp_companies`, `signals`, `seq_*`); create stubs or
   remove those references if you are running this standalone.
2. Deploy `functions/inbound-capture` with JWT verification **off** — a form
   has no login. Set `SMTP_HOST` and `SMTP_PASSWORD` as secrets.
3. Edit `inbound_settings` with your own sender address and thresholds.
4. Host `form/index.html` on any static host and replace `YOUR_PROJECT_REF`
   with your project's URL.
5. Leave `test_mode` set to `on` until you mean to email real people.

## Known gaps

- Enrichment is not wired in, so most leads score from the form alone.
- No click endpoint, so two of the five engagement events can never fire.
- Nothing is scheduled; the sweeps run by hand.
- No screen for the owner — accepting or rejecting is a database call.
- The thresholds, weights and clamp band are judgements, not findings.
