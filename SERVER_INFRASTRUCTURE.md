# SideQuest Server Infrastructure Reference

This file documents all external server services so context is preserved across conversations.

---

## 1. Fly.io — Ingestion Worker

| Field | Value |
|-------|-------|
| App Name | `sidequest-ingestion-worker` |
| URL | `https://sidequest-ingestion-worker.fly.dev` |
| Region | `lax` (Los Angeles) |
| VM | shared-cpu-1x, 1GB RAM |
| Status | **Deployed & running** (24/7) |
| Last Deploy | 2026-03-20 |
| Source | `backend/` directory (deployed to Fly, NOT in local repo) |
| Runtime | Node/TypeScript (Hono + custom worker) |
| Auth | `flyctl auth login --email tymcniff@gmail.com` |

### What It Does

The Fly.io worker is the **primary scraping engine**. It polls Supabase for refresh jobs and processes them sequentially:

1. **Claims a job** from `refresh_jobs` table (atomic `FOR UPDATE SKIP LOCKED`)
2. **Fetches events** from Ticketmaster and Eventbrite APIs
3. **Scrapes nightlife venues** from Discotech, Clubbable, and HWood Rolodex (HTML scraping)
4. **Enriches with Google Reviews** (HTML scraping, no API key needed)
5. **Deduplicates and normalizes** events
6. **Writes snapshot** to `external_event_snapshots` in Supabase
7. **Materializes viewport tiles** into `external_event_viewport_tiles` for z/x/y map exploration reads
8. **Records metrics** to `source_health` and `coverage_metrics`

### Nightlife Scraping (Discotech + Clubbable)

The server-side nightlife adapter (`backend/worker/adapters/nightlife-enrichment.ts`) scrapes:

- **Discotech**: Market pages (`discotech.me/{market}/`), individual venue pages (up to 18 per market), celebrity mentions, hot lists, Q&A pairs, gallery images, guest list/bottle service info
- **Clubbable**: Market pages (`clubbable.com/{market}`), individual venue pages (up to 16 per market), structured data, table prices, age minimums, gallery images
- **HWood Rolodex**: Guest list venues, table booking venues, hotspot venues (LA only)

Supported markets: LA, NYC, Miami, Las Vegas, Chicago, Austin, Nashville, Dallas, Houston, Atlanta, Denver, Scottsdale, Phoenix, Boston, Philadelphia, Seattle, New Orleans, Washington DC, San Francisco, San Diego, Sacramento, Orlando, Tampa, San Antonio

### API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check |
| `/api/trigger-refresh` | POST | Trigger refresh for a specific metro (`{"metro_slug":"los-angeles","intent":"nearby_and_worth_it"}`) |
| `/api/trigger-backfill` | POST | Backfill all metros up to a tier (`{"tier":2}`) |
| `/api/ingestion/status` | GET | Job queue stats, recent run metrics, metro count |
| `/api/ingestion/source-health` | GET | Per-source success rates and latency |
| `/api/debug/test-review?venue=X&city=Y&state=Z` | GET | Test Google review scraping for a venue |
| `/api/debug/check-venue-rating?venue=X` | GET | Check cached rating for a venue |
| `/api/debug/clear-review-cache` | POST | Clear all cached reviews |
| `/api/debug/clear-poisoned-reviews` | POST | Clear poisoned/low-rating reviews |
| `/api/debug/scrape-and-cache` | POST | Scrape a venue's reviews and cache them |

### Metro Tiers & Scheduling

| Tier | Refresh Interval | Cities |
|------|-----------------|--------|
| 1 (top) | 60-90 min | LA, NYC, Miami, Chicago, Las Vegas, Austin, Nashville |
| 2 (mid) | 120-180 min | Dallas, Houston, Atlanta, SF, Seattle, Denver, Boston |
| 3 (long-tail) | 240-360 min | Orlando, Tampa, Minneapolis, Charlotte, Detroit |

### Discovery Intents

Each metro is scraped with multiple intents:
- `nearby_and_worth_it` — General local events (TTL 96h)
- `biggest_tonight` — High-capacity/popular events (TTL 48h)
- `exclusive_hot` — VIP/exclusive nightlife (TTL 72h)
- `last_minute_plans` — Same-day events (TTL 24h)

