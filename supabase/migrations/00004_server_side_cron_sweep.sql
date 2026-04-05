-- Enable pg_cron and pg_net extensions for server-side scheduled HTTP calls
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

-- Grant necessary permissions
grant usage on schema cron to postgres;
grant all privileges on all tables in schema cron to postgres;

-- Tier 1: Top 8 metros (LA, NYC, Chicago, etc.) — every hour
select cron.schedule(
  'sweep-tier-1-metros',
  '0 * * * *',
  $$
  select net.http_post(
    url := 'https://sidequest-ingestion-worker.fly.dev/api/trigger-backfill',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := jsonb_build_object('tier', 1),
    timeout_milliseconds := 15000
  ) as request_id;
  $$
);

-- Tier 2: Top 25 metros — every 2 hours (at minute 15 to stagger)
select cron.schedule(
  'sweep-tier-2-metros',
  '15 */2 * * *',
  $$
  select net.http_post(
    url := 'https://sidequest-ingestion-worker.fly.dev/api/trigger-backfill',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := jsonb_build_object('tier', 2),
    timeout_milliseconds := 15000
  ) as request_id;
  $$
);

-- Tier 3: All 115 metros — every 4 hours (at minute 30 to stagger)
select cron.schedule(
  'sweep-tier-3-metros',
  '30 */4 * * *',
  $$
  select net.http_post(
    url := 'https://sidequest-ingestion-worker.fly.dev/api/trigger-backfill',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body := jsonb_build_object('tier', 3),
    timeout_milliseconds := 15000
  ) as request_id;
  $$
);

-- Clean up expired tiles daily at 4:00 AM UTC
select cron.schedule(
  'cleanup-expired-event-tiles',
  '0 4 * * *',
  $$
  delete from public.external_event_viewport_tiles
  where expires_at < now() - interval '6 hours';
  $$
);

select cron.schedule(
  'cleanup-expired-poi-tiles',
  '10 4 * * *',
  $$
  delete from public.poi_viewport_tiles
  where expires_at < now() - interval '6 hours';
  $$
);

-- Clean up old cron job run details (keep last 7 days)
select cron.schedule(
  'cleanup-cron-job-run-details',
  '0 5 * * *',
  $$
  delete from cron.job_run_details
  where end_time < now() - interval '7 days';
  $$
);
