# Decisions

What was chosen, what was rejected, and what was changed after it turned out
to be wrong. Dated, because several of these reverse an earlier call.

---

## Write first, validate second

**Decision.** `inbound_capture()` inserts the raw submission before it looks at
a single field. Validation then collects problems into a list *on that row*
rather than throwing.

**Why.** For a lead form, rejecting bad input is the expensive mistake. A
person who gets an error leaves, and you have nothing. A broken email means
the record is flagged for review and marked impossible to acknowledge — but
the submission still exists and a human can rescue it.

**Rejected alternative.** Validate first and return 400. Cleaner API, worse
business outcome.

The honeypot is the one exception: it returns a normal 200 so the bot learns
nothing, and the row is stored as spam and never processed.

---

## Ordering, not error handling (27 Oct)

**Decision.** The acknowledgement lives in a function that never calls
enrichment. Enrichment runs a minute later, in a different place.

**Why.** An enrichment provider going down cannot delay or prevent a reply,
because the two never touch. There is nothing to recover from, because there
is nothing to break. Retries and dead-lettering exist for enrichment, but they
are not what protects the acknowledgement.

---

## Unknown fit is not low fit (27 Oct, after a test failure)

**What went wrong.** A genuinely good company with maximum stated intent was
routed to self-serve because its enrichment had failed four times. A fit score
of 15 looks identical whether the company was checked and found poor, or never
checked at all. A provider outage was quietly downgrading hot leads.

**Change.** Unverified facts still score 0 — that rule did not move. What
changed is that the *routing* no longer acts as though we looked. High intent
plus unchecked fit now goes to a human with the reason recorded.

---

## Sort on what they said, when we don't know who they are (28 Oct)

**The problem the previous fix created.** Only 6 of 30 sampled domains had any
enrichment data. Fit is unknown for most inbound, so "unknown fit plus real
intent is hot" made nearly every visitor hot. A hot pile containing everyone
is the same as no piles at all.

**Three options considered.**

1. *Trust what they say.* Sort mainly on stated intent when the company is
   unknown, and reserve the alert for the strongest statement a person can
   make. **Chosen** — works today and is honest about what is actually known.
2. *Make "hot" harder to reach in general.* Rejected: guessing more strictly
   is still guessing.
3. *Wire up enrichment so fit becomes real.* The actual fix, and still the
   right answer — but a build day, not a rule change.

Tier B (nurture) cannot apply in the unknown case, because B means "right
company, wrong time" and we do not know the company.

---

## Multiply, don't add (30 Oct)

**Decision.** The combined score is `fit × engagement`, normalised to 0–100.

**Why.** A zero on either axis has to zero the result. Adding lets a strong
score on one axis hide a zero on the other: a perfect-fit company nobody has
heard from would score 50, half marks for existing, and land in front of a
salesperson. So would an enthusiastic contact at a company that fails the ICP.

---

## Reuse the sender, don't build a second one (29 Oct)

**Decision.** A nurture track is a P4 `seq_campaign` with long gaps between
steps.

**Why.** It inherits the per-mailbox caps, the jitter, the suppression list
and the event log that already exist. One opt-out list, not two that can drift
apart — an unsubscribe anywhere blocks nurture everywhere.

---

## A rejection must carry a reason (30 Oct)

**Decision.** `mql_respond()` refuses a rejection with no reason.

**Why.** The reason is the only thing that feeds the calibration. A rejection
without one is a lead that disappears and teaches nothing. Reasons are also
classified by whether they indicate the *fit* was wrong — "not a decision
maker" means the company was fine and the contact was not, so it must not drag
the segment down.

---

## The loop refuses to learn too fast (30 Oct)

**Decision.** `mql_calibration()` leaves a segment at a multiplier of 1.0 until
it has a minimum number of decisions, and clamps the multiplier to 0.7–1.3.

**Why.** A segment with two decisions and a 100% accept rate is noise. A naive
loop would boost it. The clamp means no amount of feedback can zero or double
a segment on its own, which keeps a bad week from permanently distorting the
scoring.

---

## No open tracking (29 Oct)

**Decision.** Email opens are not tracked, and `email_open` is kept in the
policy table at weight 0 with `tracked = false`.

**Why.** Apple's Mail Privacy Protection loads the tracking pixel whether or
not a human read the message, and corporate scanners do the same. A large
share of "opens" are machines. Keeping the row rather than deleting it means
the decision is written down in the system instead of implied by its absence.

**Cost, acknowledged.** Without clicks either, engagement runs on replies and
form submissions only — clean but sparse. Most people sit at the same score
and the engagement axis sorts nobody. Adding click tracking is the open
question; clicks are far more honest than opens, but it is still tracking.

---

## Test by default, real by exception (31 Oct)

**Decision.** Every submission, handoff and nurture member carries `is_test`,
defaulting to true. Real means: arrived through the public form, with no test
batch tag.

**Why.** Roughly 100 test rows lived in the same tables as anything real would.
Any reporting written on top would have counted them and produced confident,
meaningless numbers that looked exactly like results. Test-by-default is the
safe way round: forgetting to mark something produces an undercount, not a
fabrication.

**It earned itself immediately.** See TESTING.md — the reporting layer's first
run reported a 37.5% unsubscribe rate drawn entirely from a dry run.

---

## A rate with nothing behind it is NULL (31 Oct)

**Decision.** Every rate in `p6_metrics()` returns NULL and the verdict "not
measurable" when the sample is zero. None of them returns 0.

**Why.** An empty funnel is unknown, not zero per cent. Reporting 0% invites
someone to read it as a measured result and act on it. The same rule applies
to the empty Postmaster Tools dashboard in P4.

---

## The intake form, built and then dropped (30 Oct)

**What happened.** A public intake form was written, framed as intake for GTM
consulting work. It was abandoned the same day.

**Why.** That framing assumes a service being sold and clients being sought.
The goal is a GTM Engineer role, not a consulting practice, so the form would
have meant advertising something that was not on offer.

**Consequence, accepted.** Without real submissions, every metric that counts
what a real person did is unmeasurable. Those metrics are dropped rather than
simulated, and the reporting layer reports their absence rather than a number.
The form is kept in `form/` because the code is sound and the decision was
about positioning, not quality.

**A finding worth keeping.** Supabase Edge Functions cannot serve the page:
the gateway returns `text/plain` whatever `Content-Type` the function sets,
confirmed with a throwaway probe testing both a plain object header and a
`Headers` object. The browser shows the source instead of the page. The form
needs an ordinary static host.
