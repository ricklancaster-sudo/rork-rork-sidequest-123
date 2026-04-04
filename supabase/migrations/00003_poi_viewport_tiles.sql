create table if not exists public.poi_viewport_tiles (
  id bigint generated always as identity primary key,
  country_code text not null default 'US',
  z integer not null,
  x integer not null,
  y integer not null,
  snapshot jsonb not null,
  poi_count integer not null default 0,
  fetched_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '1 day'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint uq_poi_viewport_tiles_coord unique (country_code, z, x, y)
);

create index if not exists idx_poi_viewport_tiles_lookup
  on public.poi_viewport_tiles (country_code, z, x, y);

create index if not exists idx_poi_viewport_tiles_expires
  on public.poi_viewport_tiles (expires_at);

alter table public.poi_viewport_tiles enable row level security;

grant select on public.poi_viewport_tiles to anon, authenticated;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'poi_viewport_tiles'
      and policyname = 'anon_read_poi_tiles'
  ) then
    create policy "anon_read_poi_tiles"
      on public.poi_viewport_tiles
      for select
      to anon, authenticated
      using (true);
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'poi_viewport_tiles'
      and policyname = 'anon_insert_poi_tiles'
  ) then
    create policy "anon_insert_poi_tiles"
      on public.poi_viewport_tiles
      for insert
      to anon, authenticated
      with check (true);
  end if;
end
$$;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'poi_viewport_tiles'
      and policyname = 'anon_update_poi_tiles'
  ) then
    create policy "anon_update_poi_tiles"
      on public.poi_viewport_tiles
      for update
      to anon, authenticated
      using (true)
      with check (true);
  end if;
end
$$;

create or replace function public.upsert_poi_viewport_tile(
  p_country_code text default 'US',
  p_z integer default 10,
  p_x integer default 0,
  p_y integer default 0,
  p_snapshot jsonb default '{}'::jsonb,
  p_poi_count integer default 0,
  p_fetched_at timestamptz default now(),
  p_expires_at timestamptz default (now() + interval '1 day')
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.poi_viewport_tiles (
    country_code, z, x, y,
    snapshot, poi_count,
    fetched_at, expires_at, updated_at
  ) values (
    p_country_code, p_z, p_x, p_y,
    p_snapshot, p_poi_count,
    p_fetched_at, p_expires_at, now()
  )
  on conflict (country_code, z, x, y) do update set
    snapshot = excluded.snapshot,
    poi_count = excluded.poi_count,
    fetched_at = excluded.fetched_at,
    expires_at = excluded.expires_at,
    updated_at = now();
end;
$$;

grant execute on function public.upsert_poi_viewport_tile(text, integer, integer, integer, jsonb, integer, timestamptz, timestamptz) to anon, authenticated, service_role;
