-- ============================================================================
-- P5 Inbound Engine: capture, acknowledgement, owner routing, scoring
-- ============================================================================

-- The timing log helper. Every step records how long it took.
create or replace function inbound_log(p_sub bigint, p_step text, p_started timestamptz,
                                       p_outcome text, p_error text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into inbound_events (submission_id, step, started_at, ended_at, duration_ms, outcome, error)
  values (p_sub, p_step, p_started, clock_timestamp(),
          greatest(0, (extract(epoch from (clock_timestamp() - p_started)) * 1000)::int),
          p_outcome, p_error);
end $$;

-- CAPTURE.
-- The insert happens first and unconditionally. Bad data is RECORDED, never
-- rejected: a malformed or empty form still leaves a row a human can rescue.
-- The only thing treated differently is the honeypot, which returns a normal
-- 200 so the bot learns nothing.
create or replace function inbound_capture(p_payload jsonb, p_ip_hash text default null,
                                           p_user_agent text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id bigint; v_email text; v_domain text;
  v_errors jsonb := '[]'::jsonb;
  v_honeypot boolean := false;
  v_status text := 'received';
  v_ack_possible boolean := false;
  v_is_test boolean;
  v_started timestamptz := clock_timestamp();
begin
  -- test by default, real only by arriving through the public form
  v_is_test := (p_payload ? 'batch')
            or (coalesce(p_payload->>'source','') is distinct from 'public_form');

  -- 1. write it down. nothing below this line can lose the lead.
  insert into inbound_submissions (raw_payload, ip_hash, user_agent, is_test)
  values (coalesce(p_payload, '{}'::jsonb), p_ip_hash, p_user_agent, v_is_test)
  returning id into v_id;

  -- 2. honeypot: a hidden field no human ever sees
  if coalesce(trim(p_payload->>'company_website'), '') <> '' then
    v_honeypot := true; v_status := 'spam';
  end if;

  -- 3. the email is the only field that decides whether we can reply at all
  v_email := lower(nullif(trim(p_payload->>'email'), ''));
  if v_email is null then
    v_errors := v_errors || '["email_missing"]'::jsonb;
  elsif v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    v_errors := v_errors || '["email_malformed"]'::jsonb;
  else
    v_domain := split_part(v_email, '@', 2);
  end if;

  -- 4. everything else: noted as a problem, never a reason to throw the lead away
  if coalesce(trim(p_payload->>'full_name'), '')    = '' then v_errors := v_errors || '["name_missing"]'::jsonb;   end if;
  if coalesce(trim(p_payload->>'job_title'), '')    = '' then v_errors := v_errors || '["title_missing"]'::jsonb;  end if;
  if coalesce(trim(p_payload->>'company_size'), '') = '' then v_errors := v_errors || '["size_missing"]'::jsonb;   end if;
  if coalesce(trim(p_payload->>'intent'), '')       = '' then v_errors := v_errors || '["intent_missing"]'::jsonb; end if;
  if lower(coalesce(p_payload->>'consent','')) not in ('true','on','yes','1') then
    v_errors := v_errors || '["no_consent"]'::jsonb;
  end if;

  -- an unusable email means a human has to look, not that the lead disappears
  if not v_honeypot and v_domain is null then v_status := 'needs_review'; end if;
  v_ack_possible := (not v_honeypot) and v_domain is not null;

  update inbound_submissions
     set email = v_email, email_domain = v_domain,
         validation_errors = v_errors, honeypot_hit = v_honeypot, status = v_status,
         ack_status = case when v_ack_possible then 'pending' else 'impossible' end
   where id = v_id;

  perform inbound_log(v_id, 'capture', v_started,
    case when v_honeypot then 'spam'
         when jsonb_array_length(v_errors) > 0 then 'accepted_with_errors'
         else 'accepted' end,
    nullif(v_errors::text, '[]'));

  return jsonb_build_object(
    'submission_id', v_id,
    'ack_possible',  v_ack_possible,
    'is_test',       v_is_test,
    'email',         v_email,
    'first_name',    nullif(split_part(coalesce(trim(p_payload->>'full_name'),''), ' ', 1), ''),
    'spam',          v_honeypot,
    'errors',        v_errors);
end $$;

-- Acknowledgement outcome: widening backoff (3, 9, 27... minutes), then a
-- dead letter when we finally give up.
create or replace function inbound_mark_ack(p_id bigint, p_ok boolean, p_error text default null,
                                            p_started timestamptz default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_attempts int; v_max int;
begin
  select coalesce((select value::int from inbound_settings where key = 'ack_max_attempts'), 5) into v_max;
  if p_ok then
    update inbound_submissions
       set ack_status = 'sent', ack_sent_at = now(), ack_attempts = ack_attempts + 1,
           ack_next_attempt_at = null, ack_error = null
     where id = p_id;
    perform inbound_log(p_id, 'ack_send', coalesce(p_started, clock_timestamp()), 'sent');
  else
    update inbound_submissions
       set ack_status = 'failed', ack_attempts = ack_attempts + 1, ack_error = p_error,
           ack_next_attempt_at = case when ack_attempts + 1 >= v_max then null
                                      else now() + ((power(3, ack_attempts + 1))::int || ' minutes')::interval end
     where id = p_id
    returning ack_attempts into v_attempts;
    perform inbound_log(p_id, 'ack_send', coalesce(p_started, clock_timestamp()), 'failed', p_error);
    if v_attempts >= v_max then
      insert into dead_letter (node, error, payload, status, attempts, max_attempts, provider)
      values ('p5_inbound_ack', p_error, jsonb_build_object('submission_id', p_id),
              'gave_up', v_attempts, v_max, 'smtp');
    end if;
  end if;
end $$;

-- The safety net. Retries failed acknowledgements AND rescues any that never
-- went out at all, which covers the case where the capture function died after
-- writing the row but before sending.
create or replace function inbound_due_acks(p_max int default 10)
returns table(submission_id bigint, email text, first_name text)
language sql security definer set search_path = public as $$
  select s.id, s.email,
         nullif(split_part(coalesce(trim(s.raw_payload->>'full_name'),''), ' ', 1), '')
  from inbound_submissions s
  where (s.ack_status = 'failed' and s.ack_next_attempt_at is not null and s.ack_next_attempt_at <= now())
     or (s.ack_status = 'pending' and s.email is not null and s.received_at < now() - interval '2 minutes')
  order by s.received_at
  limit p_max;
$$;

-- OWNER PICKER.
-- Always returns something. "Nobody is available" is an answer, not a failure,
-- and the reason is always recorded so a slow lead has a traceable cause.
create or replace function inbound_pick_owner()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_try bigint; v_hop int := 0;
begin
  -- 1. an available owner, round robin by who was assigned longest ago
  select o.id into v_id
  from inbound_owners o
  where o.is_active and not o.is_queue
    and (o.ooo_until is null or o.ooo_until <= now())
    and (not o.weekdays_only or extract(isodow from (now() at time zone o.tz)) <= 5)
    and (now() at time zone o.tz)::time between o.work_start and o.work_end
  order by o.last_assigned_at nulls first, o.id
  limit 1;

  if v_id is not null then
    update inbound_owners set last_assigned_at = now() where id = v_id;
    return jsonb_build_object('owner_id', v_id, 'fallback_reason', null);
  end if;

  -- 2. walk the named fallback chain, capped so a loop cannot hang it
  select o.id into v_try from inbound_owners o
   where o.is_active and not o.is_queue order by o.last_assigned_at nulls first, o.id limit 1;

  while v_try is not null and v_hop < 5 loop
    select o.fallback_owner_id into v_try from inbound_owners o where o.id = v_try;
    v_hop := v_hop + 1;
    if v_try is not null then
      select o.id into v_id from inbound_owners o
       where o.id = v_try and o.is_active and (o.ooo_until is null or o.ooo_until <= now());
      if v_id is not null then
        update inbound_owners set last_assigned_at = now() where id = v_id;
        return jsonb_build_object('owner_id', v_id, 'fallback_reason', 'primary_unavailable_used_fallback');
      end if;
    end if;
  end loop;

  -- 3. the shared queue. Never unavailable, which is the whole point of it.
  select o.id into v_id from inbound_owners o where o.is_queue and o.is_active limit 1;
  if v_id is not null then
    return jsonb_build_object('owner_id', v_id, 'fallback_reason', 'all_owners_unavailable_sent_to_queue');
  end if;

  -- 4. nothing configured at all. Still return, so routing finishes and the
  --    gap is visible rather than silent.
  return jsonb_build_object('owner_id', null, 'fallback_reason', 'no_owner_configured');
end $$;

-- Enrichment outcome: widening backoff (4, 16, 64 minutes), then give up
-- gracefully. Routing never waits for this.
create or replace function inbound_mark_enrich(p_id bigint, p_ok boolean, p_error text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_attempts int; v_max int;
begin
  select coalesce((select value::int from inbound_settings where key = 'enrich_max_attempts'), 4) into v_max;
  if p_ok then
    update inbound_submissions set enrich_status = 'ok', enrich_attempts = enrich_attempts + 1,
           enrich_next_attempt_at = null, enrich_error = null where id = p_id;
  else
    update inbound_submissions
       set enrich_status = 'failed', enrich_attempts = enrich_attempts + 1, enrich_error = p_error,
           enrich_next_attempt_at = case when enrich_attempts + 1 >= v_max then null
                                         else now() + ((power(4, enrich_attempts + 1))::int || ' minutes')::interval end
     where id = p_id
    returning enrich_attempts into v_attempts;
    if v_attempts >= v_max then
      insert into dead_letter (node, error, payload, status, attempts, max_attempts, provider)
      values ('p5_inbound_enrich', p_error, jsonb_build_object('submission_id', p_id),
              'gave_up', v_attempts, v_max, 'waterfall');
    end if;
  end if;
end $$;

create or replace function inbound_due_processing(p_max int default 20)
returns table(submission_id bigint, email text, email_domain text, enrich_status text)
language sql security definer set search_path = public as $$
  select s.id, s.email, s.email_domain, s.enrich_status
  from inbound_submissions s
  where s.status = 'received' and s.email_domain is not null
    and (s.enrich_next_attempt_at is null or s.enrich_next_attempt_at <= now())
  order by s.received_at
  limit p_max;
$$;

-- DECIDE.
-- Runs whether or not enrichment worked; fit_basis records which it was.
--
-- Two rules worth knowing before reading the code:
--
--   A GATE IS NOT A LOW SCORE. No consent, a competitor domain or a honeypot
--   hit stops the lead outright rather than scoring it badly.
--
--   UNKNOWN FIT IS NOT LOW FIT. When the company could not be looked up, a fit
--   of 15 means "we never checked", not "we checked and it is poor". Those need
--   opposite treatment, so the unknown case is sorted on stated intent alone,
--   with the sales alert reserved for the strongest thing a person can say.
--   Tier B (nurture) cannot apply there: B means "right company, wrong time",
--   and we do not know the company.
create or replace function inbound_decide(p_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  s record; v_fit int := 0; v_intent int := 0; v_basis text; v_tier text; v_route text;
  v_reason text := ''; v_owner jsonb := '{}'::jsonb; v_sla timestamptz;
  v_size text; v_intent_pick text; v_timing text;
  v_free boolean := false; v_blocked text; v_signal boolean := false;
  v_enr record; v_existing_sf text; v_started timestamptz := clock_timestamp();
  v_hot_bar int;
begin
  select * into s from inbound_submissions where id = p_id;
  if not found then return jsonb_build_object('error','no_such_submission'); end if;

  select coalesce((select value::int from inbound_settings where key = 'unknown_fit_hot_intent'), 50)
    into v_hot_bar;

  -- gates first
  if s.honeypot_hit then
    v_tier := 'gate'; v_route := 'drop'; v_reason := 'Honeypot field filled: bot.';
  elsif s.email_domain is null then
    perform inbound_log(p_id, 'decide', v_started, 'skipped_needs_review');
    return jsonb_build_object('submission_id', p_id, 'tier', null, 'route', 'needs_review');
  else
    select kind into v_blocked from inbound_blocklist where domain = s.email_domain;
    if v_blocked in ('competitor','blocked') then
      v_tier := 'gate'; v_route := 'drop'; v_reason := 'Domain on the ' || v_blocked || ' list.';
    elsif s.validation_errors ? 'no_consent' then
      v_tier := 'gate'; v_route := 'ack_only';
      v_reason := 'No consent ticked: acknowledgement only, no further contact.';
    end if;
  end if;

  if v_tier is null then
    v_basis := case when s.enrich_status = 'ok' then 'enriched' else 'form_only' end;
    select exists(select 1 from free_email_domains f where f.domain = s.email_domain) into v_free;

    -- FIT, from the form: always available
    v_size := s.raw_payload->>'company_size';
    if v_size in ('11-50','51-200','201-500','501-1000') then
      v_fit := v_fit + 15; v_reason := v_reason || 'Size in range (+15). ';
    else
      v_reason := v_reason || 'Size out of range or missing (+0). ';
    end if;

    -- FIT, from P3: a live hiring signal on this domain. Independent of
    -- enrichment, so an enrichment outage never costs us this.
    select exists(select 1 from signals g
                   where g.domain = s.email_domain
                     and (g.expires_at is null or g.expires_at > now())) into v_signal;
    if v_signal then v_fit := v_fit + 15; v_reason := v_reason || 'Live hiring signal (+15). '; end if;

    -- FIT, enrichment-only points
    if v_basis = 'enriched' and not v_free then
      select * into v_enr from account_enrichment where domain = s.email_domain limit 1;
      if v_enr.industry_sf is not null then
        v_fit := v_fit + 10; v_reason := v_reason || 'Industry known (+10). ';
      end if;
      if v_enr.employee_count is not null then
        v_fit := v_fit + 10; v_reason := v_reason || 'Headcount confirmed (+10). ';
      end if;
    else
      v_reason := v_reason || 'Company not looked up yet (max fit 30). ';
    end if;

    if v_free then v_reason := v_reason || 'Personal email domain. '; end if;

    -- INTENT, entirely from what they typed
    v_intent_pick := s.raw_payload->>'intent';
    v_intent := v_intent + case v_intent_pick
                             when 'talk_to_sales' then 30 when 'pricing' then 20
                             when 'researching' then 5 else 0 end;
    v_timing := s.raw_payload->>'timing';
    v_intent := v_intent + case v_timing
                             when 'this_quarter' then 20 when 'six_months' then 10 else 0 end;
    v_reason := v_reason || 'Intent: ' || coalesce(v_intent_pick,'none') || '/' ||
                coalesce(v_timing,'none') || ' (' || v_intent || '). ';

    select sf_account_id into v_existing_sf from icp_companies
     where domain = s.email_domain and sf_account_id is not null limit 1;

    if v_existing_sf is not null then
      v_tier := 'A'; v_route := 'existing_account_owner';
      v_reason := v_reason || 'Already a CRM account: routed to its owner.';

    -- a personal address IS a checked fact, so low fit here is real
    elsif v_free and v_fit < 30 then
      v_tier := case when v_intent >= 30 then 'C' else 'D' end;
      v_route := case when v_intent >= 30 then 'self_serve' else 'resource_email' end;
      v_reason := v_reason || 'No company behind the address, so sorted on intent alone.';

    -- we KNOW the company: the two-axis grid
    elsif v_basis = 'enriched' then
      if    v_fit >= 30 and v_intent >= 30 then v_tier := 'A'; v_route := 'hot_alert_booking_link';
      elsif v_fit >= 30                    then v_tier := 'B'; v_route := 'nurture_watch_for_signal';
      elsif v_intent >= 30                 then v_tier := 'C'; v_route := 'self_serve';
      else                                      v_tier := 'D'; v_route := 'resource_email';
      end if;

    -- we DO NOT know the company: sort on what they said
    else
      if v_intent >= v_hot_bar then
        v_tier := 'A'; v_route := 'hot_pending_enrichment';
        v_reason := v_reason || 'Strongest stated intent (' || v_intent || ' of 50) and company not yet known: '
                    || 'treated as hot, and flagged so the company is looked up before the call.';
      elsif v_intent >= 30 then
        v_tier := 'C'; v_route := 'self_serve';
        v_reason := v_reason || 'Real intent but not the strongest, and company unknown: booking link, no alert.';
      else
        v_tier := 'D'; v_route := 'resource_email';
        v_reason := v_reason || 'Low stated intent and company unknown.';
      end if;
    end if;
  end if;

  if v_tier = 'A' then
    v_owner := inbound_pick_owner();
    v_sla := now() + interval '15 minutes';
    if v_owner->>'fallback_reason' is not null then
      v_reason := v_reason || ' Owner: ' || (v_owner->>'fallback_reason') || '.';
    end if;
  end if;

  insert into inbound_decisions (submission_id, fit_score, intent_score, fit_basis, tier, route,
                                 reason, owner_id, owner_fallback_reason, sla_due_at)
  values (p_id, v_fit, v_intent, coalesce(v_basis,'form_only'), v_tier, v_route,
          trim(v_reason), nullif(v_owner->>'owner_id','')::bigint, v_owner->>'fallback_reason', v_sla)
  on conflict (submission_id) do update
    set fit_score = excluded.fit_score, intent_score = excluded.intent_score,
        fit_basis = excluded.fit_basis, tier = excluded.tier, route = excluded.route,
        reason = excluded.reason, owner_id = excluded.owner_id,
        owner_fallback_reason = excluded.owner_fallback_reason,
        sla_due_at = excluded.sla_due_at, decided_at = now();

  update inbound_submissions set status = 'processed', processed_at = now() where id = p_id;
  perform inbound_log(p_id, 'decide', v_started, v_tier || '/' || v_route);

  return jsonb_build_object('submission_id', p_id, 'fit', v_fit, 'intent', v_intent,
                            'basis', coalesce(v_basis,'form_only'), 'tier', v_tier,
                            'route', v_route, 'owner', v_owner, 'reason', trim(v_reason));
end $$;

revoke all on function
  inbound_log(bigint,text,timestamptz,text,text),
  inbound_capture(jsonb,text,text),
  inbound_mark_ack(bigint,boolean,text,timestamptz),
  inbound_due_acks(int),
  inbound_pick_owner(),
  inbound_decide(bigint),
  inbound_mark_enrich(bigint,boolean,text),
  inbound_due_processing(int)
from anon, authenticated;

grant execute on function
  inbound_log(bigint,text,timestamptz,text,text),
  inbound_capture(jsonb,text,text),
  inbound_mark_ack(bigint,boolean,text,timestamptz),
  inbound_due_acks(int),
  inbound_pick_owner(),
  inbound_decide(bigint),
  inbound_mark_enrich(bigint,boolean,text),
  inbound_due_processing(int)
to service_role;
