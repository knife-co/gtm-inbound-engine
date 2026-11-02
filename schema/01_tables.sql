-- ============================================================================
-- P5 Inbound Engine + P6 Nurture: tables
-- ============================================================================
-- Design rule that everything else hangs off: the submission is written down
-- BEFORE anything that can fail. Validation, the acknowledgement email,
-- enrichment, scoring and routing all happen after the row exists, so none of
-- them can lose a lead.
--
-- Depends on tables from earlier projects:
--   dead_letter, free_email_domains, account_enrichment, icp_companies,
--   signals (P3), seq_* (P4)
-- ============================================================================

-- ---------------------------------------------------------------- P5 settings
create table if not exists inbound_settings (
  key   text primary key,
  value text not null,
  note  text
);

-- Owners, their working hours, and the fallback chain. is_queue marks the
-- shared queue, which has no working hours and is never unavailable.
create table if not exists inbound_owners (
  id                bigserial primary key,
  name              text not null,
  email             text not null unique,
  slack_handle      text,
  is_active         boolean not null default true,
  tz                text not null default 'Africa/Lagos',
  work_start        time not null default '09:00',
  work_end          time not null default '18:00',
  weekdays_only     boolean not null default true,
  ooo_until         timestamptz,
  fallback_owner_id bigint references inbound_owners(id),
  is_queue          boolean not null default false,
  last_assigned_at  timestamptz,
  created_at        timestamptz not null default now()
);

create table if not exists inbound_blocklist (
  domain   text primary key,
  kind     text not null check (kind in ('competitor','blocked','partner')),
  note     text,
  added_at timestamptz not null default now()
);

-- raw_payload holds the submission exactly as it arrived, always.
-- is_test: test by default, real only when it came through the public form.
create table if not exists inbound_submissions (
  id           bigserial primary key,
  received_at  timestamptz not null default now(),
  raw_payload  jsonb not null,
  ip_hash      text,
  user_agent   text,
  email        text,
  email_domain text,
  is_test      boolean not null default true,
  status       text not null default 'received'
    check (status in ('received','needs_review','processed','spam','failed')),
  validation_errors jsonb not null default '[]'::jsonb,
  honeypot_hit boolean not null default false,

  ack_status   text not null default 'pending'
    check (ack_status in ('pending','sent','failed','impossible')),
  ack_attempts int not null default 0,
  ack_sent_at  timestamptz,
  ack_next_attempt_at timestamptz,
  ack_error    text,

  enrich_status text not null default 'pending'
    check (enrich_status in ('pending','ok','failed','skipped')),
  enrich_attempts int not null default 0,
  enrich_next_attempt_at timestamptz,
  enrich_error  text,

  processed_at timestamptz
);

create index if not exists inbound_sub_ack_due on inbound_submissions (ack_next_attempt_at) where ack_status = 'failed';
create index if not exists inbound_sub_status  on inbound_submissions (status);
create index if not exists inbound_sub_email   on inbound_submissions (lower(email));
create index if not exists inbound_sub_enrich  on inbound_submissions (enrich_next_attempt_at) where enrich_status in ('pending','failed');
create index if not exists inbound_sub_real    on inbound_submissions (is_test, received_at);

-- fit and intent are stored SEPARATELY and never blended into one column.
-- reason is the decision in plain words, so a rep can see why.
create table if not exists inbound_decisions (
  id            bigserial primary key,
  submission_id bigint not null unique references inbound_submissions(id) on delete cascade,
  fit_score     int not null,
  intent_score  int not null,
  fit_basis     text not null check (fit_basis in ('enriched','form_only')),
  tier          text not null check (tier in ('A','B','C','D','gate')),
  route         text not null,
  reason        text not null,
  owner_id      bigint references inbound_owners(id),
  owner_fallback_reason text,
  sla_due_at    timestamptz,
  decided_at    timestamptz not null default now()
);

-- the timing log: every step, with how long it took
create table if not exists inbound_events (
  id            bigserial primary key,
  submission_id bigint references inbound_submissions(id) on delete cascade,
  step          text not null,
  started_at    timestamptz not null,
  ended_at      timestamptz,
  duration_ms   int,
  outcome       text not null,
  error         text,
  at            timestamptz not null default now()
);

create index if not exists inbound_events_sub on inbound_events (submission_id, at);

create table if not exists inbound_rejections (
  id            bigserial primary key,
  submission_id bigint not null references inbound_submissions(id) on delete cascade,
  reason        text not null,
  rejected_by   text,
  at            timestamptz not null default now()
);

