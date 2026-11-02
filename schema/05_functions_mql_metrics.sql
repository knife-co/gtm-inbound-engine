-- ============================================================================
-- P6: combined score, MQL handoff with an SLA, the feedback loop, reporting
-- ============================================================================

-- COMBINED SCORE = fit MULTIPLIED by engagement, not added.
--
-- Multiplying means a zero on either axis zeroes the result, which is what the
-- fit x engagement grid asks for. Adding lets a strong score on one axis hide a
-- zero on the other:
--
--   fit 50, engagement 0  -> multiplied 0,  added would be 50
--   fit 0,  engagement 40 -> multiplied 0,  added would be 50
--
-- A perfect-fit company nobody has heard a word from is not an MQL, and an
-- enthusiastic contact at a company that fails the ICP is not one either.
-- Adding would have put both in front of a salesperson.
create or replace function combined_score(p_fit int, p_engagement int)
returns int language sql immutable as $$
  select greatest(0, least(100, round(
    100.0
    * (least(greatest(coalesce(p_fit,0),0),50)::numeric / 50)
    * least(1.0, least(greatest(coalesce(p_engagement,0),0),100)::numeric
            / greatest(1, coalesce((select value::int from inbound_settings where key='mql_engagement_full'), 40)))
  )::int));
$$;

-- CALIBRATION: the feedback loop, read back.
--
-- What each segment's past accept/reject decisions say about its scoring.
-- Two safeguards that are the point of the whole thing:
--   1. It REFUSES to move on a small sample. A 100% accept rate drawn from two
--      leads changes nothing until there are enough decisions to mean anything.
--   2. The multiplier is clamped to 0.7-1.3, so no amount of feedback can zero
--      or double a segment on its own.
create or replace function mql_calibration()
returns table(segment text, decided int, accepted int, accept_rate numeric,
              multiplier numeric, calibrated boolean, note text)
language plpgsql stable security definer set search_path = public as $$
declare v_min int; v_overall numeric;
begin
  select coalesce((select value::int from inbound_settings where key='mql_calibration_min_sample'), 10)
    into v_min;

  select case when count(*) = 0 then null
              else count(*) filter (where status='accepted')::numeric / count(*) end
    into v_overall
  from mql_handoffs where status in ('accepted','rejected');

  return query
  with per as (
    select h.segment as seg,
           count(*)::int as dec_n,
           count(*) filter (where h.status='accepted')::int as acc_n
    from mql_handoffs h
    where h.status in ('accepted','rejected')
    group by h.segment
  )
  select p.seg,
         p.dec_n,
         p.acc_n,
         round(p.acc_n::numeric / p.dec_n, 3),
         case when p.dec_n < v_min then 1.0
              else round(greatest(0.7, least(1.3,
                   (p.acc_n::numeric / p.dec_n) / nullif(v_overall, 0))), 3)
         end,
         p.dec_n >= v_min,
         case when p.dec_n < v_min
              then 'not calibrated: ' || p.dec_n || ' of ' || v_min || ' decisions needed'
              else 'calibrated on ' || p.dec_n || ' decisions'
         end
  from per p
  order by p.dec_n desc;
end $$;

