create table if not exists public.external_event_snapshots (
  id bigint generated always as identity primary key,
  cache_key text not null,
  intent text not null,
  quality text not null default 'fast',
  country_code text not null default 'US',
  display_name text not null default '',
  city text,
  state text,
  postal_code text,
  latitude double precision,
  longitude double precision,
  bucket_latitude double precision,
  bucket_longitude double precision,
  event_count integer not null default 0,
  exclusive_count integer not null default 0,
  nightlife_count integer not null default 0,
  snapshot jsonb not null,
  fetched_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '2 days'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists idx_external_event_snapshots_key
  on public.external_event_snapshots (cache_key, intent);

create index if not exists idx_external_event_snapshots_expires
  on public.external_event_snapshots (expires_at);

create index if not exists idx_external_event_snapshots_country_state
  on public.external_event_snapshots (country_code, state);

create index if not exists idx_external_event_snapshots_coords
  on public.external_event_snapshots (latitude, longitude);

create index if not exists idx_external_event_snapshots_bucket_coords
  on public.external_event_snapshots (bucket_latitude, bucket_longitude);

alter table public.external_event_snapshots enable row level security;

create policy "anon_read_snapshots"
  on public.external_event_snapshots
  for select
  to anon
  using (true);

create policy "anon_insert_snapshots"
  on public.external_event_snapshots
  for insert
  to anon
  with check (true);

create policy "anon_update_snapshots"
  on public.external_event_snapshots
  for update
  to anon
  using (true)
  with check (true);

create or replace function public.upsert_external_event_snapshot(
  p_cache_key text,
  p_intent text,
  p_quality text default 'fast',
  p_country_code text default 'US',
  p_display_name text default '',
  p_city text default null,
  p_state text default null,
  p_postal_code text default null,
  p_latitude double precision default null,
  p_longitude double precision default null,
  p_bucket_latitude double precision default null,
  p_bucket_longitude double precision default null,
  p_event_count integer default 0,
  p_exclusive_count integer default 0,
  p_nightlife_count integer default 0,
  p_snapshot jsonb default '{}'::jsonb,
  p_fetched_at timestamptz default now(),
  p_expires_at timestamptz default (now() + interval '2 days')
)
returns void
language plpgsql
security definer
as $$
begin
  insert into public.external_event_snapshots (
    cache_key, intent, quality, country_code, display_name,
    city, state, postal_code,
    latitude, longitude, bucket_latitude, bucket_longitude,
    event_count, exclusive_count, nightlife_count,
    snapshot, fetched_at, expires_at, updated_at
  ) values (
    p_cache_key, p_intent, p_quality, p_country_code, p_display_name,
    p_city, p_state, p_postal_code,
    p_latitude, p_longitude, p_bucket_latitude, p_bucket_longitude,
    p_event_count, p_exclusive_count, p_nightlife_count,
    p_snapshot, p_fetched_at, p_expires_at, now()
  )
  on conflict (cache_key, intent) do update set
    quality = excluded.quality,
    country_code = excluded.country_code,
    display_name = excluded.display_name,
    city = excluded.city,
    state = excluded.state,
    postal_code = excluded.postal_code,
    latitude = excluded.latitude,
    longitude = excluded.longitude,
    bucket_latitude = excluded.bucket_latitude,
    bucket_longitude = excluded.bucket_longitude,
    event_count = excluded.event_count,
    exclusive_count = excluded.exclusive_count,
    nightlife_count = excluded.nightlife_count,
    snapshot = excluded.snapshot,
    fetched_at = excluded.fetched_at,
    expires_at = excluded.expires_at,
    updated_at = now();
end;
$$;
