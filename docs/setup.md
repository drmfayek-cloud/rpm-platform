# Setup checklist (non-technical)

## Week 1 — now

- [ ] **Connect GitHub to Claude** (claude.ai → Settings → Connectors → GitHub) and tell Claude the repository
      name (`owner/repo`). Claude pushes the code there; GitHub builds the app automatically.
- [ ] **Keep the repository private** (it contains the licensed Linktop SDK).
- [ ] Download the latest APK from GitHub → Actions and run `docs/device-test-script.md`.
- [ ] Send the clinical protocol draft to the provider's clinical lead for review.

## Week 2 — backend

- [ ] Create a free account at supabase.com and a project. **Region:** choose the one closest to the pilot
      country for now. Before any real patient data (week 7), confirm the pilot country's hosting rules —
      if data must stay in-country and Supabase has no region there, we move to self-hosted Supabase on a
      local cloud (same code, no app changes).
- [ ] In the project: Database → Extensions → enable **pg_cron** (runs the hourly alert checks).
- [ ] Share with Claude: the project URL and the **anon** key (Settings → API). **Never share the
      service_role key in chat** — it bypasses all security rules; it goes into GitHub secrets only.

## Before go-live (weeks 5–7)

- [ ] Clinical lead signs off alert thresholds (recorded in the rule set: name + date).
- [ ] Data-processing agreement and patient consent text agreed with the provider.
- [ ] Release signing key for the Android app created and stored in GitHub secrets (Claude will guide).
- [ ] Kit phones bought, app installed, each phone paired to its HC03 and labelled.
