# Testing

Every verification run, and what it found. Nothing here is a projection; each
row is something that was executed against the live database.

---

## Hard paths (27 Oct) — 9 of 9

Nine deliberate failure cases, plus a control that had to behave normally.

| # | Scenario | Outcome |
|---|---|---|
| 1 | Good lead, enrichment worked | fit 35 / intent 50 → A, named owner |
| 2 | Enrichment failed 4× then gave up | form_only → A `hot_pending_enrichment` |
| 3 | Malformed email address | row kept, `needs_review`, ack impossible |
| 4 | Completely empty request body | row kept, 6 validation errors listed |
| 5 | Honeypot field filled | `spam` → gate / drop, no email |
| 6 | Consent not ticked | gate / `ack_only` |
| 7 | Personal Gmail address | 0 / 50 → C self-serve |
| 8 | Competitor domain | gate / drop |
| 9 | Owner on leave | A, routed to the shared queue, reason recorded |

**Defect found:** case 2 originally routed to self-serve. A fit of 15 looks
identical whether the company was checked and rejected or never checked at
all, so a provider outage was quietly downgrading hot leads. Rule added:
unknown fit is not low fit.

---

## Latency (28 Oct) — 50 submissions

| | median | 95th percentile | slowest |
|---|---|---|---|
| Capture (database write) | 1 ms | 46 ms | 75 ms |
| Acknowledgement email | 2.44 s | 2.50 s | 2.51 s |

The acknowledgement sample is 5, not 50, because each measurement sends a real
email. Capture was measured from inside the same cloud region with all 50
fired near-simultaneously, so the 95th percentile reflects that burst rather
than real traffic. The browser round trip has never been measured, because the
form has never been hosted.

**0 of 50** acknowledgements reached a non-allowlisted address.

---

## Routing rule change (28 Oct) — all 9 possible answers

A visitor has 3 intent options and 3 timing options, so there are exactly 9
possible answers. Checking all 9 is the complete set, not a sample.

Before: 5 of 9 answers triggered a sales alert when the company was unknown.
After: 1 of 9 — wants to talk to sales **and** deciding this quarter.

The 9 hard-path scenarios were re-run after the change and all still passed.

**A test that was thrown away.** A 30-lead routing-accuracy audit was built and
scrapped before producing a number, for two reasons either of which is
sufficient: the same author wrote both the scoring rules and the test cases,
so agreement would measure self-consistency rather than accuracy; and half of
each lead was invented — real domains with randomly generated job titles and
intent. No routing-accuracy figure is claimed anywhere.

---

## Engagement decay (29 Oct) — 7 ages

One identical link click, scored at seven ages. Full 15 points through day 3,
halving every 14 days after that, zero past the 90-day hard stop.

| days ago | 0 | 3 | 10 | 17 | 31 | 60 | 95 |
|---|---|---|---|---|---|---|---|
| worth now | 15 | 15 | 11 | 8 | 4 | 1 | 0 |

---

## Nurture lifecycle (29 Oct) — 6 gates, 7 exits

**Enrolment**, 6 of 6 refusal paths each returning its own named reason:
suppressed · consent not ticked · already nurtured · fit too low · already
engaged · existing account.

**Exit**, 7 of 7 routes fired correctly in one sweep, with a control that
correctly stayed in: suppressed · replied · company signal fired ·
became engaged · fit dropped · max duration · track completed.

**Two defects found:**

1. The sweep's output columns were named `email`, `reason` and `detail`, which
   collided with real columns of the same name inside the function. It failed
   outright on first run.
2. A reply arriving in the same database transaction as the enrolment has an
   identical timestamp, because `now()` is fixed per transaction. The strict
   "after enrolment" test missed it and the member exited as `became_engaged`
   instead of `replied`. Nobody was wrongly emailed — both exit to a human —
   but the recorded reason is what the reporting counts.

---

## The feedback loop closing (30 Oct)

15 identically shaped leads in the 51–200 segment were handed to the owner,
who accepted 4 and rejected 8 as "not our kind of company". A 16th lead with
exactly the same fit (35), engagement (40) and answers was then submitted.

| | raw score | segment multiplier | scored |
|---|---|---|---|
| Before the feedback | 70 | 1.0 | **70** |
| After 12 decisions | 70 | 0.778 | **54** |

A second segment held 2 decisions, both accepted — a 100% accept rate. The
loop left it at a multiplier of 1.0 and reported "not calibrated: 2 of 10
decisions needed".

Also verified: 2 SLA breaches detected and recorded with how late they were
(7.0 minutes each), and 4 refusal guards — a rejection with no reason, an
already-answered handoff, an unknown rejection reason, and a decision that was
neither accepted nor rejected.

**The decisions in this run were synthetic**, made to exercise the mechanism.
It proves the loop closes. It does not prove anything about that segment.

---

## Reporting layer (31 Oct) — 0 of 6 measurable

| Metric | Real | Test |
|---|---|---|
| MQL volume | 0 — none yet | 19 |
| Sales acceptance rate | not measurable | 0.429 |
| Time to first contact (median) | not measurable | 0.1 min |
| SLA breach rate | not measurable | 0.125 |
| Nurture engagement (average) | not measurable | 0.0 |
| Unsubscribe rate | not measurable | 0.2917 |

**Defect found on the first run:** unsubscribe rate reported **37.5% as
"measured"**, drawn entirely from a dry run to the author's own addresses
where the link had been clicked on purpose. The query had no test filter —
precisely the mistake the layer exists to prevent. Fixed to count only
campaigns that are not in test mode.