### Environment Variables (on Fly.io)

Set via `flyctl secrets set`:
- `SUPABASE_URL` — Supabase project URL
- `SUPABASE_SERVICE_ROLE_KEY` — Service role key (full access)
- `TICKETMASTER_API_KEY` — Ticketmaster Discovery API
- `EVENTBRITE_PRIVATE_TOKEN` — Eventbrite OAuth token
- `APIFY_API_TOKEN` — Apify token for Google Events
- `WORKER_ID` — Worker identity for job claiming
- `POLL_INTERVAL_MS` — Job poll interval (default 10000)
- `MAX_CONCURRENT_JOBS` — Max parallel jobs (default 2)

### Useful Commands

```bash
# Install flyctl
curl -sL https://fly.io/install.sh | sh
export PATH="/home/user/.fly/bin:$PATH"

# Login
flyctl auth login --email tymcniff@gmail.com

# Check status
flyctl status -a sidequest-ingestion-worker
flyctl logs -a sidequest-ingestion-worker

# SSH into the worker
flyctl ssh console -a sidequest-ingestion-worker

# Check API
curl https://sidequest-ingestion-worker.fly.dev/health
curl https://sidequest-ingestion-worker.fly.dev/api/ingestion/status

# Trigger a refresh
curl -X POST https://sidequest-ingestion-worker.fly.dev/api/trigger-refresh \
  -H "Content-Type: application/json" \
  -d '{"metro_slug":"los-angeles","intent":"nearby_and_worth_it"}'

# Backfill all tier 1+2 metros
curl -X POST https://sidequest-ingestion-worker.fly.dev/api/trigger-backfill \
  -H "Content-Type: application/json" \
  -d '{"tier":2}'
```

---

## 2. Supabase — Database & Auth

| Field | Value |
|-------|-------|
| Access | Via `EXPO_PUBLIC_SUPABASE_URL` and `EXPO_PUBLIC_SUPABASE_ANON_KEY` in Config.swift |
| Auth | `tymcniff@gmail.com` on supabase.com dashboard |

### Tables

| Table | Purpose | Writer | Reader |
|-------|---------|--------|--------|
| `external_event_snapshots` | Pre-warmed event/venue snapshots per metro+intent | Fly.io worker | iOS app |
| `external_event_viewport_tiles` | Precomputed z/x/y viewport tile bundles for map exploration | Fly.io worker | iOS app |
| `ingestion_metros` | Which metros to scrape, with tier and refresh intervals | Admin | Fly.io worker |
| `refresh_jobs` | Job queue with claiming, heartbeats, retries, backoff | Fly.io scheduler | Fly.io worker |
| `refresh_runs` | Execution history for observability | Fly.io worker | Admin |
| `venue_review_cache` | Server-side Google review storage with poison protection | Fly.io worker | Fly.io worker |
| `source_health` | Per-source success/failure/latency metrics | Fly.io worker | API |
| `coverage_metrics` | Metro-level event and review coverage tracking | Fly.io worker | API |
| `player_profiles` | User game profiles (level, score, gold, character) | iOS app | iOS app |

### Key RPC Functions

- `claim_refresh_job()` — Atomic job claiming
- `heartbeat_refresh_job()` — Keep-alive for running jobs
- `complete_refresh_job()` / `fail_refresh_job()` — Job lifecycle
- `reclaim_stale_jobs()` — Recover jobs from dead workers
- `enqueue_scheduled_refreshes()` — Auto-enqueue based on metro intervals
- `upsert_event_snapshot()` — Upsert event snapshots (used by iOS fallback too)
- `upsert_external_event_viewport_tile()` — Upsert precomputed viewport tile bundles keyed by intent + z/x/y tile

---

## 3. Data Flow

