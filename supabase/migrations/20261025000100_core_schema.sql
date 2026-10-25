-- =====================================================================
-- RPM platform — core schema (hypertension pilot)
-- Target: Supabase (PostgreSQL 15+). Tested locally on PostgreSQL 16
-- with a stub of Supabase's auth schema (see supabase/tests).
--
-- Design notes
--  * Multi-tenant: every clinical row carries org_id (the provider).
--  * Readings are immutable; corrections are made by voiding, never by
--    editing values.
--  * Reading ids are generated on the phone so offline uploads can be
--    retried safely (idempotent insert).
-- =====================================================================

create extension if not exists pgcrypto;

create schema if not exists app;   -- internal helper functions

-- ---------------------------------------------------------------------
-- Tenancy and users
-- ---------------------------------------------------------------------
create table public.organizations (
  id               uuid primary key default gen_random_uuid(),
  name             text not null,
  country_code     text,                         -- ISO 3166-1 alpha-2
  timezone         text not null default 'UTC',  -- used for "days with readings"
  emergency_number text,                         -- shown to patients on urgent results
  created_at       timestamptz not null default now()
);

create table public.user_profiles (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  org_id      uuid not null references public.organizations(id),
  role        text not null check (role in ('admin', 'clinician', 'patient')),
  full_name   text not null,
  phone       text,
  locale      text not null default 'en',
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);
create index on public.user_profiles (org_id, role);

-- ---------------------------------------------------------------------
-- Alert rule sets (clinical thresholds — require clinical sign-off)
-- ---------------------------------------------------------------------
create table public.alert_rule_sets (
  id                     uuid primary key default gen_random_uuid(),
  org_id                 uuid not null references public.organizations(id),
  name                   text not null,
  is_default             boolean not null default false,
  version                int  not null default 1,
  -- urgent (evaluated per measurement session)
  urgent_sys_high        int  not null default 180 check (urgent_sys_high between 140 and 260),
  urgent_dia_high        int  not null default 110 check (urgent_dia_high between 90 and 160),
  urgent_sys_low         int  not null default 90  check (urgent_sys_low between 60 and 110),
  -- control (evaluated on rolling window averages)
  default_target_sys     int  not null default 135 check (default_target_sys between 100 and 180),
  default_target_dia     int  not null default 85  check (default_target_dia between 60 and 110),
  control_window_days    int  not null default 7   check (control_window_days between 3 and 30),
  control_min_readings   int  not null default 6   check (control_min_readings >= 2),
  control_min_days       int  not null default 3   check (control_min_days >= 1),
  -- adherence
  nonadherence_days      int  not null default 3   check (nonadherence_days between 1 and 30),
  -- governance
  approved_by_name       text,                     -- clinical lead who signed off
  approved_at            timestamptz,
  created_at             timestamptz not null default now()
);
create unique index alert_rule_sets_one_default
  on public.alert_rule_sets (org_id) where is_default;

-- ---------------------------------------------------------------------
-- Patients, invitations, consent
-- ---------------------------------------------------------------------
create table public.patients (
  id                     uuid primary key default gen_random_uuid(),
  org_id                 uuid not null references public.organizations(id),
  user_id                uuid unique references auth.users(id),  -- set when the patient joins
  mrn                    text,                                    -- provider's record number
  full_name              text not null,
  date_of_birth          date,
  sex                    text check (sex in ('female', 'male', 'other', 'unknown')),
  phone                  text,
  locale                 text not null default 'en',
  status                 text not null default 'invited'
                           check (status in ('invited', 'active', 'paused', 'withdrawn', 'completed')),
  enrolled_at            timestamptz,
  ended_at               timestamptz,
  assigned_clinician_id  uuid references public.user_profiles(user_id),
  alert_rule_set_id      uuid references public.alert_rule_sets(id),  -- null = org default
  target_sys             int check (target_sys between 100 and 180),   -- null = rule-set default
  target_dia             int check (target_dia between 60 and 110),
  created_by             uuid references auth.users(id),
  created_at             timestamptz not null default now(),
  unique (org_id, mrn)
);
create index on public.patients (org_id, status);

create table public.patient_invites (
  code        text primary key,
  org_id      uuid not null references public.organizations(id),
  patient_id  uuid not null references public.patients(id) on delete cascade,
  expires_at  timestamptz not null default now() + interval '14 days',
  used_at     timestamptz,
  used_by     uuid references auth.users(id),
  created_by  uuid references auth.users(id),
  created_at  timestamptz not null default now()
);

create table public.consents (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references public.organizations(id),
  patient_id    uuid not null references public.patients(id) on delete cascade,
  consent_type  text not null check (consent_type in ('care', 'data_sharing', 'research')),
  version       text not null,                 -- consent text version shown
  granted       boolean not null,
  method        text not null default 'in_app' check (method in ('in_app', 'paper')),
  recorded_by   uuid references auth.users(id),
  recorded_at   timestamptz not null default now()
);
create index on public.consents (patient_id, consent_type, recorded_at desc);

