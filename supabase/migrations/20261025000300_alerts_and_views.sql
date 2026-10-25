-- =====================================================================
-- Alert engine and clinician views
--
-- Three alert families (thresholds live in alert_rule_sets and must be
-- signed off by the provider's clinical lead before go-live):
--
--  1. Urgent (per session, evaluated as each reading arrives)
--     urgent_high : session mean SBP >= urgent_sys_high OR DBP >= urgent_dia_high
--     urgent_low  : session mean SBP <  urgent_sys_low
--  2. Control (rolling window, evaluated on a schedule)
--     uncontrolled: window mean SBP >= target OR DBP >= target, with at
--                   least control_min_readings over control_min_days days
--  3. Adherence (evaluated on a schedule)
--     nonadherence: no reading for nonadherence_days days; resolves
--                   automatically when readings resume
--
-- De-duplication: one open/acknowledged alert per patient per type.
-- A repeat urgent session updates the open alert (count + latest values)
-- instead of creating a new one. A resolved 'uncontrolled' alert is not
-- re-raised until a full control window has passed.
-- =====================================================================

-- Effective rules for a patient: their rule set, else the org default,
-- else the column defaults.
create or replace function app.effective_rules(p_patient_id uuid)
returns table (
  rule_set_id uuid, rule_set_version int,
  urgent_sys_high int, urgent_dia_high int, urgent_sys_low int,
  target_sys int, target_dia int,
  control_window_days int, control_min_readings int, control_min_days int,
  nonadherence_days int
)
language sql stable security definer set search_path = public, pg_temp as $$
  with p as (select * from public.patients where id = p_patient_id),
  r as (
    select rs.* from p
      join public.alert_rule_sets rs
        on rs.id = p.alert_rule_set_id
        or (p.alert_rule_set_id is null and rs.org_id = p.org_id and rs.is_default)
     limit 1
  )
  select r.id, r.version,
         coalesce(r.urgent_sys_high, 180), coalesce(r.urgent_dia_high, 110), coalesce(r.urgent_sys_low, 90),
         coalesce(p.target_sys, r.default_target_sys, 135), coalesce(p.target_dia, r.default_target_dia, 85),
         coalesce(r.control_window_days, 7), coalesce(r.control_min_readings, 6), coalesce(r.control_min_days, 3),
         coalesce(r.nonadherence_days, 3)
    from p left join r on true
$$;

-- Open (or update) an alert, respecting de-duplication.
create or replace function app.raise_alert(
  p_patient_id uuid, p_type text, p_severity text, p_details jsonb,
  p_session_id uuid default null, p_reading_id uuid default null)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_existing public.alerts%rowtype;
  v_org uuid;
  v_id uuid;
begin
  select * into v_existing from public.alerts
   where patient_id = p_patient_id and alert_type = p_type and status in ('open', 'acknowledged')
   order by triggered_at desc limit 1
   for update;

  if found then
    update public.alerts
       set details = v_existing.details
                     || jsonb_build_object(
                          'latest', p_details,
                          'repeat_count', coalesce((v_existing.details ->> 'repeat_count')::int, 0)
                                          + case when p_session_id is distinct from v_existing.trigger_session_id
                                                 then 1 else 0 end,
                          'last_seen_at', now())
     where id = v_existing.id;
    return v_existing.id;
  end if;

  select org_id into v_org from public.patients where id = p_patient_id;
  insert into public.alerts (org_id, patient_id, alert_type, severity, details,
                             trigger_session_id, trigger_reading_id)
  values (v_org, p_patient_id, p_type, p_severity,
          p_details || jsonb_build_object('repeat_count', 0, 'first', p_details),
          p_session_id, p_reading_id)
  returning id into v_id;
  return v_id;
end $$;

-- Urgent evaluation, run for every new reading.
create or replace function app.bp_readings_after_insert() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r record;
  v_mean_sys numeric;
  v_mean_dia numeric;
  v_n int;
  v_details jsonb;
begin
  select * into r from app.effective_rules(new.patient_id);

  -- session mean (a reading without a session is its own session)
  select avg(systolic), avg(diastolic), count(*)
    into v_mean_sys, v_mean_dia, v_n
    from public.bp_readings
   where not voided
     and patient_id = new.patient_id
     and (case when new.session_id is null then id = new.id else session_id = new.session_id end);

  v_details := jsonb_build_object(
    'session_mean_sys', round(v_mean_sys), 'session_mean_dia', round(v_mean_dia),
    'session_readings', v_n, 'reading_id', new.id, 'measured_at', new.measured_at,
    'thresholds', jsonb_build_object('sys_high', r.urgent_sys_high, 'dia_high', r.urgent_dia_high,
                                     'sys_low', r.urgent_sys_low),
    'rule_set_id', r.rule_set_id, 'rule_set_version', r.rule_set_version);

  if v_mean_sys >= r.urgent_sys_high or v_mean_dia >= r.urgent_dia_high then
    perform app.raise_alert(new.patient_id, 'urgent_high', 'urgent', v_details, new.session_id, new.id);
  elsif v_mean_sys < r.urgent_sys_low then
    perform app.raise_alert(new.patient_id, 'urgent_low', 'urgent', v_details, new.session_id, new.id);
  end if;

  -- readings resumed: close any adherence alert automatically
  update public.alerts
     set status = 'resolved', resolved_at = now(),
         resolution_note = 'Auto-resolved: readings resumed'
   where patient_id = new.patient_id and alert_type = 'nonadherence'
     and status in ('open', 'acknowledged');

  return new;
end $$;

create trigger bp_readings_after_insert
  after insert on public.bp_readings
  for each row execute function app.bp_readings_after_insert();

-- Control and adherence evaluation. Schedule hourly (see cron migration).
-- Returns the number of alerts opened or updated.
create or replace function public.evaluate_control_and_adherence(p_as_of timestamptz default now())
returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  p record;
  r record;
  s record;
  v_last timestamptz;
  v_count int := 0;
begin
  for p in
    select pt.id, pt.enrolled_at, o.timezone
      from public.patients pt join public.organizations o on o.id = pt.org_id
     where pt.status = 'active'
  loop
    select * into r from app.effective_rules(p.id);

    -- control
    select count(*) as n,
           count(distinct (measured_at at time zone p.timezone)::date) as days,
           avg(systolic) as mean_sys, avg(diastolic) as mean_dia
      into s
      from public.bp_readings
     where patient_id = p.id and not voided
       and measured_at >  p_as_of - make_interval(days => r.control_window_days)
       and measured_at <= p_as_of;

    if s.n >= r.control_min_readings and s.days >= r.control_min_days
       and (s.mean_sys >= r.target_sys or s.mean_dia >= r.target_dia)
       and not exists (
         select 1 from public.alerts a
          where a.patient_id = p.id and a.alert_type = 'uncontrolled'
            and a.status = 'resolved'
            and a.resolved_at > p_as_of - make_interval(days => r.control_window_days))
    then
      perform app.raise_alert(p.id, 'uncontrolled', 'routine', jsonb_build_object(
        'window_days', r.control_window_days, 'readings', s.n, 'days_with_readings', s.days,
        'mean_sys', round(s.mean_sys), 'mean_dia', round(s.mean_dia),
        'target_sys', r.target_sys, 'target_dia', r.target_dia,
        'rule_set_id', r.rule_set_id, 'rule_set_version', r.rule_set_version,
        'evaluated_at', p_as_of));
      v_count := v_count + 1;
    end if;

    -- adherence
    select max(measured_at) into v_last from public.bp_readings
     where patient_id = p.id and not voided and measured_at <= p_as_of;

    if coalesce(v_last, p.enrolled_at) is not null
       and coalesce(v_last, p.enrolled_at) < p_as_of - make_interval(days => r.nonadherence_days)
    then
      perform app.raise_alert(p.id, 'nonadherence', 'routine', jsonb_build_object(
        'last_reading_at', v_last, 'enrolled_at', p.enrolled_at,
        'threshold_days', r.nonadherence_days, 'evaluated_at', p_as_of));
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end $$;

revoke all on function public.evaluate_control_and_adherence(timestamptz) from public, anon, authenticated;
grant execute on function public.evaluate_control_and_adherence(timestamptz) to service_role;

revoke all on function app.raise_alert(uuid, text, text, jsonb, uuid, uuid) from public, authenticated;
revoke all on function app.effective_rules(uuid) from public;
grant execute on function app.effective_rules(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Clinician worklist view (RLS of the caller applies)
-- ---------------------------------------------------------------------
create or replace view public.patient_summary
with (security_invoker = true) as
with tz as (
  select pt.*, o.timezone from public.patients pt join public.organizations o on o.id = pt.org_id
),
last_reading as (
  select distinct on (patient_id) patient_id, measured_at, systolic, diastolic, pulse
    from public.bp_readings where not voided
   order by patient_id, measured_at desc
),
win7 as (
  select patient_id, count(*) as n7, round(avg(systolic)) as avg_sys_7d, round(avg(diastolic)) as avg_dia_7d
    from public.bp_readings
   where not voided and measured_at > now() - interval '7 days'
   group by patient_id
),
adh30 as (
  select b.patient_id, count(distinct (b.measured_at at time zone t.timezone)::date) as days_with_readings_30d
    from public.bp_readings b join tz t on t.id = b.patient_id
   where not b.voided and b.measured_at > now() - interval '30 days'
   group by b.patient_id
),
open_alerts as (
  select patient_id,
         count(*) as open_alerts,
         bool_or(severity = 'urgent') as has_urgent,
         min(triggered_at) as oldest_open_alert_at
    from public.alerts where status in ('open', 'acknowledged')
   group by patient_id
)
select
  t.id as patient_id, t.org_id, t.full_name, t.mrn, t.status, t.enrolled_at,
  t.assigned_clinician_id,
  er.target_sys, er.target_dia,
  lr.measured_at as last_reading_at, lr.systolic as last_sys, lr.diastolic as last_dia, lr.pulse as last_pulse,
  coalesce(w.n7, 0) as readings_7d, w.avg_sys_7d, w.avg_dia_7d,
  coalesce(a.days_with_readings_30d, 0) as days_with_readings_30d,
  case
    when coalesce(w.n7, 0) < er.control_min_readings then 'insufficient_data'
    when w.avg_sys_7d >= er.target_sys or w.avg_dia_7d >= er.target_dia then 'above_target'
    else 'at_target'
  end as control_status,
  coalesce(oa.open_alerts, 0) as open_alerts,
  coalesce(oa.has_urgent, false) as has_urgent_alert,
  oa.oldest_open_alert_at,
  -- worklist priority: urgent alerts, then other open alerts, then above target, then not measuring
  case
    when coalesce(oa.has_urgent, false) then 1
    when coalesce(oa.open_alerts, 0) > 0 then 2
    when w.avg_sys_7d >= er.target_sys or w.avg_dia_7d >= er.target_dia then 3
    when lr.measured_at is null or lr.measured_at < now() - interval '3 days' then 4
    else 5
  end as priority
from tz t
cross join lateral app.effective_rules(t.id) er
left join last_reading lr on lr.patient_id = t.id
left join win7 w         on w.patient_id = t.id
left join adh30 a        on a.patient_id = t.id
left join open_alerts oa on oa.patient_id = t.id;

grant select on public.patient_summary to authenticated;

-- ---------------------------------------------------------------------
-- Pilot evidence: one row per patient per calendar month
-- (row-level security applies: staff see their org, a patient sees only themselves)
-- ---------------------------------------------------------------------
create or replace view public.pilot_monthly_metrics
with (security_invoker = true) as
select
  b.org_id, b.patient_id,
  date_trunc('month', b.measured_at at time zone o.timezone)::date as month,
  count(*) as readings,
  count(distinct (b.measured_at at time zone o.timezone)::date) as days_with_readings,
  round(avg(b.systolic), 1) as mean_sys,
  round(avg(b.diastolic), 1) as mean_dia,
  round(avg(case when b.systolic < er.target_sys and b.diastolic < er.target_dia then 1.0 else 0.0 end), 3)
    as share_readings_at_target
from public.bp_readings b
join public.organizations o on o.id = b.org_id
cross join lateral app.effective_rules(b.patient_id) er
where not b.voided
group by b.org_id, b.patient_id, 3;

grant select on public.pilot_monthly_metrics to authenticated;
