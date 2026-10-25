-- =====================================================================
-- Behaviour tests for the RPM schema. Run with supabase/tests/run_tests.sh
-- Any failed assertion aborts the run with a non-zero exit code.
-- =====================================================================
\set ON_ERROR_STOP on
\set QUIET on
\pset tuples_only on
\pset format unaligned

create schema test;
grant usage on schema test to anon, authenticated, service_role;

create function test.ok(cond boolean, msg text) returns void language plpgsql as $$
begin
  if cond is distinct from true then raise exception 'FAIL: %', msg; end if;
  raise notice 'ok - %', msg;
end $$;

-- expects the statement to raise an error
create function test.throws(stmt text, msg text) returns void language plpgsql as $$
begin
  begin
    execute stmt;
  exception when others then
    raise notice 'ok - % (%)', msg, sqlerrm;
    return;
  end;
  raise exception 'FAIL: expected error: %', msg;
end $$;

-- counts rows a statement affects/returns
create function test.cnt(q text) returns bigint language plpgsql as $$
declare n bigint;
begin execute 'select count(*) from (' || q || ') s' into n; return n; end $$;

grant execute on all functions in schema test to anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- Fixtures (as database owner)
-- ---------------------------------------------------------------------
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'admin.a@x'),
  ('00000000-0000-0000-0000-0000000000c1', 'clin.a@x'),
  ('00000000-0000-0000-0000-0000000000b1', 'admin.b@x'),
  ('00000000-0000-0000-0000-0000000000f1', 'p1@x'),
  ('00000000-0000-0000-0000-0000000000f2', 'p2@x'),
  ('00000000-0000-0000-0000-0000000000f9', 'intruder@x');

insert into public.organizations (id, name, timezone, emergency_number) values
  ('0000000a-0000-0000-0000-000000000000', 'Provider A', 'Asia/Riyadh', '997'),
  ('0000000b-0000-0000-0000-000000000000', 'Provider B', 'Africa/Cairo', '123');

insert into public.user_profiles (user_id, org_id, role, full_name) values
  ('00000000-0000-0000-0000-0000000000a1', '0000000a-0000-0000-0000-000000000000', 'admin', 'Admin A'),
  ('00000000-0000-0000-0000-0000000000c1', '0000000a-0000-0000-0000-000000000000', 'clinician', 'Dr A'),
  ('00000000-0000-0000-0000-0000000000b1', '0000000b-0000-0000-0000-000000000000', 'admin', 'Admin B');

insert into public.alert_rule_sets (org_id, name, is_default) values
  ('0000000a-0000-0000-0000-000000000000', 'Default HTN v1', true),
  ('0000000b-0000-0000-0000-000000000000', 'Default HTN v1', true);

-- helper to switch identity
create function test.login(uid text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(uid, ''), false);
end $$;
grant execute on function test.login(text) to anon, authenticated, service_role;

-- =====================================================================
-- 1. Admin enrols patients and issues invite codes
-- =====================================================================
set role authenticated;
select test.login('00000000-0000-0000-0000-0000000000a1');