-- ------------------------------------------------------- P6 engagement decay
-- Mirrors P3's signal_decay_policy on purpose, so the system has ONE decay
-- idea rather than two. email_open is kept here at weight 0 and tracked=false
-- so the decision not to trust opens is written down rather than implied.
create table if not exists engagement_policy (
  event_type     text primary key,
  weight         int  not null,
  fresh_days     int  not null,
  half_life_days int  not null,
  hard_stop_days int  not null,
  tracked        boolean not null default true,
  why            text
);

create table if not exists engagement_events (
  id         bigserial primary key,
  email      text not null,
  event_type text not null references engagement_policy(event_type),
  at         timestamptz not null default now(),
  source     text,
  ref        text,
  detail     jsonb
);

create index if not exists engagement_events_email on engagement_events (lower(email), at desc);

-- ------------------------------------------------------------- P6 nurture
-- A nurture track is a P4 seq_campaign with long gaps, so it inherits that
-- project's caps, jitter, suppression list and event log. No second sender.
create table if not exists nurture_tracks (
  id              text primary key,
  name            text not null,
  campaign_id     text not null references seq_campaigns(id),
  min_fit         int  not null default 30,
  max_engagement  int  not null default 30,
  max_days        int  not null default 180,
  active          boolean not null default true,
  created_at      timestamptz not null default now()
);

create table if not exists nurture_members (
  id            bigserial primary key,
  email         text not null,
  track_id      text not null references nurture_tracks(id),
  enrollment_id bigint,
  submission_id bigint references inbound_submissions(id),
  is_test       boolean not null default true,
  enrolled_at   timestamptz not null default now(),
  status        text not null default 'active' check (status in ('active','exited')),
  exit_reason   text,
  exit_detail   text,
  exited_at     timestamptz,
  unique (email, track_id)
);

create index if not exists nurture_members_active on nurture_members (status, track_id);

create table if not exists nurture_exit_log (
  id         bigserial primary key,
  email      text not null,
  track_id   text,
  reason     text not null,
  detail     text,
  at         timestamptz not null default now()
);

-- ------------------------------------------------------- P6 MQL handoff
-- counts_against_fit marks the reasons that should change scoring. "Not a
-- decision maker" means the fit was fine and the contact was wrong, so it
-- must not drag the segment down.
create table if not exists mql_reject_reasons (
  code  text primary key,
  label text not null,
  counts_against_fit boolean not null default false,
  why   text
);

create table if not exists mql_handoffs (
  id             bigserial primary key,
  submission_id  bigint references inbound_submissions(id) on delete cascade,
  email          text not null,
  segment        text,
  fit_score      int not null,
  engagement     int not null,
  combined       int not null,
  owner_id       bigint references inbound_owners(id),
  owner_fallback text,
  is_test        boolean not null default true,
  created_at     timestamptz not null default now(),
  sla_due_at     timestamptz not null,
  status         text not null default 'pending'
                 check (status in ('pending','accepted','rejected','breached')),
  responded_at   timestamptz,
  response_mins  numeric,
  reject_reason  text references mql_reject_reasons(code),
  notes          text
);

create index if not exists mql_pending on mql_handoffs (status, sla_due_at);
create unique index if not exists mql_one_per_submission on mql_handoffs (submission_id)
  where submission_id is not null;

-- ------------------------------------------------------------------ lockdown
-- RLS on with no policies, and every grant to service_role only. Nothing
-- reaches these tables except the server key.
alter table inbound_settings    enable row level security;
alter table inbound_owners      enable row level security;
alter table inbound_blocklist   enable row level security;
alter table inbound_submissions enable row level security;
alter table inbound_decisions   enable row level security;
alter table inbound_events      enable row level security;
alter table inbound_rejections  enable row level security;
alter table engagement_policy   enable row level security;
alter table engagement_events   enable row level security;
alter table nurture_tracks      enable row level security;
alter table nurture_members     enable row level security;
alter table nurture_exit_log    enable row level security;
alter table mql_handoffs        enable row level security;
alter table mql_reject_reasons  enable row level security;

revoke all on inbound_settings, inbound_owners, inbound_blocklist, inbound_submissions,
              inbound_decisions, inbound_events, inbound_rejections,
              engagement_policy, engagement_events,
              nurture_tracks, nurture_members, nurture_exit_log,
              mql_handoffs, mql_reject_reasons from anon, authenticated;

grant all on inbound_settings, inbound_owners, inbound_blocklist, inbound_submissions,
             inbound_decisions, inbound_events, inbound_rejections,
             engagement_policy, engagement_events,
             nurture_tracks, nurture_members, nurture_exit_log,
             mql_handoffs, mql_reject_reasons to service_role;
