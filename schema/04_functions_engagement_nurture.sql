-- ============================================================================
-- P6: engagement scoring with decay, and the nurture lifecycle
-- ============================================================================
-- Intent is what someone said once on the form. Engagement is what they keep
-- doing. Points fade, because interest goes stale: a click yesterday is worth
-- more than a click in August even though both are "one click".
--
-- The decay shape deliberately mirrors P3's signal_decay_policy, so the system
-- has ONE decay idea rather than two.
-- ============================================================================

-- What is still burning, not how many logs were ever thrown on the fire.
create or replace function engagement_score(p_email text)
returns int language sql stable security definer set search_path = public as $$
  select least(100, greatest(0, coalesce(round(sum(
    p.weight * case
      when age_days <= p.fresh_days then 1.0
      when age_days >= p.hard_stop_days then 0.0
      else power(0.5, (age_days - p.fresh_days)::numeric / p.half_life_days)
    end
  ))::int, 0)))
  from (
    select e.event_type,
           extract(epoch from (now() - e.at)) / 86400.0 as age_days
    from engagement_events e
    where lower(e.email) = lower(p_email)
  ) ev
  join engagement_policy p on p.event_type = ev.event_type and p.tracked;
$$;

-- A readable breakdown, for explaining a score to a rep rather than asserting it.
create or replace function engagement_explain(p_email text)
returns table(event_type text, happened timestamptz, days_ago numeric, full_value int, worth_now numeric)
language sql stable security definer set search_path = public as $$
  select e.event_type, e.at,
         round((extract(epoch from (now() - e.at)) / 86400.0)::numeric, 1),
         p.weight,
         round((p.weight * case
           when extract(epoch from (now() - e.at))/86400.0 <= p.fresh_days then 1.0
           when extract(epoch from (now() - e.at))/86400.0 >= p.hard_stop_days then 0.0
           else power(0.5, ((extract(epoch from (now() - e.at))/86400.0) - p.fresh_days)::numeric / p.half_life_days)
         end)::numeric, 1)
  from engagement_events e
  join engagement_policy p on p.event_type = e.event_type and p.tracked
  where lower(e.email) = lower(p_email)
  order by e.at desc;
$$;