-- ---------------------------------------------------------------------
-- Devices (the 100 HC03 units) and assignments
-- ---------------------------------------------------------------------
create table public.devices (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.organizations(id),
  model             text not null default 'HC03',
  device_sn         text not null unique       -- device ID read from the HC03 over Bluetooth
                      check (device_sn = lower(device_sn)),
  ble_mac           text,
  firmware_version  text,
  status            text not null default 'in_stock'
                      check (status in ('in_stock', 'assigned', 'faulty', 'lost', 'retired')),
  notes             text,
  created_at        timestamptz not null default now()
);

create table public.device_assignments (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references public.organizations(id),
  device_id    uuid not null references public.devices(id),
  patient_id   uuid not null references public.patients(id),
  assigned_at  timestamptz not null default now(),
  returned_at  timestamptz,
  assigned_by  uuid references auth.users(id)
);
create unique index device_assignments_one_active_per_device
  on public.device_assignments (device_id) where returned_at is null;
create unique index device_assignments_one_active_per_patient
  on public.device_assignments (patient_id) where returned_at is null;

-- ---------------------------------------------------------------------
-- Blood pressure readings
-- ---------------------------------------------------------------------
create table public.bp_readings (
  id                uuid primary key,              -- generated on the phone (idempotent upload)
  org_id            uuid not null references public.organizations(id),
  patient_id        uuid not null references public.patients(id),
  session_id        uuid,                          -- readings taken in one guided session
  measured_at       timestamptz not null,
  received_at       timestamptz not null default now(),
  systolic          int  not null check (systolic  between 40 and 300),
  diastolic         int  not null check (diastolic between 20 and 200),
  pulse             int           check (pulse     between 20 and 250),
  position          text not null default 'arm' check (position in ('arm', 'wrist')),
  source            text not null default 'hc03' check (source in ('hc03', 'manual')),
  device_id         uuid references public.devices(id),
  device_sn         text,
  firmware_version  text,
  sdk_version       text,
  app_version       text,
  entered_by        uuid references auth.users(id),
  voided            boolean not null default false,
  void_reason       text,
  voided_by         uuid references auth.users(id),
  voided_at         timestamptz,
  check (systolic > diastolic),
  check (measured_at <= received_at + interval '10 minutes')   -- no future-dated readings
);
create index on public.bp_readings (patient_id, measured_at desc);
create index on public.bp_readings (session_id);
create index on public.bp_readings (org_id, measured_at desc);

-- ---------------------------------------------------------------------
-- Alerts, notes, medications
-- ---------------------------------------------------------------------
create table public.alerts (
  id                  uuid primary key default gen_random_uuid(),
  org_id              uuid not null references public.organizations(id),
  patient_id          uuid not null references public.patients(id),
  alert_type          text not null check (alert_type in ('urgent_high', 'urgent_low', 'uncontrolled', 'nonadherence')),
  severity            text not null check (severity in ('urgent', 'routine')),
  status              text not null default 'open' check (status in ('open', 'acknowledged', 'resolved')),
  triggered_at        timestamptz not null default now(),
  trigger_session_id  uuid,
  trigger_reading_id  uuid references public.bp_readings(id),
  details             jsonb not null default '{}'::jsonb,   -- values, thresholds, rule-set version
  acknowledged_by     uuid references auth.users(id),
  acknowledged_at     timestamptz,
  resolved_by         uuid references auth.users(id),     -- null when resolved by the system
  resolved_at         timestamptz,
  resolution_note     text
);
create index on public.alerts (org_id, status, severity, triggered_at desc);
create index on public.alerts (patient_id, alert_type, status);

create table public.clinical_notes (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations(id),
  patient_id  uuid not null references public.patients(id),
  alert_id    uuid references public.alerts(id),
  author_id   uuid not null references auth.users(id),
  body        text not null check (length(body) between 1 and 10000),
  created_at  timestamptz not null default now()
);
create index on public.clinical_notes (patient_id, created_at desc);

create table public.medication_events (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references public.organizations(id),
  patient_id      uuid not null references public.patients(id),
  drug_name       text not null,
  dose            text,
  frequency       text,
  action          text not null check (action in ('start', 'change', 'stop', 'baseline')),
  effective_date  date not null,
  reason          text,
  recorded_by     uuid not null references auth.users(id),
  created_at      timestamptz not null default now()
);
create index on public.medication_events (patient_id, effective_date desc);

-- ---------------------------------------------------------------------
-- Audit log (written only by triggers)
-- ---------------------------------------------------------------------
create table public.audit_log (
  id          bigint generated always as identity primary key,
  org_id      uuid,
  actor_id    uuid,
  action      text not null,          -- INSERT / UPDATE / DELETE
  entity      text not null,          -- table name
  entity_id   text,
  details     jsonb,
  at          timestamptz not null default now()
);
create index on public.audit_log (org_id, at desc);
