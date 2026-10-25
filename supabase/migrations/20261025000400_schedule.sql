-- =====================================================================
-- Schedule the control/adherence evaluation hourly.
-- On Supabase, enable the "pg_cron" extension first
-- (Dashboard → Database → Extensions). Skipped silently where pg_cron
-- is not available (e.g. local test databases).
-- =====================================================================
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule(
      'rpm-evaluate-control-adherence',
      '7 * * * *',                                   -- every hour at :07
      $job$ select public.evaluate_control_and_adherence(); $job$
    );
  else
    raise notice 'pg_cron not installed: schedule public.evaluate_control_and_adherence() manually';
  end if;
end $$;
