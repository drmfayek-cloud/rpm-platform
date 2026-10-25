-- =====================================================================
-- Access control: helper functions, row-level security, guarded
-- writes, invitation flow, audit trail.
--
-- Roles (user_profiles.role):
--   admin      — provider administrator: users, patients, devices, rules
--   clinician  — reviews readings, handles alerts, notes, medications
--   patient    — own data only; can submit readings and consent
-- =====================================================================

-- ---------------------------------------------------------------------
-- Helper functions (SECURITY DEFINER so policies don't recurse)
-- ---------------------------------------------------------------------
create or replace function app.my_org_id() returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select org_id from public.user_profiles where user_id = auth.uid() and active
$$;

create or replace function app.my_role() returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select role from public.user_profiles where user_id = auth.uid() and active
$$;

create or replace function app.is_staff() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(app.my_role() in ('admin', 'clinician'), false)
$$;

create or replace function app.is_admin() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(app.my_role() = 'admin', false)
$$;

create or replace function app.my_patient_id() returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select id from public.patients where user_id = auth.uid()
$$;

grant usage on schema app to authenticated, service_role;
grant execute on all functions in schema app to authenticated, service_role;

-- ---------------------------------------------------------------------
-- Baseline privileges: nothing for anonymous users
-- ---------------------------------------------------------------------
revoke all on all tables in schema public from anon;
revoke all on all tables in schema public from authenticated;

grant select, update                 on public.organizations      to authenticated;
grant select, insert, update         on public.user_profiles      to authenticated;
grant select, insert, update         on public.alert_rule_sets    to authenticated;
grant select, insert, update         on public.patients           to authenticated;
grant select, insert, delete         on public.patient_invites    to authenticated;
grant select, insert                 on public.consents           to authenticated;
grant select, insert, update         on public.devices            to authenticated;
grant select, insert, update         on public.device_assignments to authenticated;
grant select, insert                 on public.bp_readings        to authenticated;
grant update (voided, void_reason)   on public.bp_readings        to authenticated;
grant select                         on public.alerts             to authenticated;
grant update (status, resolution_note) on public.alerts           to authenticated;
grant select, insert                 on public.clinical_notes     to authenticated;
grant select, insert                 on public.medication_events  to authenticated;
grant select                         on public.audit_log          to authenticated;

grant all on all tables in schema public to service_role;

-- ---------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------
alter table public.organizations      enable row level security;
alter table public.user_profiles      enable row level security;
alter table public.alert_rule_sets    enable row level security;
alter table public.patients           enable row level security;
alter table public.patient_invites    enable row level security;
alter table public.consents           enable row level security;
alter table public.devices            enable row level security;
alter table public.device_assignments enable row level security;
alter table public.bp_readings        enable row level security;
alter table public.alerts             enable row level security;
alter table public.clinical_notes     enable row level security;
alter table public.medication_events  enable row level security;
alter table public.audit_log          enable row level security;

-- organizations
create policy org_select on public.organizations for select to authenticated
  using (id = app.my_org_id());
create policy org_update on public.organizations for update to authenticated
  using (id = app.my_org_id() and app.is_admin())
  with check (id = app.my_org_id());

-- user_profiles
create policy profiles_select on public.user_profiles for select to authenticated
  using (user_id = auth.uid() or (org_id = app.my_org_id() and app.is_staff()));
create policy profiles_admin_insert on public.user_profiles for insert to authenticated
  with check (org_id = app.my_org_id() and app.is_admin() and role in ('admin', 'clinician'));
create policy profiles_admin_update on public.user_profiles for update to authenticated
  using (org_id = app.my_org_id() and app.is_admin())
  with check (org_id = app.my_org_id());

-- alert_rule_sets
create policy rules_select on public.alert_rule_sets for select to authenticated
  using (org_id = app.my_org_id() and app.is_staff());
create policy rules_admin_insert on public.alert_rule_sets for insert to authenticated
  with check (org_id = app.my_org_id() and app.is_admin());
create policy rules_admin_update on public.alert_rule_sets for update to authenticated
  using (org_id = app.my_org_id() and app.is_admin())
  with check (org_id = app.my_org_id());

-- patients
create policy patients_select on public.patients for select to authenticated
  using (user_id = auth.uid() or (org_id = app.my_org_id() and app.is_staff()));
create policy patients_admin_insert on public.patients for insert to authenticated
  with check (org_id = app.my_org_id() and app.is_admin() and user_id is null);
create policy patients_staff_update on public.patients for update to authenticated
  using (org_id = app.my_org_id() and app.is_staff())
  with check (org_id = app.my_org_id());

-- patient_invites (redeemed only through public.redeem_invite)
create policy invites_admin_all on public.patient_invites for select to authenticated
  using (org_id = app.my_org_id() and app.is_admin());
create policy invites_admin_insert on public.patient_invites for insert to authenticated
  with check (org_id = app.my_org_id() and app.is_admin());
create policy invites_admin_delete on public.patient_invites for delete to authenticated
  using (org_id = app.my_org_id() and app.is_admin() and used_at is null);

-- consents
create policy consents_select on public.consents for select to authenticated
  using (patient_id = app.my_patient_id() or (org_id = app.my_org_id() and app.is_staff()));
create policy consents_patient_insert on public.consents for insert to authenticated
  with check (patient_id = app.my_patient_id() and method = 'in_app');
create policy consents_staff_insert on public.consents for insert to authenticated
  with check (org_id = app.my_org_id() and app.is_staff() and method = 'paper');

-- devices
create policy devices_select on public.devices for select to authenticated
  using (
    (org_id = app.my_org_id() and app.is_staff())
    or id in (select device_id from public.device_assignments
              where patient_id = app.my_patient_id() and returned_at is null)
  );
create policy devices_admin_insert on public.devices for insert to authenticated
  with check (org_id = app.my_org_id() and app.is_admin());
create policy devices_admin_update on public.devices for update to authenticated
  using (org_id = app.my_org_id() and app.is_admin())
  with check (org_id = app.my_org_id());

-- device_assignments
create policy assignments_select on public.device_assignments for select to authenticated
  using (patient_id = app.my_patient_id() or (org_id = app.my_org_id() and app.is_staff()));
create policy assignments_admin_insert on public.device_assignments for insert to authenticated
  with check (org_id = app.my_org_id() and app.is_admin());
create policy assignments_admin_update on public.device_assignments for update to authenticated
  using (org_id = app.my_org_id() and app.is_admin())
  with check (org_id = app.my_org_id());

-- bp_readings
create policy readings_select on public.bp_readings for select to authenticated
  using (patient_id = app.my_patient_id() or (org_id = app.my_org_id() and app.is_staff()));
create policy readings_patient_insert on public.bp_readings for insert to authenticated
  with check (patient_id = app.my_patient_id());
create policy readings_staff_manual_insert on public.bp_readings for insert to authenticated
  with check (org_id = app.my_org_id() and app.is_staff() and source = 'manual');
create policy readings_staff_void on public.bp_readings for update to authenticated
  using (org_id = app.my_org_id() and app.is_staff())
  with check (org_id = app.my_org_id());

-- alerts (created only by the system)
create policy alerts_select on public.alerts for select to authenticated
  using (org_id = app.my_org_id() and app.is_staff());
create policy alerts_staff_update on public.alerts for update to authenticated
  using (org_id = app.my_org_id() and app.is_staff())
  with check (org_id = app.my_org_id());

-- clinical notes & medications (append-only)
create policy notes_select on public.clinical_notes for select to authenticated
  using (org_id = app.my_org_id() and app.is_staff());
create policy notes_insert on public.clinical_notes for insert to authenticated
  with check (org_id = app.my_org_id() and app.is_staff() and author_id = auth.uid());

create policy meds_select on public.medication_events for select to authenticated
  using (org_id = app.my_org_id() and app.is_staff());
create policy meds_insert on public.medication_events for insert to authenticated
  with check (org_id = app.my_org_id() and app.is_staff() and recorded_by = auth.uid());

-- audit log
create policy audit_admin_select on public.audit_log for select to authenticated
  using (org_id = app.my_org_id() and app.is_admin());

-- ---------------------------------------------------------------------
-- Guarded writes: server-side defaults that clients cannot override
-- ---------------------------------------------------------------------

-- Readings: org, author and device are derived on the server.
create or replace function app.bp_readings_before_insert() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_patient public.patients%rowtype;
begin
  select * into v_patient from public.patients where id = new.patient_id;
  if not found then
    raise exception 'unknown patient %', new.patient_id using errcode = '23503';
  end if;
  if v_patient.status not in ('active', 'paused') and auth.uid() is not null
     and auth.uid() = v_patient.user_id then
    raise exception 'patient is not enrolled' using errcode = '42501';
  end if;

  new.org_id      := v_patient.org_id;
  new.received_at := now();
  new.entered_by  := auth.uid();
  new.voided      := false;
  new.void_reason := null;
  new.voided_by   := null;
  new.voided_at   := null;

  if new.device_sn is not null and new.device_id is null then
    select id into new.device_id from public.devices
     where device_sn = lower(new.device_sn) and org_id = v_patient.org_id;
  end if;
  new.device_sn := lower(new.device_sn);
  return new;
end $$;

create trigger bp_readings_before_insert
  before insert on public.bp_readings
  for each row execute function app.bp_readings_before_insert();

-- Readings: only the void flag may change, and only one way.
create or replace function app.bp_readings_before_update() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  if old.voided then
    raise exception 'reading already voided' using errcode = '42501';
  end if;
  if new.voided and coalesce(trim(new.void_reason), '') = '' then
    raise exception 'void_reason is required' using errcode = '23514';
  end if;
  new.voided_by := auth.uid();
  new.voided_at := now();
  return new;
end $$;

create trigger bp_readings_before_update
  before update on public.bp_readings
  for each row execute function app.bp_readings_before_update();

-- Alerts: status moves forward only; who/when is stamped by the server.
create or replace function app.alerts_before_update() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  if old.status = 'resolved' and new.status <> 'resolved' then
    raise exception 'resolved alerts cannot be reopened' using errcode = '42501';
  end if;
  -- System updates (alert engine, running as the function owner) set their own fields.
  if current_user <> 'authenticated' then
    return new;
  end if;
  if new.status = 'acknowledged' and old.status = 'open' then
    new.acknowledged_by := auth.uid();
    new.acknowledged_at := now();
  elsif new.status = 'resolved' and old.status <> 'resolved' then
    if old.acknowledged_at is null then
      new.acknowledged_by := auth.uid();
      new.acknowledged_at := now();
    end if;
    new.resolved_by := auth.uid();
    new.resolved_at := now();
  elsif new.status = 'open' and old.status = 'acknowledged' then
    raise exception 'acknowledged alerts cannot be reopened' using errcode = '42501';
  end if;
  return new;
end $$;

create trigger alerts_before_update
  before update on public.alerts
  for each row execute function app.alerts_before_update();

-- Patients: patients join only through invites; staff cannot hijack user_id.
create or replace function app.patients_before_update() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  if new.user_id is distinct from old.user_id and current_user = 'authenticated' then
    raise exception 'user_id can only be set by invitation' using errcode = '42501';
  end if;
  if new.org_id <> old.org_id then
    raise exception 'org_id cannot change' using errcode = '42501';
  end if;
  if new.status in ('withdrawn', 'completed') and old.status not in ('withdrawn', 'completed') then
    new.ended_at := coalesce(new.ended_at, now());
  end if;
  return new;
end $$;

create trigger patients_before_update
  before update on public.patients
  for each row execute function app.patients_before_update();

-- Notes / medications / consents: stamp the author.
create or replace function app.stamp_author() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  if tg_table_name = 'consents' then
    new.recorded_by := auth.uid();
    new.recorded_at := now();
    if new.method = 'in_app' then
      select org_id into new.org_id from public.patients where id = new.patient_id;
    end if;
  elsif tg_table_name = 'clinical_notes' then
    new.created_at := now();
  elsif tg_table_name = 'medication_events' then
    new.created_at := now();
  end if;
  return new;
end $$;

create trigger consents_stamp before insert on public.consents
  for each row execute function app.stamp_author();
create trigger notes_stamp before insert on public.clinical_notes
  for each row execute function app.stamp_author();
create trigger meds_stamp before insert on public.medication_events
  for each row execute function app.stamp_author();

-- ---------------------------------------------------------------------
-- Invitations
-- ---------------------------------------------------------------------

-- Admin creates a one-time code for a patient (shown/printed in the web app).
create or replace function public.create_patient_invite(p_patient_id uuid, p_valid_days int default 14)
returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_org uuid;
  v_code text;
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';  -- no 0/O/1/I
  i int;
begin
  if not app.is_admin() then
    raise exception 'only admins can invite patients' using errcode = '42501';
  end if;
  select org_id into v_org from public.patients
   where id = p_patient_id and user_id is null;
  if v_org is null or v_org <> app.my_org_id() then
    raise exception 'patient not found or already joined' using errcode = '42501';
  end if;
  loop
    v_code := '';
    for i in 1..8 loop
      v_code := v_code || substr(v_alphabet, 1 + (get_byte(gen_random_bytes(1), 0) % 32), 1);
    end loop;
    exit when not exists (select 1 from public.patient_invites where code = v_code);
  end loop;
  -- one live code per patient
  delete from public.patient_invites where patient_id = p_patient_id and used_at is null;
  insert into public.patient_invites (code, org_id, patient_id, expires_at, created_by)
  values (v_code, v_org, p_patient_id, now() + make_interval(days => p_valid_days), auth.uid());
  return v_code;
end $$;

-- Patient app calls this right after sign-up to link the account.
create or replace function public.redeem_invite(p_code text)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_inv public.patient_invites%rowtype;
  v_patient public.patients%rowtype;
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  if exists (select 1 from public.user_profiles where user_id = auth.uid()) then
    raise exception 'account is already linked' using errcode = '42501';
  end if;

  select * into v_inv from public.patient_invites
   where code = upper(trim(p_code)) for update;
  if not found or v_inv.used_at is not null or v_inv.expires_at < now() then
    raise exception 'invalid or expired code' using errcode = '22023';
  end if;

  select * into v_patient from public.patients where id = v_inv.patient_id for update;
  if v_patient.user_id is not null then
    raise exception 'invalid or expired code' using errcode = '22023';
  end if;

  insert into public.user_profiles (user_id, org_id, role, full_name, phone, locale)
  values (auth.uid(), v_patient.org_id, 'patient', v_patient.full_name, v_patient.phone, v_patient.locale);

  update public.patients
     set user_id = auth.uid(), status = 'active', enrolled_at = coalesce(enrolled_at, now())
   where id = v_patient.id;

  update public.patient_invites set used_at = now(), used_by = auth.uid() where code = v_inv.code;
  return v_patient.id;
end $$;

revoke all on function public.create_patient_invite(uuid, int) from public, anon;
revoke all on function public.redeem_invite(text) from public, anon;
grant execute on function public.create_patient_invite(uuid, int) to authenticated;
grant execute on function public.redeem_invite(text) to authenticated;

-- ---------------------------------------------------------------------
-- Audit trail
-- ---------------------------------------------------------------------
create or replace function app.audit() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_new jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  v_old jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_row jsonb := coalesce(v_new, v_old);
  v_changes jsonb;
begin
  if tg_op = 'UPDATE' then
    select jsonb_object_agg(key, jsonb_build_object('from', v_old -> key, 'to', value))
      into v_changes
      from jsonb_each(v_new)
     where v_old -> key is distinct from value;
  end if;
  insert into public.audit_log (org_id, actor_id, action, entity, entity_id, details)
  values (
    nullif(v_row ->> 'org_id', '')::uuid,
    auth.uid(),
    tg_op,
    tg_table_name,
    coalesce(v_row ->> 'id', v_row ->> 'user_id', v_row ->> 'code'),
    case
      when tg_op = 'UPDATE' then v_changes
      when tg_table_name = 'bp_readings' then jsonb_build_object('patient_id', v_row -> 'patient_id')
      else null
    end
  );
  return coalesce(new, old);
end $$;

do $$
declare t text;
begin
  foreach t in array array['organizations', 'user_profiles', 'alert_rule_sets', 'patients',
                           'patient_invites', 'consents', 'devices', 'device_assignments',
                           'bp_readings', 'alerts', 'clinical_notes', 'medication_events']
  loop
    execute format('create trigger %I_audit after insert or update or delete on public.%I
                    for each row execute function app.audit()', t, t);
  end loop;
end $$;