-- ENROL.
-- Nurture is the high-fit, low-engagement quadrant: right company, not paying
-- attention yet. Gates are checked in order and every refusal is named, so
-- "why is this person not being nurtured?" always has an answer.
create or replace function nurture_enroll(p_email text, p_track text, p_submission bigint default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  t record; v_fit int; v_eng int; v_domain text; v_member bigint;
begin
  select * into t from nurture_tracks where id = p_track and active;
  if not found then return jsonb_build_object('enrolled', false, 'reason', 'no_such_active_track'); end if;

  p_email  := lower(trim(p_email));
  v_domain := split_part(p_email, '@', 2);

  -- 1. never email someone who opted out, bounced or complained.
  --    This is P4's suppression list, reused: one opt-out list, not two.
  if exists (select 1 from seq_suppression s where lower(s.email) = p_email) then
    return jsonb_build_object('enrolled', false, 'reason', 'suppressed');
  end if;

  -- 2. consent is a gate, not a score
  if p_submission is not null and exists (
      select 1 from inbound_submissions s
      where s.id = p_submission and s.validation_errors ? 'no_consent') then
    return jsonb_build_object('enrolled', false, 'reason', 'no_consent');
  end if;

  -- 3. already being nurtured, or already in any live sequence
  if exists (select 1 from nurture_members m
              where m.email = p_email and m.status = 'active') then
    return jsonb_build_object('enrolled', false, 'reason', 'already_nurtured');
  end if;
  if exists (select 1 from seq_enrollments e
             join seq_contacts c on c.id = e.contact_id
             where lower(c.email) = p_email and e.status in ('active','pending')) then
    return jsonb_build_object('enrolled', false, 'reason', 'in_another_sequence');
  end if;

  -- 4. already a customer: that conversation belongs to its owner
  if exists (select 1 from icp_companies ic where ic.domain = v_domain and ic.sf_account_id is not null) then
    return jsonb_build_object('enrolled', false, 'reason', 'existing_account');
  end if;

  -- 5. the quadrant test: high fit, low engagement
  select d2.fit_score into v_fit from inbound_decisions d2
   where d2.submission_id = coalesce(p_submission, -1);
  v_fit := coalesce(v_fit, 0);
  v_eng := engagement_score(p_email);

  if v_fit < t.min_fit then
    return jsonb_build_object('enrolled', false, 'reason', 'fit_too_low', 'fit', v_fit, 'needed', t.min_fit);
  end if;
  if v_eng > t.max_engagement then
    return jsonb_build_object('enrolled', false, 'reason', 'already_engaged', 'engagement', v_eng);
  end if;

  insert into nurture_members (email, track_id, submission_id)
  values (p_email, p_track, p_submission)
  returning id into v_member;

  return jsonb_build_object('enrolled', true, 'member_id', v_member,
                            'track', p_track, 'fit', v_fit, 'engagement', v_eng);
end $$;

-- EXIT.
-- A nurture track nobody can leave is a spam machine. Seven ways out, checked
-- most-urgent first; the first match wins, is recorded with its reason, and
-- immediately pauses any sending.
--
-- Rule 3 is the one that connects the projects: P3 watches job boards and
-- website tech stacks every morning, and a fresh signal on a nurtured
-- company's domain pulls that person straight out to a human. Nurture is not
-- a waiting room, it is a watch list with a trigger.
create or replace function nurture_exit_sweep()
returns table(out_email text, out_reason text, out_detail text)
language plpgsql security definer set search_path = public as $$
declare
  m record; v_domain text; v_eng int; v_fit int; v_reason text; v_detail text; v_sig record;
begin
  for m in select nm.*, t.max_days, t.min_fit, t.max_engagement
             from nurture_members nm
             join nurture_tracks t on t.id = nm.track_id
            where nm.status = 'active'
  loop
    v_reason := null; v_detail := null;
    v_domain := split_part(m.email, '@', 2);

    -- 1. opted out, bounced or complained: terminal
    if exists (select 1 from seq_suppression s where lower(s.email) = m.email) then
      select s2.reason into v_detail from seq_suppression s2 where lower(s2.email) = m.email limit 1;
      v_reason := 'suppressed';

    -- 2. they replied: a human conversation beats any automation.
    --    >= rather than > because a reply arriving in the same transaction as
    --    the enrolment carries an identical timestamp (now() is fixed per
    --    transaction), and the strict test silently missed it.
    elsif exists (select 1 from engagement_events e
                   where lower(e.email) = m.email and e.event_type = 'replied'
                     and e.at >= m.enrolled_at) then
      v_reason := 'replied'; v_detail := 'hand to a person';

    else
      -- 3. their company just did something: what nurture was waiting for
      select g.signal_type, g.detected_at into v_sig
        from signals g
       where g.domain = v_domain
         and g.detected_at > m.enrolled_at
         and (g.expires_at is null or g.expires_at > now())
       order by g.detected_at desc limit 1;

      if v_sig.signal_type is not null then
        v_reason := 'company_signal_fired';
        v_detail := v_sig.signal_type || ' on ' || to_char(v_sig.detected_at, 'DD Mon');
      else
        v_eng := engagement_score(m.email);
        v_fit := coalesce((select d.fit_score from inbound_decisions d
                            where d.submission_id = m.submission_id), 0);

        -- 4. warmed up on their own: out of the quiet quadrant
        if v_eng > m.max_engagement then
          v_reason := 'became_engaged'; v_detail := 'engagement ' || v_eng;
        -- 5. no longer fits: stop quietly
        elsif v_fit < m.min_fit then
          v_reason := 'fit_dropped'; v_detail := 'fit ' || v_fit;
        -- 6. time is up: nobody is nurtured forever
        elsif m.enrolled_at < now() - (m.max_days || ' days')::interval then
          v_reason := 'max_duration'; v_detail := m.max_days || ' days';
        -- 7. the track ran out of things to say
        elsif m.enrollment_id is not null and exists (
                select 1 from seq_enrollments e2
                 where e2.id = m.enrollment_id and e2.status = 'completed') then
          v_reason := 'track_completed'; v_detail := 'all steps sent';
        end if;
      end if;
    end if;

    if v_reason is not null then
      update nurture_members nm2
         set status = 'exited', exit_reason = v_reason, exit_detail = v_detail, exited_at = now()
       where nm2.id = m.id;
      insert into nurture_exit_log (email, track_id, reason, detail)
      values (m.email, m.track_id, v_reason, v_detail);
      if m.enrollment_id is not null then
        update seq_enrollments e3 set status = 'paused'
         where e3.id = m.enrollment_id and e3.status = 'active';
      end if;
      out_email := m.email; out_reason := v_reason; out_detail := v_detail;
      return next;
    end if;
  end loop;
end $$;

revoke all on function
  engagement_score(text), engagement_explain(text),
  nurture_enroll(text,text,bigint), nurture_exit_sweep()
from anon, authenticated;

grant execute on function
  engagement_score(text), engagement_explain(text),
  nurture_enroll(text,text,bigint), nurture_exit_sweep()
to service_role;
