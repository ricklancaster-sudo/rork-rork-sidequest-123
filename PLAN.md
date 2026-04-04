# Fix nightlife scraper to reliably surface big clubs like Poppy, Sound, Delilah

## Problem
Big-name clubs (Poppy, Sound, Delilah, etc.) aren't showing up because the Discotech market page often fails to load, killing the only discovery path. Clubbable extraction is also too narrow. Google Events naturally favors Ticketmaster concert listings over club nights.

## What's changing

### 1. Multiple Discotech discovery fallback sources ✅
- [x] When the main market page (`discotech.me/los-angeles/`) fails, scrape these additional Discotech pages as fallback discovery sources:
  - **Guest lists page** (`/los-angeles/guest-lists/`) — lists clubs with active guest lists
  - **Bottle service page** (`/los-angeles/bottle-service/`) — lists clubs with bottle service
  - **Nightclubs category page** (`/los-angeles/nightclubs/`) — lists clubs by category
  - **Top clubs articles** (`app.discotech.me/articles/best-*-nightclubs-in-*`) — editorial venue lists (returns 36+ venues incl Poppy, Sound, Delilah)
- [x] Extract venue names and slugs from these pages, then fetch each venue's individual page for full details
- [x] This ensures big clubs are always discovered even when the main listing page is blocked

### 2. Google Search-based nightlife venue discovery ✅
- [x] Google Search discovery now ALWAYS runs in parallel with the market page (not just as fallback)
- [x] 7 search queries instead of 3: `"best nightclubs"`, `"top clubs"`, `"popular nightlife venues"`, `"hottest clubs"`, `"exclusive nightclubs"`, `"best lounges"`, `"VIP nightclubs"`
- [x] Extracted names seed Discotech individual venue page lookups
- [x] Pure scraping — no hardcoded names — reliably surfaces the biggest, most talked-about venues

### 3. Improved Clubbable URL extraction ✅
- [x] Broadened regex pattern for extracting venue URLs from Clubbable market pages (already had multiple patterns)
- [x] Support for both PascalCase and lowercase slug formats (already existed)
- [x] JSON-LD structured data scraping (`"@type": "NightClub"` blocks) for venue names (already existed)

### 4. Higher venue page limits ✅
- [x] Increase Discotech venue page limit: small queries 6→16, medium 14→24, large 32→40
- [x] Increase Clubbable venue page limit: small queries 6→16, medium 14→24, large 28→36
- [x] Increase mention expansion limit: small 3→6, medium 6→10, large 12→16
- [x] This ensures more venues are actually fetched and parsed, not just discovered

### 5. Apple Maps seed → aggregator enrichment loop ✅ (already existed)
- [x] When Apple Maps discovers a nightlife venue, automatically attempts to find and scrape its Discotech and Clubbable pages
- [x] Two-way pipeline already in place: Apple Maps finds venues, aggregators provide rich nightlife metadata

### 6. Google Events nightlife search improvements ✅ (already existed)
- [x] Nightlife-focused search channels already exist: `"nightlife tonight"`, `"club nights tonight"`, `"DJ events tonight"`, `"nightclub events tonight"`, `"exclusive nightlife tonight"`
- [x] Google Events scraper is functional and pushing data
- [x] Multiple discovery intents (biggestTonight, exclusiveHot, nearbyWorthIt) each include nightlife channels

### 7. Fix refresh state and discovery escalation ✅
- [x] `isRefreshingExternalEvents` was being set to `false` BEFORE live discovery started — UI showed empty state while scrapers were still running
- [x] Removed premature flag drop; now stays `true` until live discovery actually completes
- [x] Added automatic escalation: when preview/fast discovery returns 0 nightlife events, automatically kicks off full discovery with ALL venue adapters (Discotech, Clubbable, Apple Maps, Google Search seeding, h.wood Rolodex)
- [x] This ensures users see a loading spinner instead of "No nightlife" while scrapers work

