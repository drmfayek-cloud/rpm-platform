# RPM platform — hypertension pilot

Remote patient monitoring for a provider-led hypertension pilot using the Linktop HC03.

> **Keep this repository private.** It contains the licensed Linktop SDK (`apps/patient_app/vendor/`).

## What's here

| Path | What it is | Status |
|---|---|---|
| `supabase/migrations/` | Database: providers, users and roles, patients, invitations, consent, devices, readings, alerts, notes, medications, audit log; security rules; alert engine; clinician worklist and pilot-metrics views | Week 1 ✅ (46 tests) |
| `supabase/tests/` | Automated tests for security, invitations, alerts and views | Week 1 ✅ |
| `apps/patient_app/` | Flutter patient app. Week 1 ships the **HC03 device test bench**; patient screens follow | Week 1 ✅ device layer |
| `apps/web/` | Doctor + admin web app | Weeks 2–6 |
| `docs/` | Setup guide, device test script, pilot clinical protocol | Week 1 ✅ |
| `.github/workflows/` | Automatic builds: Android APKs and database tests run on every change | Week 1 ✅ |

## How the pieces fit

```
 HC03 ──Bluetooth──▶ Android phone (patient app, Linktop SDK inside)
                          │  readings (HTTPS, retried offline)
                          ▼
                    Supabase (Postgres + login + security rules)
                     ├─ alert engine: urgent (on arrival), control + adherence (hourly)
                     └─ views: clinician worklist, pilot monthly metrics
                          ▲
                          │
        Web app: doctors (worklist, chart, alerts, notes) · admins (patients, devices, rules, exports)
```

## Getting the app onto a phone

1. Open the repository on GitHub → **Actions** → **Patient app (Android)** → latest green run.
2. Download the artifact `patient-app-apks-N` (a zip with two APKs):
   - `rpm-patient-hc03-N.apk` — talks to a real HC03
   - `rpm-patient-simulator-N.apk` — simulated device, for demos without hardware
3. Copy the APK to the Android phone and open it (allow "install unknown apps" once).

See `docs/device-test-script.md` for the week-1 device test.

## Database tests (developers)

```bash
supabase/tests/run_tests.sh      # needs a local PostgreSQL 15+
```