insert into public.patients (id, org_id, full_name, mrn, phone)
values ('11111111-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'Patient One', 'MRN1', '+966500000001'),
       ('11111111-0000-0000-0000-000000000002', '0000000a-0000-0000-0000-000000000000', 'Patient Two', 'MRN2', '+966500000002');
select test.ok(test.cnt('select * from public.patients') = 2, 'admin sees the two patients they created');

select test.throws($$insert into public.patients (org_id, full_name)
                     values ('0000000b-0000-0000-0000-000000000000', 'Wrong org')$$,
                   'admin cannot create a patient in another provider');

insert into public.devices (org_id, device_sn, ble_mac)
values ('0000000a-0000-0000-0000-000000000000', 'hc03-sn-0001', 'aa:bb:cc:dd:ee:01');
insert into public.device_assignments (org_id, device_id, patient_id)
select '0000000a-0000-0000-0000-000000000000', id, '11111111-0000-0000-0000-000000000001'
  from public.devices where device_sn = 'hc03-sn-0001';
select test.throws($$insert into public.device_assignments (org_id, device_id, patient_id)
                     select '0000000a-0000-0000-0000-000000000000', id, '11111111-0000-0000-0000-000000000002'
                       from public.devices where device_sn = 'hc03-sn-0001'$$,
                   'a device cannot be assigned to two patients at once');

create temp table codes (patient int, code text);
grant all on codes to authenticated;
insert into codes select 1, public.create_patient_invite('11111111-0000-0000-0000-000000000001');
insert into codes select 2, public.create_patient_invite('11111111-0000-0000-0000-000000000002');
select test.ok((select length(code) = 8 from codes where patient = 1), 'invite code is 8 characters');

-- clinician cannot issue invites
select test.login('00000000-0000-0000-0000-0000000000c1');
select test.throws($$select public.create_patient_invite('11111111-0000-0000-0000-000000000001')$$,
                   'clinicians cannot issue invites');

-- =====================================================================
-- 2. Patients join with their code
-- =====================================================================
select test.login('00000000-0000-0000-0000-0000000000f1');
select test.ok(test.cnt('select * from public.patients') = 0, 'before joining, a user sees no patients');
select test.ok(public.redeem_invite((select lower(code) from codes where patient = 1)) = '11111111-0000-0000-0000-000000000001',
               'patient 1 joins with their code (case-insensitive)');
select test.ok(test.cnt('select * from public.patients') = 1, 'patient sees only their own record');
select test.ok((select status = 'active' from public.patients), 'patient becomes active on joining');
select test.ok(test.cnt('select * from public.devices') = 1, 'patient sees the device assigned to them');

select test.login('00000000-0000-0000-0000-0000000000f9');
select test.throws(format('select public.redeem_invite(%L)', (select code from codes where patient = 1)),
                   'a used code cannot be reused');
select test.throws($$select public.redeem_invite('ZZZZZZZZ')$$, 'an unknown code is rejected');

select test.login('00000000-0000-0000-0000-0000000000f2');
select public.redeem_invite((select code from codes where patient = 2));

-- =====================================================================
-- 3. Readings and urgent alerts
-- =====================================================================
select test.login('00000000-0000-0000-0000-0000000000f1');

-- session 1: 182/112 then 178/108 -> mean 180/110 -> urgent_high
insert into public.bp_readings (id, patient_id, org_id, session_id, measured_at, systolic, diastolic, pulse, device_sn)
values ('22222222-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000001',
        '0000000b-0000-0000-0000-000000000000',                       -- spoofed org: must be overridden
        '33333333-0000-0000-0000-000000000001', now() - interval '2 hours', 182, 112, 80, 'HC03-SN-0001'),
       ('22222222-0000-0000-0000-000000000002', '11111111-0000-0000-0000-000000000001',
        '0000000a-0000-0000-0000-000000000000',
        '33333333-0000-0000-0000-000000000001', now() - interval '119 minutes', 178, 108, 78, 'hc03-sn-0001');

select test.ok((select bool_and(org_id = '0000000a-0000-0000-0000-000000000000') from public.bp_readings),
               'org is set by the server, not the phone');
select test.ok((select bool_and(device_id is not null) from public.bp_readings),
               'device is matched from its serial number');
select test.ok(test.cnt('select * from public.alerts') = 0, 'patients cannot see alerts');

select test.throws($$insert into public.bp_readings (id, patient_id, org_id, measured_at, systolic, diastolic)
                     values (gen_random_uuid(), '11111111-0000-0000-0000-000000000002',
                             '0000000a-0000-0000-0000-000000000000', now(), 120, 80)$$,
                   'a patient cannot submit readings for someone else');
select test.throws($$insert into public.bp_readings (id, patient_id, org_id, measured_at, systolic, diastolic)
                     values (gen_random_uuid(), '11111111-0000-0000-0000-000000000001',
                             '0000000a-0000-0000-0000-000000000000', now() + interval '1 day', 120, 80)$$,
                   'future-dated readings are rejected');
select test.throws($$insert into public.bp_readings (id, patient_id, org_id, measured_at, systolic, diastolic)
                     values (gen_random_uuid(), '11111111-0000-0000-0000-000000000001',
                             '0000000a-0000-0000-0000-000000000000', now(), 80, 120)$$,
                   'diastolic above systolic is rejected');
select test.throws($$insert into public.bp_readings (id, patient_id, org_id, measured_at, systolic, diastolic)
                     values ('22222222-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000001',
                             '0000000a-0000-0000-0000-000000000000', now(), 120, 80)$$,
                   'a re-sent reading id is rejected (phone treats this as already uploaded)');

-- the app uploads with "insert ... on conflict do nothing" so retries are harmless
insert into public.bp_readings (id, patient_id, org_id, measured_at, systolic, diastolic)
values ('22222222-0000-0000-0000-000000000001', '11111111-0000-0000-0000-000000000001',
        '0000000a-0000-0000-0000-000000000000', now() - interval '2 hours', 182, 112)
on conflict (id) do nothing;
select test.ok(test.cnt($$select * from public.bp_readings where id = '22222222-0000-0000-0000-000000000001'$$) = 1,
               'retrying an upload (on conflict do nothing) succeeds without duplicating');

-- a patient cannot void (RLS hides the row from UPDATE)
update public.bp_readings set voided = true, void_reason = 'x' where id = '22222222-0000-0000-0000-000000000001';
reset role;
select test.ok((select not voided from public.bp_readings where id = '22222222-0000-0000-0000-000000000001'),
               'patients cannot void readings');
select test.ok((select count(*) = 1 and max(details ->> 'session_readings') = '2'
                  and max(details -> 'latest' ->> 'session_mean_sys') = '180'
                  from public.alerts where alert_type = 'urgent_high'),
               'one urgent_high alert for the session, using the session mean (180)');

-- a second high session updates the same open alert
set role authenticated;
select test.login('00000000-0000-0000-0000-0000000000f1');
insert into public.bp_readings (id, patient_id, org_id, session_id, measured_at, systolic, diastolic)
values (gen_random_uuid(), '11111111-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000',
        '33333333-0000-0000-0000-000000000002', now() - interval '1 hour', 190, 100);
-- low reading -> urgent_low
insert into public.bp_readings (id, patient_id, org_id, session_id, measured_at, systolic, diastolic)
values (gen_random_uuid(), '11111111-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000',
        '33333333-0000-0000-0000-000000000003', now() - interval '30 minutes', 85, 55);
-- normal session: no alert
insert into public.bp_readings (id, patient_id, org_id, session_id, measured_at, systolic, diastolic)
values (gen_random_uuid(), '11111111-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000',
        '33333333-0000-0000-0000-000000000004', now() - interval '10 minutes', 128, 82);
reset role;
select test.ok((select count(*) = 1 and max((details ->> 'repeat_count')::int) = 1
                  from public.alerts where alert_type = 'urgent_high'),
               'a repeat high session updates the open alert instead of creating another');
select test.ok((select count(*) = 1 from public.alerts where alert_type = 'urgent_low'), 'a low session raises urgent_low');
select test.ok((select count(*) = 2 from public.alerts), 'a normal session raises nothing');

-- =====================================================================
-- 4. Clinician workflow
-- =====================================================================
set role authenticated;
select test.login('00000000-0000-0000-0000-0000000000c1');
select test.ok(test.cnt('select * from public.alerts') = 2, 'clinician sees their provider''s alerts');
select test.ok((select priority = 1 and has_urgent_alert from public.patient_summary
                 where patient_id = '11111111-0000-0000-0000-000000000001'),
               'patient with an urgent alert is top of the worklist');

update public.alerts set status = 'acknowledged' where alert_type = 'urgent_high';
select test.ok((select acknowledged_by = '00000000-0000-0000-0000-0000000000c1' and acknowledged_at is not null
                  from public.alerts where alert_type = 'urgent_high'),
               'acknowledging stamps the clinician and time');
update public.alerts set status = 'resolved', resolution_note = 'Called patient; meds adjusted'
 where alert_type = 'urgent_high';
select test.throws($$update public.alerts set status = 'open' where alert_type = 'urgent_high'$$,
                   'a resolved alert cannot be reopened');
select test.throws($$update public.alerts set severity = 'routine' where alert_type = 'urgent_low'$$,
                   'clinicians cannot edit alert severity');

insert into public.clinical_notes (org_id, patient_id, author_id, body)
values ('0000000a-0000-0000-0000-000000000000', '11111111-0000-0000-0000-000000000001',
        '00000000-0000-0000-0000-0000000000c1', 'Increase amlodipine to 10 mg');
select test.throws($$insert into public.clinical_notes (org_id, patient_id, author_id, body)
                     values ('0000000a-0000-0000-0000-000000000000', '11111111-0000-0000-0000-000000000001',
                             '00000000-0000-0000-0000-0000000000a1', 'impersonation')$$,
                   'a note cannot be written in someone else''s name');
insert into public.medication_events (org_id, patient_id, drug_name, dose, action, effective_date, recorded_by)
values ('0000000a-0000-0000-0000-000000000000', '11111111-0000-0000-0000-000000000001',
        'Amlodipine', '10 mg', 'change', current_date, '00000000-0000-0000-0000-0000000000c1');

update public.bp_readings set voided = true, void_reason = 'Cuff on wrist by mistake'
 where systolic = 85;
select test.ok((select voided_by = '00000000-0000-0000-0000-0000000000c1' from public.bp_readings where systolic = 85),
               'clinician can void a reading with a reason');
select test.throws($$update public.bp_readings set voided = false, void_reason = 'undo' where systolic = 85$$,
                   'a voided reading cannot be un-voided');
select test.throws($$update public.bp_readings set systolic = 120 where systolic = 190$$,
                   'reading values cannot be edited');
select test.throws($$update public.patients set user_id = '00000000-0000-0000-0000-0000000000f9'
                     where id = '11111111-0000-0000-0000-000000000002'$$,
                   'staff cannot re-link a patient account');
select test.ok(test.cnt('select * from public.audit_log') = 0, 'clinicians cannot read the audit log');

-- =====================================================================
-- 5. Tenant isolation and anonymous access
-- =====================================================================
select test.login('00000000-0000-0000-0000-0000000000b1');
select test.ok(test.cnt('select * from public.patients') = 0
           and test.cnt('select * from public.bp_readings') = 0
           and test.cnt('select * from public.alerts') = 0
           and test.cnt('select * from public.patient_summary') = 0,
               'another provider sees none of provider A''s data');

reset role;
set role anon;
select test.login(null);
select test.throws('select * from public.patients', 'anonymous users have no access');
reset role;

-- =====================================================================
-- 6. Scheduled control and adherence evaluation (runs as service)
-- =====================================================================
-- patient 2: 6 readings over 3 days averaging 150/95 (target 135/85)
insert into public.bp_readings (id, patient_id, org_id, session_id, measured_at, systolic, diastolic)
select gen_random_uuid(), '11111111-0000-0000-0000-000000000002', '0000000a-0000-0000-0000-000000000000',
       gen_random_uuid(), now() - (d || ' days')::interval - (h || ' hours')::interval, 150, 95
  from generate_series(1, 3) d, generate_series(0, 1) h;

set role service_role;
select public.evaluate_control_and_adherence();
select public.evaluate_control_and_adherence();
reset role;
select test.ok((select count(*) = 1 from public.alerts where alert_type = 'uncontrolled'
                 and patient_id = '11111111-0000-0000-0000-000000000002'),
               'uncontrolled alert raised once for 7-day mean 150/95, not duplicated on re-run');

update public.alerts set status = 'resolved', resolved_at = now() where alert_type = 'uncontrolled';
set role service_role;
select public.evaluate_control_and_adherence();
reset role;
select test.ok((select count(*) = 1 from public.alerts where alert_type = 'uncontrolled'),
               'a resolved uncontrolled alert is not re-raised within the window');
select test.ok((select count(*) = 0 from public.alerts where alert_type = 'uncontrolled'
                 and patient_id = '11111111-0000-0000-0000-000000000001'),
               'a patient without enough readings in the window gets no control alert');

-- adherence: patient 2's last reading was ~1 day ago; evaluate as of 5 days later
set role service_role;
select public.evaluate_control_and_adherence(now() + interval '5 days');
reset role;
select test.ok((select count(*) = 1 from public.alerts where alert_type = 'nonadherence'
                 and patient_id = '11111111-0000-0000-0000-000000000002' and status = 'open'),
               'no readings for more than 3 days raises a non-adherence alert');

set role authenticated;
select test.login('00000000-0000-0000-0000-0000000000f2');
insert into public.bp_readings (id, patient_id, org_id, measured_at, systolic, diastolic)
values (gen_random_uuid(), '11111111-0000-0000-0000-000000000002', '0000000a-0000-0000-0000-000000000000',
        now(), 132, 84);
reset role;
select test.ok((select status = 'resolved' and resolved_by is null and resolution_note like 'Auto-resolved%'
                  from public.alerts where alert_type = 'nonadherence'
                   and patient_id = '11111111-0000-0000-0000-000000000002'),
               'the non-adherence alert closes itself when readings resume');

-- =====================================================================
-- 7. Audit trail and evidence views
-- =====================================================================
set role authenticated;
select test.login('00000000-0000-0000-0000-0000000000a1');
select test.ok(test.cnt($$select * from public.audit_log where entity = 'alerts' and action = 'UPDATE'$$) >= 2,
               'admins can read alert changes in the audit log');
select test.ok(test.cnt($$select * from public.audit_log where entity = 'bp_readings'$$) >= 5,
               'reading uploads are audited');
select test.ok(test.cnt('select * from public.pilot_monthly_metrics') >= 2,
               'monthly pilot metrics are available to staff');
reset role;

\echo
\echo 'ALL TESTS PASSED'