### 8. Remove ALL device-side scraping — server-only architecture ✅
- [x] Removed ALL HTML scraping from iOS app (Discotech, Clubbable, HWood, Google Reviews, venue websites, reservation providers)
- [x] Removed venue discovery (`ExternalVenueDiscoveryService`) from `ExternalLiveLocationDiscoveryService.discover()` — all modes now API-only
- [x] Removed Google review enrichment and source page image enrichment from device
- [x] Removed "full escalation" that triggered 30-60s device-side scraping when nightlife count was low
- [x] All discovery modes now equivalent to `.fast` — only Ticketmaster, Eventbrite, RunSignup, Google Events API calls (2-3 seconds)
- [x] Created `FlyioScraperTriggerService` — fire-and-forget POST to `https://sidequest-ingestion-worker.fly.dev/api/trigger-refresh` when Supabase cache is stale
- [x] Nightlife data now comes EXCLUSIVELY from Supabase cache (populated by Fly.io server scraper)
- [x] Nightlife loads at the same speed as Ticketmaster events — instant from Supabase cache
- [x] Updated `SERVER_INFRASTRUCTURE.md` to reflect new architecture

### 9. Viewport-based map population for Snapchat-style exploration ✅
- [x] Capture the full visible map viewport from `MKMapView.visibleMapRect` instead of relying on the center radius alone
- [x] Drive POI tile requests from viewport corners + edge midpoints so zoomed-out map exploration populates the whole camera view, not just the middle
- [x] Lower viewport reload sensitivity and preserve cached tiles during pan/zoom so map exploration feels instant with no visible loading state
- [x] Expand max zoom-out distance substantially so the map can roam much farther without feeling artificially constrained

### 10. Server/data foundation for viewport tile feed ✅
- [x] Add Supabase migration for `external_event_viewport_tiles` with tile-key uniqueness, viewport metadata, TTLs, and service-role upsert RPC
- [x] Add shared Swift models for slippy-map viewport tile keys, bounds, ranges, and tile bundle payloads
- [x] Add `SupabaseEventViewportTileService` so the iOS app can request z/x/y viewport bundles from Supabase instead of only center/radius snapshot buckets
- [x] Define deterministic Web Mercator tile math (`recommendedZoom`, viewport→tile range, tile→bounds) so the server and app can speak the same tile contract
- [x] Keep the existing snapshot cache path available as a compatibility fallback while the tile-backed feed is rolled out

### 11. iOS event map now consumes the viewport tile feed ✅
- [x] Refactor `MapExploreView` to hydrate map events from `SupabaseEventViewportTileService` viewport tile bundles instead of relying only on center/radius event snapshots
- [x] Preserve the existing event pins while viewport tile requests are inflight so pan/zoom exploration has no spinner-based loading UX
- [x] Filter event visibility against the current camera viewport and keep same-address grouped event consolidation intact on the map
- [x] Update `ExploreMapView` annotation syncing so map pins are diffed and reused instead of being fully torn down on every viewport refresh
- [x] Keep the older snapshot-driven event feeds as a compatibility fallback when the viewport tile feed is unavailable

### 12. POI viewport tile infrastructure — Supabase-backed POI tiles ✅
- [x] Create `POIViewportTile` models (`POIViewportTileKey`, `POIViewportTilePOI`, `POIViewportTileSnapshot`, `POIViewportTileBundle`) using same z/x/y slippy-map scheme as event tiles
- [x] Create `SupabasePOIViewportTileService` — reads POI tiles from `poi_viewport_tiles` Supabase table, writes seed tiles back when MKLocalSearch discovers new POIs
- [x] Add `scheduleViewportDrivenSupabasePOILoad` to `MapExploreView` — loads POI tiles from Supabase on every viewport change, merges into map pins alongside MKLocalSearch results
- [x] Client-side seed-back: when MKLocalSearch fills a missing tile, automatically writes POIs back to Supabase so future users get instant cached results
- [x] Remove the 16-pin POI encounter cap (`prefix(16)` → all POIs) so all cached POIs render on the map
- [x] Add `triggerPOITileRefreshIfNeeded` to `FlyioScraperTriggerService` so the Fly.io server can batch-populate POI tiles for target metros
- [x] POI tiles use same tile math, caching, and dedup patterns as event viewport tiles

## What stays the same
- No hardcoded venue names — everything is 100% scrape-driven (server-side)
- All existing lighting, camera, and lookdev in the app
- Ticketmaster, Eventbrite, RunSignup API calls still run on-device (fast structured JSON)
- Existing cache, dedup, and merge logic
- Existing snapshot cache, dedup, and merge logic stay in place alongside the new viewport tile feed foundation
- Fly.io server scraper unchanged (still does all the heavy scraping)
- MKLocalSearch still runs as fallback for tiles not yet in Supabase — seeds results back for future users
