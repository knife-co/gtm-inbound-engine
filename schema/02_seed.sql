-- ============================================================================
-- Seed data. Every threshold lives here as a row, not as a constant in code,
-- so changing the system's behaviour is an UPDATE rather than a deploy.
-- ============================================================================

insert into inbound_settings (key, value, note) values
  ('ack_from_email','you@example.com','sender for the acknowledgement'),
  ('ack_from_name','Your Name','display name'),
  ('ack_max_attempts','5','then dead_letter'),
  ('enrich_max_attempts','4','then score from the form alone'),
  ('fit_threshold','30','tier boundary'),
  ('intent_threshold','30','tier boundary'),
  ('sla_minutes','15','hot lead response target'),
  ('test_mode','on','only addresses on seq_test_allowlist may be emailed'),
  ('unknown_fit_hot_intent','50',
   'When the company is not known, intent must reach this to be hot. 50 = wants to talk to sales AND deciding this quarter.'),
  ('mql_threshold','50','combined score at or above this becomes an MQL'),
  ('mql_engagement_full','40','engagement that counts as fully engaged; one reply reaches it'),
  ('mql_sla_minutes','15','how long the owner has to accept or reject'),
  ('mql_calibration_min_sample','10','never adjust a segment on fewer decisions than this')
on conflict (key) do nothing;

-- What counts as engagement, and how fast it fades.
-- A reply is worth most because it is a person choosing to write back.
insert into engagement_policy (event_type, weight, fresh_days, half_life_days, hard_stop_days, tracked, why) values
  ('replied',            40, 7,  30, 180, true,  'A reply is a person choosing to write back. The strongest thing short of booking.'),
  ('booking_link_click', 35, 3,  14,  90, true,  'Clicked through to book time. Deliberate and specific.'),
  ('form_resubmit',      30, 7,  21, 120, true,  'Came back and filled the form again. Rare and meaningful.'),
  ('form_submit',        20, 7,  21, 120, true,  'The first submission. Real, but everyone in the system has one.'),
  ('link_click',         15, 3,  14,  90, true,  'Clicked a link in an email. Less polluted than opens, not free of bots.'),
  ('email_open',          0, 0,   1,   1, false, 'NOT TRACKED, by decision: Apple Mail Privacy Protection loads the pixel whether or not a human read it, so opens are mostly machines. Kept here as a row so the reason is written down.')
on conflict (event_type) do nothing;

-- Why a lead was rejected. counts_against_fit marks the reasons that should
-- change scoring; the others are routing or contact problems, not fit problems.
insert into mql_reject_reasons (code, label, counts_against_fit, why) values
  ('not_icp',      'Not our kind of company',   true,  'The fit score was wrong. This is the one that should change scoring.'),
  ('wrong_person', 'Not a decision maker',      false, 'Right company, wrong contact. Fit was fine.'),
  ('bad_timing',   'Nothing happening yet',     false, 'Fit fine, intent overstated. Belongs in nurture, not sales.'),
  ('no_budget',    'Cannot afford it',          true,  'Usually a size or segment problem, so it counts against fit.'),
  ('duplicate',    'Already in a conversation', false, 'A routing miss, not a scoring miss.'),
  ('competitor',   'Competitor or recruiter',   false, 'Should have been caught by a gate, not by scoring.'),
  ('junk',         'Not a real enquiry',        false, 'Spam that got past the honeypot.')
on conflict (code) do nothing;

-- A shared queue that is never unavailable. This is what makes
-- "nobody is available" an answer rather than a failure.
insert into inbound_owners (name, email, slack_handle, is_queue, weekdays_only, work_start, work_end)
values ('Inbound queue','inbound-queue@example.com','#inbound',true,false,'00:00','23:59')
on conflict (email) do nothing;