```
                    ┌─────────────────────────────────┐
                    │          Fly.io Worker           │
                    │  (sidequest-ingestion-worker)    │
                    │                                  │
                    │  Ticketmaster API ──┐            │
                    │  Eventbrite API ────┤            │
                    │  Discotech scrape ──┤──► Snapshot│
                    │  Clubbable scrape ──┤            │
                    │  HWood scrape ──────┤            │
                    │  Google Reviews ────┘            │
                    └──────────┬──────────────────────┘
                               │ writes snapshots
                               ▼
                    ┌──────────────────────┐
                    │      Supabase        │
                    │                      │
                    │  external_event_     │
                    │  snapshots           │
                    │  external_event_     │
                    │  viewport_tiles      │
                    │                      │
                    │  venue_review_cache  │
                    │  source_health       │
                    │  coverage_metrics    │
                    └──────────┬──────────┘
                               │ reads snapshots
                               ▼
                    ┌──────────────────────┐
                    │      iOS App         │
                    │                      │
                    │  Supabase cache read │
                    │ (snapshots + tiles)  │
                    │                      │
                    │  Ticketmaster/etc    │
                    │  API calls (fast)    │
                    │                      │
                    │  Fly.io trigger      │
                    │  (fire-and-forget    │
                    │   when cache stale)  │
                    └──────────────────────┘
```

### iOS Path (as of 2026-04-03 — NO device-side scraping)
1. Restore from local disk cache (instant if available from prior session)
2. `SupabaseEventViewportTileService` can query `external_event_viewport_tiles` by intent + z/x/y viewport range for map-camera exploration
3. `SupabaseEventFeedCacheService` continues to query `external_event_snapshots` by lat/lng bucket + intent as the compatibility fallback path
4. If a valid Supabase cache entry exists → instant display (nightlife + Ticketmaster + everything)
5. Concurrently, `ExternalEventIngestionService` fetches Ticketmaster/Google Events/Eventbrite/RunSignup APIs (fast JSON, 2-3s)
6. If Supabase cache is stale or missing, `FlyioScraperTriggerService` POSTs to Fly.io `/api/trigger-refresh` (fire-and-forget)
7. **NO device-side HTML scraping** — no Discotech, no Clubbable, no Google Reviews, no venue website scraping, no Apple Maps enrichment
8. All nightlife data comes exclusively from Supabase (populated by Fly.io server)

### What runs on-device
- Ticketmaster, Eventbrite, RunSignup, Google Events **API calls** (structured JSON, fast)
- Reading from Supabase snapshot cache and viewport tile cache
- Web Mercator viewport→tile math to request the correct z/x/y bundle window
- Fire-and-forget trigger to Fly.io when cache is stale

### What ONLY runs server-side (Fly.io)
- ALL HTML scraping: Discotech, Clubbable, HWood Rolodex, Google Reviews
- Nightlife venue discovery and enrichment
- Snapshot normalization plus viewport tile materialization for nationwide map reads
- Scheduled refresh orchestration (cron-like metro polling)
- Review poison detection and cross-validation
- Coverage metrics and source health tracking

---

## 4. Apify — Google Events & StubHub

| Field | Value |
|-------|-------|
| API Token | `apify_api_yhX54E2qHYteUQxN3s8iEpsayM2A4W2sX0xF` |
| Client ID | `ewlVnFdot0MTzKGFq` |
| Google Events Actor | `johnvc~google-events-api---access-google-events-data` |
| StubHub Actor | `benthepythondev~stubhub-scraper` |

Used by the iOS app's `GoogleEventsEventAdapter` and `StubHubEventAdapter` for on-device event fetching.

---

## 5. Third-Party API Keys (hardcoded in iOS prototype config)

| Service | Key |
|---------|-----|
| Ticketmaster | `FIi3TiBxb316X1xYP2zThM5zfKYTCgKm` (+ 3 rotation keys) |
| Ticketmaster Secret | `BwHmB1zLV698NU7V` |
| Eventbrite | `ODMX7LG7SIKPWKVARRPJ` |

These are in `ExternalEventServiceConfiguration.sideQuestPrototype()` and used as fallbacks when env vars aren't set.

---

## 6. Current Status (as of 2026-03-30)

- **Fly.io worker**: Running, healthy, actively processing jobs
- **38 metros** configured and enabled
- **176 completed jobs**, 23 pending, 1 claimed (actively processing)
- **Average job duration**: ~15 seconds
- **Average events per run**: ~115
- Nightlife venues discovered per run: 1-22 depending on market (Las Vegas highest at 22, Nashville lowest at 1)
- Review coverage: 48-77% depending on market density
