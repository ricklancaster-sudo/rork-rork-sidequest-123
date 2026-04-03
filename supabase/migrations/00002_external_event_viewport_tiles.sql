create table if not exists public.external_event_viewport_tiles (
  id bigint generated always as identity primary key,
  tile_key text not null,
  intent text not null,
  z integer not null,
  x integer not null,
  y integer not null,
  quality text not null default 'fast',
  country_code text not null default 'US',
  state text,
  bounds jsonb not null default '{}'::jsonb,
  source_snapshot_keys text[] not null default '{}',
  event_count integer not null default 0,
  exclusive_count integer not null default 0,
  nightlife_count integer not null default 0,
  snapshot jsonb not null,
  fetched_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '2 days'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists idx_external_event_viewport_tiles_key
  on public.external_event_viewport_tiles (tile_key);

create index if not exists idx_external_event_viewport_tiles_lookup
  on public.external_event_viewport_tiles (intent, z, x, y, country_code, state);

create index if not exists idx_external_event_viewport_tiles_expires
  on public.external_event_viewport_tiles (expires_at);

alter table public.external_event_viewport_tiles enable row level security;

grant select on public.external_event_viewport_tiles to anon, authenticated;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'external_event_viewport_tiles'
      and policyname = 'anon_read_viewport_tiles'
  ) then
    create policy "anon_read_viewport_tiles"
      on public.external_event_viewport_tiles
      for select
      to anon, authenticated
      using (true);
  end if;
end
$$;

create or replace function public.upsert_external_event_viewport_tile(
  p_tile_key text,
  p_intent text,
  p_z integer,
  p_x integer,
  p_y integer,
  p_quality text default 'fast',
  p_country_code text default 'US',
  p_state text default null,
  p_bounds jsonb default '{}'::jsonb,
  p_source_snapshot_keys text[] default '{}',
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
set search_path = public
as $$
begin
  insert into public.external_event_viewport_tiles (
    tile_key,
    intent,
    z,
    x,
    y,
    quality,
    country_code,
    state,
    bounds,
    source_snapshot_keys,
    event_count,
    exclusive_count,
    nightlife_count,
    snapshot,
    fetched_at,
    expires_at,
    updated_at
  ) values (
    p_tile_key,
    p_intent,
    p_z,
    p_x,
    p_y,
    p_quality,
    p_country_code,
    p_state,
    p_bounds,
    p_source_snapshot_keys,
    p_event_count,
    p_exclusive_count,
    p_nightlife_count,
    p_snapshot,
    p_fetched_at,
    p_expires_at,
    now()
  )
  on conflict (tile_key) do update set
    intent = excluded.intent,
    z = excluded.z,
    x = excluded.x,
    y = excluded.y,
    quality = excluded.quality,
    country_code = excluded.country_code,
    state = excluded.state,
    bounds = excluded.bounds,
    source_snapshot_keys = excluded.source_snapshot_keys,
    event_count = excluded.event_count,
    exclusive_count = excluded.exclusive_count,
    nightlife_count = excluded.nightlife_count,
    snapshot = excluded.snapshot,
    fetched_at = excluded.fetched_at,
    expires_at = excluded.expires_at,
    updated_at = now();
end;
$$;

revoke all on function public.upsert_external_event_viewport_tile(
  text,
  text,
  integer,
  integer,
  integer,
  text,
  text,
  text,
  jsonb,
  text[],
  integer,
  integer,
  integer,
  jsonb,
  timestamptz,
  timestamptz
) from public, anon, authenticated;

grant execute on function public.upsert_external_event_viewport_tile(
  text,
  text,
  integer,
  integer,
  integer,
  text,
  text,
  text,
  jsonb,
  text[],
  integer,
  integer,
  integer,
  jsonb,
  timestamptz,
  timestamptz
) to service_role;