-- HANDOFF. Evaluate a submission and raise an MQL if it clears the bar,
-- with the segment's calibration applied to the score first.
create or replace function mql_evaluate(p_submission bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  d record; s record; v_eng int; v_combined int; v_thresh int; v_sla int;
  v_owner jsonb; v_id bigint; v_mult numeric; v_adj int; v_seg text;
begin
  select * into d from inbound_decisions where submission_id = p_submission;
  if not found then return jsonb_build_object('mql', false, 'reason', 'not_scored_yet'); end if;
  select * into s from inbound_submissions where id = p_submission;

  if d.tier = 'gate' then
    return jsonb_build_object('mql', false, 'reason', 'stopped_by_a_gate');
  end if;

  v_seg      := coalesce(s.raw_payload->>'company_size', 'unknown');
  v_eng      := engagement_score(s.email);
  v_combined := combined_score(d.fit_score, v_eng);

  -- the feedback loop, applied
  select multiplier into v_mult from mql_calibration() where segment = v_seg;
  v_mult := coalesce(v_mult, 1.0);
  v_adj  := least(100, round(v_combined * v_mult)::int);

  select coalesce((select value::int from inbound_settings where key='mql_threshold'), 50) into v_thresh;

  if v_adj < v_thresh then
    return jsonb_build_object('mql', false, 'reason', 'below_threshold',
      'fit', d.fit_score, 'engagement', v_eng, 'combined', v_combined,
      'segment_multiplier', v_mult, 'adjusted', v_adj, 'threshold', v_thresh);
  end if;

  if exists (select 1 from mql_handoffs h where h.submission_id = p_submission) then
    return jsonb_build_object('mql', false, 'reason', 'already_handed_off');
  end if;

  select coalesce((select value::int from inbound_settings where key='mql_sla_minutes'), 15) into v_sla;
  v_owner := inbound_pick_owner();

  insert into mql_handoffs (submission_id, email, segment, fit_score, engagement, combined,
                            owner_id, owner_fallback, sla_due_at)
  values (p_submission, s.email, v_seg, d.fit_score, v_eng, v_adj,
          nullif(v_owner->>'owner_id','')::bigint, v_owner->>'fallback_reason',
          now() + (v_sla || ' minutes')::interval)
  returning id into v_id;

  return jsonb_build_object('mql', true, 'handoff_id', v_id, 'email', s.email,
    'fit', d.fit_score, 'engagement', v_eng, 'combined', v_combined,
    'segment', v_seg, 'segment_multiplier', v_mult, 'adjusted', v_adj,
    'owner', v_owner, 'sla_minutes', v_sla);
end $$;

-- THE SLA TIMER. Anything unanswered when its clock runs out is a breach.
-- A breach is recorded, not quietly cleared, because time-to-first-response is
-- the number marketing and sales actually argue about.
create or replace function mql_sla_sweep()
returns table(handoff_id bigint, email text, minutes_late numeric)
language sql security definer set search_path = public as $$
  with late as (
    update mql_handoffs h
       set status = 'breached'
     where h.status = 'pending' and h.sla_due_at < now()
    returning h.id, h.email, extract(epoch from (now() - h.sla_due_at))/60 as mins
  )
  select id, email, round(mins::numeric, 1) from late;
$$;

-- THE FEEDBACK LOOP. The owner says yes or no, and why.
-- A rejection with no reason is refused outright: the reason is the only thing
-- that feeds the loop.
create or replace function mql_respond(p_handoff bigint, p_decision text,
                                       p_reason text default null, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare h record;
begin
  if p_decision not in ('accepted','rejected') then
    return jsonb_build_object('ok', false, 'error', 'decision must be accepted or rejected');
  end if;
  select * into h from mql_handoffs where id = p_handoff;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_such_handoff'); end if;
  if h.status in ('accepted','rejected') then
    return jsonb_build_object('ok', false, 'error', 'already_answered', 'was', h.status);
  end if;
  if p_decision = 'rejected' and p_reason is null then
    return jsonb_build_object('ok', false, 'error', 'a rejection needs a reason, that is the whole point');
  end if;
  if p_reason is not null and not exists (select 1 from mql_reject_reasons r where r.code = p_reason) then
    return jsonb_build_object('ok', false, 'error', 'unknown_reason', 'allowed',
      (select jsonb_agg(code order by code) from mql_reject_reasons));
  end if;

  update mql_handoffs
     set status = p_decision, responded_at = now(),
         response_mins = round((extract(epoch from (now() - created_at))/60)::numeric, 1),
         reject_reason = p_reason, notes = p_notes
   where id = p_handoff;

  -- junk and competitor rejections also suppress the address, so the same
  -- person cannot be emailed again from anywhere in the system
  if p_decision = 'rejected' and p_reason in ('junk','competitor') then
    insert into seq_suppression (email, reason, source, detail)
    values (h.email, 'manual', 'mql_reject', p_reason)
    on conflict do nothing;
  end if;

  return jsonb_build_object('ok', true, 'handoff_id', p_handoff, 'decision', p_decision,
    'reason', p_reason, 'answered_in_minutes',
    (select response_mins from mql_handoffs where id = p_handoff));
end $$;

-- REPORTING.
-- Two rules this is built around:
--   1. A rate with nothing behind it is NULL and says "not measurable", never
--      0. An empty funnel is unknown, not zero per cent.
--   2. Test data and real data are counted separately and never summed.
--      p6_metrics('real') is the honest report; p6_metrics('test') runs the
--      identical queries over test rows, proving the queries work rather than
--      that the system is empty.
create or replace function p6_metrics(p_scope text default 'real')
returns table(metric text, value numeric, unit text, sample int, verdict text, note text)
language plpgsql stable security definer set search_path = public as $$
declare v_test boolean;
begin
  if p_scope not in ('real','test') then
    raise exception 'scope must be real or test';
  end if;
  v_test := (p_scope = 'test');

  return query
  select 'MQL volume'::text, count(*)::numeric, 'leads'::text, count(*)::int,
         case when count(*) = 0 then 'none yet' else 'measured' end,
         case when count(*) = 0 then 'No ' || p_scope || ' submission has cleared the threshold.'
              else count(*) || ' handed to an owner' end
  from mql_handoffs h where h.is_test = v_test;

  return query
  with d as (
    select count(*) filter (where h.status = 'accepted') as acc,
           count(*) filter (where h.status in ('accepted','rejected')) as dec_n
    from mql_handoffs h where h.is_test = v_test
  )
  select 'Sales acceptance rate'::text,
         case when d.dec_n = 0 then null else round(d.acc::numeric / d.dec_n, 3) end,
         'of decided'::text, d.dec_n::int,
         case when d.dec_n = 0 then 'not measurable' else 'measured' end,
         case when d.dec_n = 0
              then 'No owner has accepted or rejected a ' || p_scope || ' lead. Not 0%, unknown.'
              else d.acc || ' accepted of ' || d.dec_n || ' decided' end
  from d;

  return query
  with t as (
    select percentile_cont(0.5) within group (order by h.response_mins) as med, count(*) as n
    from mql_handoffs h where h.is_test = v_test and h.response_mins is not null
  )
  select 'Time to first contact (median)'::text,
         case when t.n = 0 then null else round(t.med::numeric, 1) end,
         'minutes'::text, t.n::int,
         case when t.n = 0 then 'not measurable' else 'measured' end,
         case when t.n = 0 then 'Nobody has responded to a ' || p_scope || ' handoff yet.'
              else 'median across ' || t.n || ' answered handoffs' end
  from t;

  return query
  with b as (
    select count(*) filter (where h.status = 'breached') as br,
           count(*) filter (where h.status in ('accepted','rejected','breached')) as fin
    from mql_handoffs h where h.is_test = v_test
  )
  select 'SLA breach rate'::text,
         case when b.fin = 0 then null else round(b.br::numeric / b.fin, 3) end,
         'of finished'::text, b.fin::int,
         case when b.fin = 0 then 'not measurable' else 'measured' end,
         case when b.fin = 0 then 'No ' || p_scope || ' handoff has finished yet.'
              else b.br || ' ran out of time of ' || b.fin end
  from b;

  return query
  with n as (
    select count(*) as members, avg(engagement_score(m.email)) as avg_eng
    from nurture_members m where m.is_test = v_test and m.status = 'active'
  )
  select 'Nurture engagement (average)'::text,
         case when n.members = 0 then null else round(n.avg_eng::numeric, 1) end,
         'points of 100'::text, n.members::int,
         case when n.members = 0 then 'not measurable' else 'measured' end,
         case when n.members = 0 then 'Nobody ' || p_scope || ' is in a nurture track.'
              else 'across ' || n.members || ' people still being nurtured' end
  from n;

  -- Only campaigns NOT in test mode count toward a real unsubscribe rate.
  -- Without this filter the first run reported 37.5%, drawn entirely from a
  -- dry run to our own addresses where the link was clicked on purpose.
  return query
  with sent as (
    select count(*) as n
    from seq_events e
    join seq_campaigns c on c.id = e.campaign_id
    where e.event_type = 'sent' and c.test_mode = v_test
  ),
  unsub as (
    select count(distinct p.email) as n
    from seq_suppression p
    where p.reason = 'unsubscribe'
      and exists (
        select 1 from seq_enrollments en
        join seq_contacts ct on ct.id = en.contact_id
        join seq_campaigns c2 on c2.id = en.campaign_id
        where lower(ct.email) = lower(p.email) and c2.test_mode = v_test)
  )
  select 'Unsubscribe rate'::text,
         case when sent.n = 0 then null else round(unsub.n::numeric / sent.n, 4) end,
         'of emails sent'::text, sent.n::int,
         case when sent.n = 0 then 'not measurable' else 'measured' end,
         case when sent.n = 0
              then 'No email has been sent from a campaign that is not in test mode.'
              else unsub.n || ' unsubscribes against ' || sent.n || ' emails' end
  from sent, unsub;
end $$;

revoke all on function
  combined_score(int,int), mql_calibration(), mql_evaluate(bigint),
  mql_sla_sweep(), mql_respond(bigint,text,text,text), p6_metrics(text)
from anon, authenticated;

grant execute on function
  combined_score(int,int), mql_calibration(), mql_evaluate(bigint),
  mql_sla_sweep(), mql_respond(bigint,text,text,text), p6_metrics(text)
to service_role;
