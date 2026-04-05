import { Hono } from "hono";
import { cors } from "hono/cors";

import { testScrapeVenue } from "./worker/adapters/google-reviews";

const app = new Hono();

app.use("*", cors());

function supabaseEnv() {
  const supabaseUrl = process.env.SUPABASE_URL;
  const supabaseKey =
    process.env.SUPABASE_SERVICE_ROLE_KEY ?? process.env.SUPABASE_ANON_KEY;

  if (!supabaseUrl || !supabaseKey) {
    throw new Error("Supabase not configured");
  }

  return {
    supabaseUrl,
    headers: {
      apikey: supabaseKey,
      Authorization: `Bearer ${supabaseKey}`,
      "Content-Type": "application/json",
    },
  };
}

const DEFAULT_INTENTS = [
  "nearby_and_worth_it",
  "biggest_tonight",
  "exclusive_hot",
  "last_minute_plans",
] as const;

type MetroRecord = {
  id: string;
  slug: string;
  display_name: string;
  city?: string;
  state?: string;
  country_code?: string;
  latitude: number;
  longitude: number;
};

async function fetchJson(url: string, headers: Record<string, string>) {
  const response = await fetch(url, { headers });
  const json = await response.json().catch(() => null);
  return { response, json };
}

async function loadEnabledMetroBySlug(
  supabaseUrl: string,
  headers: Record<string, string>,
  metroSlug: string
): Promise<MetroRecord | null> {
  const { json } = await fetchJson(
    `${supabaseUrl}/rest/v1/ingestion_metros?slug=eq.${encodeURIComponent(
      metroSlug
    )}&enabled=eq.true&select=id,slug,display_name,city,state,country_code,latitude,longitude&limit=1`,
    headers
  );
  return Array.isArray(json) && json.length > 0 ? (json[0] as MetroRecord) : null;
}

async function loadEnabledMetros(
  supabaseUrl: string,
  headers: Record<string, string>
): Promise<MetroRecord[]> {
  const { json } = await fetchJson(
    `${supabaseUrl}/rest/v1/ingestion_metros?enabled=eq.true&select=id,slug,display_name,city,state,country_code,latitude,longitude`,
    headers
  );
  return Array.isArray(json) ? (json as MetroRecord[]) : [];
}

async function fetchFreshSnapshotIntents(
  supabaseUrl: string,
  headers: Record<string, string>,
  metro: MetroRecord,
  intents: readonly string[]
): Promise<Set<string>> {
  const { json } = await fetchJson(
    `${supabaseUrl}/rest/v1/external_event_snapshots?select=intent,expires_at,event_count&latitude=eq.${metro.latitude}&longitude=eq.${metro.longitude}&intent=in.(${intents.join(",")})&expires_at=gte.${new Date().toISOString()}&limit=20`,
    headers
  );
  return new Set(Array.isArray(json) ? json.map((row: any) => row.intent) : []);
}

async function fetchFreshTileIntents(
  supabaseUrl: string,
  headers: Record<string, string>,
  tile: { z: number; x: number; y: number }
): Promise<Set<string>> {
  const { json } = await fetchJson(
    `${supabaseUrl}/rest/v1/external_event_viewport_tiles?select=intent,event_count,expires_at&z=eq.${tile.z}&x=eq.${tile.x}&y=eq.${tile.y}&expires_at=gte.${new Date().toISOString()}&event_count=gt.0&limit=20`,
    headers
  );
  return new Set(Array.isArray(json) ? json.map((row: any) => row.intent) : []);
}

async function enqueueJobs(
  supabaseUrl: string,
  headers: Record<string, string>,
  jobs: Array<{ metro_id: string; intent: string; priority: number }>
): Promise<{ inserted: number; skipped: number; jobs: any[] }> {
  if (jobs.length === 0) {
    return { inserted: 0, skipped: 0, jobs: [] };
  }

  const metroIds = [...new Set(jobs.map((job) => job.metro_id))];
  const intents = [...new Set(jobs.map((job) => job.intent))];
  const { json: activeJobsJson } = await fetchJson(
    `${supabaseUrl}/rest/v1/refresh_jobs?select=metro_id,intent,status&status=in.(pending,claimed)&metro_id=in.(${metroIds.join(",")})&intent=in.(${intents.join(",")})&limit=1000`,
    headers
  );

  const activeKeys = new Set(
    Array.isArray(activeJobsJson)
      ? activeJobsJson.map((row: any) => `${row.metro_id}::${row.intent}`)
      : []
  );

  const dedupedJobs = jobs.filter(
    (job) => !activeKeys.has(`${job.metro_id}::${job.intent}`)
  );
  if (dedupedJobs.length === 0) {
    return { inserted: 0, skipped: jobs.length, jobs: [] };
  }

  const response = await fetch(`${supabaseUrl}/rest/v1/refresh_jobs`, {
    method: "POST",
    headers: {
      ...headers,
      Prefer: "return=representation",
    },
    body: JSON.stringify(dedupedJobs),
  });

  if (!response.ok) {
    throw new Error(`Failed to enqueue jobs (${response.status})`);
  }

  const insertedJobs = await response.json().catch(() => []);
  return {
    inserted: Array.isArray(insertedJobs) ? insertedJobs.length : dedupedJobs.length,
    skipped: jobs.length - dedupedJobs.length,
    jobs: Array.isArray(insertedJobs) ? insertedJobs : [],
  };
}

function tileFromLatLon(lat: number, lon: number, zoom: number) {
  const scale = Math.pow(2, zoom);
  const normalizedLon = Math.min(Math.max((lon + 180) / 360, 0), 0.999999999);
  const x = Math.floor(normalizedLon * scale);
  const clampedLat = Math.min(Math.max(lat, -85.05112878), 85.05112878);
  const radians = (clampedLat * Math.PI) / 180;
  const mercator = Math.log(Math.tan(Math.PI / 4 + radians / 2));
  const normalizedLat = Math.min(Math.max((1 - mercator / Math.PI) / 2, 0), 0.999999999);
  const y = Math.floor(normalizedLat * scale);
  return { z: zoom, x, y };
}

function tileCenter(z: number, x: number, y: number) {
  const scale = Math.pow(2, z);
  const lon = ((x + 0.5) / scale) * 360 - 180;
  const mercatorVal = Math.PI - (2 * Math.PI * (y + 0.5)) / scale;
  const lat = (Math.atan(Math.sinh(mercatorVal)) * 180) / Math.PI;
  return { lat, lon };
}

function haversineMiles(
  lat1: number,
  lon1: number,
  lat2: number,
  lon2: number
): number {
  const toRadians = (value: number) => (value * Math.PI) / 180;
  const dLat = toRadians(lat2 - lat1);
  const dLon = toRadians(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(toRadians(lat1)) *
      Math.cos(toRadians(lat2)) *
      Math.sin(dLon / 2) *
      Math.sin(dLon / 2);
  return 3958.8 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function selectCoverageMetros(
  metros: MetroRecord[],
  latitude: number,
  longitude: number,
  maxMiles: number,
  maxCount: number
): MetroRecord[] {
  return metros
    .map((metro) => ({
      metro,
      distanceMiles: haversineMiles(latitude, longitude, metro.latitude, metro.longitude),
    }))
    .filter((entry) => entry.distanceMiles <= maxMiles)
    .sort((a, b) => a.distanceMiles - b.distanceMiles)
    .slice(0, maxCount)
    .map((entry) => entry.metro);
}

app.get("/", (c) => {
  return c.json({ status: "ok", message: "SideQuest Ingestion API" });
});

app.get("/health", (c) => {
  return c.json({ status: "ok", timestamp: new Date().toISOString() });
});

app.post("/api/trigger-refresh", async (c) => {
  const body = await c.req.json().catch(() => ({}));
  const metroSlug = body.metro_slug;
  const intent = body.intent || "nearby_and_worth_it";

  if (!metroSlug) {
    return c.json({ error: "metro_slug is required" }, 400);
  }

  try {
    const { supabaseUrl, headers } = supabaseEnv();
    const metro = await loadEnabledMetroBySlug(supabaseUrl, headers, metroSlug);
    if (!metro) {
      return c.json({ error: "Metro not found" }, 404);
    }

    const enqueueResult = await enqueueJobs(supabaseUrl, headers, [
      {
        metro_id: metro.id,
        intent,
        priority: 1,
      },
    ]);
    return c.json({
      status: enqueueResult.inserted > 0 ? "enqueued" : "already_pending",
      metro,
      inserted: enqueueResult.inserted,
      skipped: enqueueResult.skipped,
      jobs: enqueueResult.jobs,
    });
  } catch (err) {
    return c.json({ error: String(err) }, 500);
  }
});

app.post("/api/trigger-backfill", async (c) => {
  const body = await c.req.json().catch(() => ({}));
  const tier = Number(body.tier ?? 1);

  try {
    const { supabaseUrl, headers } = supabaseEnv();
    const { json: metrosJson } = await fetchJson(
      `${supabaseUrl}/rest/v1/ingestion_metros?enabled=eq.true&tier=lte.${tier}&select=id,slug&order=tier.asc`,
      headers
    );
    const metros = metrosJson;
    if (!Array.isArray(metros)) {
      return c.json({ error: "Failed to fetch metros" }, 500);
    }

    const jobs = metros.flatMap((metro: { id: string }) =>
      DEFAULT_INTENTS.map((intent) => ({
        metro_id: metro.id,
        intent,
        priority: 2,
      }))
    );

    const enqueueResult = await enqueueJobs(supabaseUrl, headers, jobs);

    return c.json({
      status: "backfill_enqueued",
      metro_count: metros.length,
      job_count: enqueueResult.inserted,
      skipped_jobs: enqueueResult.skipped,
    });
  } catch (err) {
    return c.json({ error: String(err) }, 500);
  }
});

app.get("/api/ingestion/status", async (c) => {
  try {
    const { supabaseUrl, headers } = supabaseEnv();

    const [jobsRes, runsRes, metrosRes] = await Promise.all([
      fetch(
        `${supabaseUrl}/rest/v1/refresh_jobs?select=status&order=created_at.desc&limit=200`,
        { headers }
      ),
      fetch(
        `${supabaseUrl}/rest/v1/refresh_runs?select=status,duration_ms,event_count,review_hit_count,review_miss_count&order=started_at.desc&limit=50`,
        { headers }
      ),
      fetch(
        `${supabaseUrl}/rest/v1/ingestion_metros?select=slug,tier,last_refresh_at,enabled&enabled=eq.true&order=tier.asc`,
        { headers }
      ),
    ]);

    const jobs = await jobsRes.json();
    const runs = await runsRes.json();
    const metros = await metrosRes.json();

    const jobsByStatus: Record<string, number> = {};
    if (Array.isArray(jobs)) {
      for (const job of jobs) {
        jobsByStatus[job.status] = (jobsByStatus[job.status] || 0) + 1;
      }
    }

    const recentRuns = Array.isArray(runs) ? runs.slice(0, 20) : [];
    const avgDuration =
      recentRuns.length > 0
        ? Math.round(
            recentRuns.reduce(
              (sum: number, run: any) => sum + (run.duration_ms || 0),
              0
            ) / recentRuns.length
          )
        : 0;
    const totalEvents = recentRuns.reduce(
      (sum: number, run: any) => sum + (run.event_count || 0),
      0
    );

    return c.json({
      jobs: jobsByStatus,
      recent_runs: {
        count: recentRuns.length,
        avg_duration_ms: avgDuration,
        total_events: totalEvents,
      },
      metros: Array.isArray(metros) ? metros.length : 0,
    });
  } catch (err) {
    return c.json({ error: String(err) }, 500);
  }
});

app.get("/api/ingestion/source-health", async (c) => {
  try {
    const { supabaseUrl, headers } = supabaseEnv();
    const response = await fetch(
      `${supabaseUrl}/rest/v1/source_health?select=source,request_count,success_count,failure_count,timeout_count,event_count,avg_latency_ms&order=window_start.desc&limit=100`,
      { headers }
    );

    if (!response.ok) {
      return c.json(
        { error: `Failed to load source health (${response.status})` },
        500
      );
    }

    const rows = await response.json();
    const bySource: Record<string, any> = {};

    if (Array.isArray(rows)) {
      for (const row of rows) {
        if (!bySource[row.source]) {
          bySource[row.source] = {
            total_requests: 0,
            total_successes: 0,
            total_failures: 0,
            total_timeouts: 0,
            total_events: 0,
            avg_latency_ms: 0,
            windows: 0,
          };
        }

        const source = bySource[row.source];
        source.total_requests += row.request_count || 0;
        source.total_successes += row.success_count || 0;
        source.total_failures += row.failure_count || 0;
        source.total_timeouts += row.timeout_count || 0;
        source.total_events += row.event_count || 0;
        source.avg_latency_ms += row.avg_latency_ms || 0;
        source.windows++;
      }

      for (const sourceName of Object.keys(bySource)) {
        const source = bySource[sourceName];
        source.success_rate =
          source.total_requests > 0
            ? ((source.total_successes / source.total_requests) * 100).toFixed(
                1
              ) + "%"
            : "N/A";
        source.avg_latency_ms =
          source.windows > 0
            ? Math.round(source.avg_latency_ms / source.windows)
            : 0;
      }
    }

    return c.json({ sources: bySource });
  } catch (err) {
    return c.json({ error: String(err) }, 500);
  }
});



app.post("/api/debug/clear-review-cache", async (c) => {
  try {
    const { supabaseUrl, headers } = supabaseEnv();
    const response = await fetch(
      supabaseUrl + "/rest/v1/venue_review_cache?select=venue_key",
      {
        method: "DELETE",
        headers: { ...headers, Prefer: "return=representation" },
      }
    );
    const deleted = await response.json().catch(() => []);
    return c.json({ status: "cleared", count: Array.isArray(deleted) ? deleted.length : 0 });
  } catch (err) {
    return c.json({ error: String(err) }, 500);
  }
});

app.post("/api/debug/clear-poisoned-reviews", async (c) => {
  try {
    const { supabaseUrl, headers } = supabaseEnv();
    const response = await fetch(
      supabaseUrl + "/rest/v1/venue_review_cache?is_poisoned=eq.true",
      {
        method: "DELETE",
        headers: { ...headers, Prefer: "return=representation" },
      }
    );
    const deleted = await response.json().catch(() => []);

    const response2 = await fetch(
      supabaseUrl + "/rest/v1/venue_review_cache?google_rating=lt.3",
      {
        method: "DELETE",
        headers: { ...headers, Prefer: "return=representation" },
      }
    );
    const deleted2 = await response2.json().catch(() => []);

    return c.json({ 
      status: "cleared", 
      poisoned: Array.isArray(deleted) ? deleted.length : 0,
      low_rating: Array.isArray(deleted2) ? deleted2.length : 0 
    });
  } catch (err) {
    return c.json({ error: String(err) }, 500);
  }
});

app.get("/api/debug/test-review", async (c) => {
  const venue = c.req.query("venue");
  const city = c.req.query("city") || "";
  const state = c.req.query("state") || "";
  const postal = c.req.query("postal") || undefined;
  if (!venue) {
    return c.json({ error: "venue query param required" }, 400);
  }
  try {
    const result = await testScrapeVenue(venue, city, state, postal);
    return c.json({ venue, city, state, result });
  } catch (err) {
    return c.json({ error: String(err) }, 500);
  }
});


app.get("/api/debug/check-venue-rating", async (c) => {
  const venue = c.req.query("venue") || "";
  try {
    const { supabaseUrl, headers } = supabaseEnv();
    const encoded = encodeURIComponent("%" + venue.replace(/ /g, "%") + "%");
    const cacheRes = await fetch(
      supabaseUrl + "/rest/v1/venue_review_cache?venue_name=ilike." + encoded + "&select=venue_key,venue_name,google_rating,google_review_count,google_maps_url,is_poisoned,poison_reason,fetched_at&limit=10",
      { headers }
    );
    const cacheData = await cacheRes.json();

    const snapshotRes = await fetch(
      supabaseUrl + "/rest/v1/external_event_snapshots?select=cache_key,snapshot&limit=5&order=fetched_at.desc&city=ilike.%25Los%20Angeles%25",
      { headers }
    );
    const snapshots = await snapshotRes.json();

    let matchingEvents: any[] = [];
    if (Array.isArray(snapshots)) {
      for (const snap of snapshots) {
        const events = snap.snapshot?.mergedEvents || snap.snapshot?.eventSnapshot?.mergedEvents || [];
        for (const event of events) {
          if (event.venueName && event.venueName.toLowerCase().includes(venue.toLowerCase())) {
            matchingEvents.push({
              title: event.title,
              venueName: event.venueName,
              venueRating: event.venueRating,
              cacheKey: snap.cache_key,
            });
          }
        }
      }
    }

    return c.json({ venue, cacheEntries: cacheData, snapshotEvents: matchingEvents.slice(0, 10) });
  } catch (err) {
    return c.json({ error: String(err) }, 500);
  }
});


app.get("/api/debug/raw-event", async (c) => {
  const venue = c.req.query("venue") || "";
  try {
    const { supabaseUrl, headers } = supabaseEnv();
    const snapshotRes = await fetch(
      supabaseUrl + "/rest/v1/external_event_snapshots?select=cache_key,snapshot&limit=2&order=fetched_at.desc&city=ilike.%25Los%20Angeles%25",
      { headers }
    );
    const snapshots = await snapshotRes.json();
    let matchingEvents: any[] = [];
    if (Array.isArray(snapshots)) {
      for (const snap of snapshots) {
        const events = snap.snapshot?.mergedEvents || [];
        for (const event of events) {
          if (event.venueName && event.venueName.toLowerCase().includes(venue.toLowerCase())) {
            matchingEvents.push({
              title: event.title,
              venueName: event.venueName,
              venueRating: event.venueRating,
              addressLine1: event.addressLine1,
              city: event.city,
              state: event.state,
              postalCode: event.postalCode,
              rawPayloadKeys: Object.keys(JSON.parse(event.rawSourcePayload || "{}")),
              googleRating: JSON.parse(event.rawSourcePayload || "{}").google_places_rating,
              cacheKey: snap.cache_key,
            });
            if (matchingEvents.length >= 3) break;
          }
        }
        if (matchingEvents.length >= 3) break;
      }
    }
    return c.json({ matchingEvents });
  } catch (err) {
    return c.json({ error: String(err) }, 500);
  }
});


app.get("/api/debug/venue-cache-lookup", async (c) => {
  const venue = c.req.query("venue") || "";
  const city = c.req.query("city") || "";
  const state = c.req.query("state") || "";
  const postal = c.req.query("postal") || "";
  
  function normalizeToken(v: string): string {
    return v.toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/[^a-z0-9\s]/g, " ").replace(/\s+/g, " ").trim();
  }
  function normalizeState(v: string): string {
    const map: Record<string, string> = { california: "ca", "new york": "ny", florida: "fl", texas: "tx" };
    const t = v.trim().toLowerCase();
    return map[t] || t;
  }
  
  const venueKey = normalizeToken(venue);
  const cityKey = normalizeToken(city);
  const stateKey = normalizeState(state);
  const postalKey = postal.replace(/\D/g, "").substring(0, 5);
  
  let key = "";
  if (venueKey && postalKey) key = "venue:" + venueKey + "|postal:" + postalKey;
  else if (venueKey && cityKey && stateKey) key = "venue:" + venueKey + "|city:" + cityKey + "|state:" + stateKey;
  else key = "venue:" + venueKey;
  
  try {
    const { supabaseUrl, headers } = supabaseEnv();
    const encoded = encodeURIComponent(key);
    const res = await fetch(
      supabaseUrl + "/rest/v1/venue_review_cache?venue_key=eq." + encoded + "&select=*",
      { headers }
    );
    const data = await res.json();
    return c.json({ computedKey: key, cacheEntries: data });
  } catch (err) {
    return c.json({ error: String(err) }, 500);
  }
});


app.post("/api/debug/scrape-and-cache", async (c) => {
  const body = await c.req.json().catch(() => ({}));
  const venue = body.venue || "";
  const city = body.city || "";
  const state = body.state || "";
  const postal = body.postal || "";
  const addressLine1 = body.addressLine1 || "";
  if (!venue) return c.json({ error: "venue required" }, 400);
  try {
    const result = await testScrapeVenue(venue, city, state, postal || undefined);
    if (!result || !result.rating) return c.json({ error: "scrape returned no result", result });

    function normalizeToken(v: string): string {
      return v.toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/[^a-z0-9\s]/g, " ").replace(/\s+/g, " ").trim();
    }
    function normalizeState(v: string): string {
      const map: Record<string, string> = { california: "ca", "new york": "ny", florida: "fl", texas: "tx", illinois: "il", nevada: "nv", georgia: "ga", tennessee: "tn" };
      return map[v.trim().toLowerCase()] || v.trim().toLowerCase();
    }
    const venueKey = normalizeToken(venue);
    const cityKey = normalizeToken(city);
    const stateKey = normalizeState(state);
    const postalKey = postal.replace(/\D/g, "").substring(0, 5);
    let key = "";
    if (venueKey && postalKey) key = "venue:" + venueKey + "|postal:" + postalKey;
    else if (venueKey && cityKey && stateKey) key = "venue:" + venueKey + "|city:" + cityKey + "|state:" + stateKey;
    else key = "venue:" + venueKey;

    const { supabaseUrl, headers } = supabaseEnv();
    const upsertRes = await fetch(supabaseUrl + "/rest/v1/venue_review_cache", {
      method: "POST",
      headers: { ...headers, Prefer: "resolution=merge-duplicates,return=representation" },
      body: JSON.stringify({
        venue_key: key,
        venue_name: venue,
        city: city || null,
        state: state || null,
        postal_code: postal || null,
        google_rating: result.rating,
        google_review_count: result.reviewCount,
        google_maps_url: result.url,
        review_source: result.source,
        is_poisoned: false,
        fetched_at: new Date().toISOString(),
        expires_at: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString(),
        updated_at: new Date().toISOString(),
      }),
    });
    const upsertData = await upsertRes.json().catch(() => null);
    return c.json({ status: "cached", key, rating: result.rating, reviewCount: result.reviewCount, url: result.url, upsertResult: upsertData });
  } catch (err) {
    return c.json({ error: String(err) }, 500);
  }
});



app.post("/api/trigger-poi-refresh", async (c) => {
  const body = await c.req.json().catch(() => ({}));
  const metroSlug = body.metro_slug;

  if (!metroSlug) {
    return c.json({ error: "metro_slug is required" }, 400);
  }

  try {
    const { supabaseUrl, headers } = supabaseEnv();

    const metroResponse = await fetch(
      `${supabaseUrl}/rest/v1/ingestion_metros?slug=eq.${encodeURIComponent(metroSlug)}&enabled=eq.true&select=id,slug,display_name,city,state,country_code,latitude,longitude&limit=1`,
      { headers }
    );

    const metros = await metroResponse.json();
    if (!Array.isArray(metros) || metros.length === 0) {
      return c.json({ error: "Metro not found" }, 404);
    }

    const metro = metros[0];
    const zoom = 12;
    const scale = Math.pow(2, zoom);

    function latLonToTile(lat: number, lon: number) {
      const normalizedLon = Math.min(Math.max((lon + 180) / 360, 0), 0.999999999);
      const x = Math.floor(normalizedLon * scale);
      const clampedLat = Math.min(Math.max(lat, -85.05112878), 85.05112878);
      const radians = (clampedLat * Math.PI) / 180;
      const mercator = Math.log(Math.tan(Math.PI / 4 + radians / 2));
      const normalizedLat = Math.min(Math.max((1 - mercator / Math.PI) / 2, 0), 0.999999999);
      const y = Math.floor(normalizedLat * scale);
      return { z: zoom, x, y };
    }

    function tileYToLat(y: number) {
      const mercator = Math.PI - (2 * Math.PI * y) / scale;
      return (Math.atan(Math.sinh(mercator)) * 180) / Math.PI;
    }

    const center = latLonToTile(metro.latitude, metro.longitude);
    const padding = 3;
    const maxTile = scale - 1;
    const tiles: Array<{ z: number; x: number; y: number }> = [];
    for (let dx = -padding; dx <= padding; dx++) {
      for (let dy = -padding; dy <= padding; dy++) {
        tiles.push({
          z: zoom,
          x: Math.min(Math.max(center.x + dx, 0), maxTile),
          y: Math.min(Math.max(center.y + dy, 0), maxTile),
        });
      }
    }

    const poiCategories = [
      "restaurant", "bar", "cafe", "nightlife", "fitness",
      "shopping", "entertainment", "arts", "outdoors", "hotel"
    ];

    let totalPOIs = 0;
    let tilesWritten = 0;

    for (const tile of tiles) {
      const westLon = (tile.x / scale) * 360 - 180;
      const eastLon = ((tile.x + 1) / scale) * 360 - 180;
      const northLat = tileYToLat(tile.y);
      const southLat = tileYToLat(tile.y + 1);
      const centerLat = (northLat + southLat) / 2;
      const centerLon = (westLon + eastLon) / 2;

      const searchUrl = `https://maps.googleapis.com/maps/api/place/nearbysearch/json?location=${centerLat},${centerLon}&radius=2000&type=establishment&key=`;

      const pois: Array<{
        id: string; name: string; latitude: number; longitude: number;
        category: string; address: string | null; specificType: string | null;
        neighborhood: string | null; locality: string | null;
        websiteURL: string | null; phoneNumber: string | null;
        placeDescription: string | null;
      }> = [];

      const snapshotPayload = {
        tile: { countryCode: metro.country_code, z: tile.z, x: tile.x, y: tile.y },
        pois,
        poiCount: pois.length,
        fetchedAt: new Date().toISOString(),
        expiresAt: new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(),
      };

      const upsertBody = {
        country_code: metro.country_code,
        z: tile.z,
        x: tile.x,
        y: tile.y,
        snapshot: snapshotPayload,
        poi_count: 0,
        fetched_at: new Date().toISOString(),
        expires_at: new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(),
      };

      const upsertRes = await fetch(
        `${supabaseUrl}/rest/v1/poi_viewport_tiles`,
        {
          method: "POST",
          headers: {
            ...headers,
            Prefer: "resolution=merge-duplicates",
          },
          body: JSON.stringify(upsertBody),
        }
      );

      if (upsertRes.ok) tilesWritten++;
    }

    return c.json({
      status: "poi_tiles_seeded",
      metro: metro.display_name,
      tiles_written: tilesWritten,
      total_tiles: tiles.length,
      zoom,
    });
  } catch (err) {
    return c.json({ error: String(err) }, 500);
  }
});


app.post("/api/trigger-metro-refresh", async (c) => {
  const body = await c.req.json().catch(() => ({}));
  const metroSlug = body.metro_slug;

  if (!metroSlug) {
    return c.json({ error: "metro_slug is required" }, 400);
  }

  try {
    const { supabaseUrl, headers } = supabaseEnv();
    const metro = await loadEnabledMetroBySlug(supabaseUrl, headers, metroSlug);
    if (!metro) {
      return c.json({ error: "Metro not found" }, 404);
    }

    const jobs = DEFAULT_INTENTS.map((intent) => ({
      metro_id: metro.id,
      intent,
      priority: 1,
    }));
    const enqueueResult = await enqueueJobs(supabaseUrl, headers, jobs);
    return c.json({
      status: enqueueResult.inserted > 0 ? "enqueued" : "already_pending",
      metro,
      job_count: enqueueResult.inserted,
      skipped_jobs: enqueueResult.skipped,
    });
  } catch (err) {
    return c.json({ error: String(err) }, 500);
  }
});

app.post("/api/trigger-tile-scrape", async (c) => {
  const body = await c.req.json().catch(() => ({}));
  const { z, x, y } = body;

  if (z == null || x == null || y == null) {
    return c.json({ error: "z, x, y are required" }, 400);
  }

  try {
    const { supabaseUrl, headers } = supabaseEnv();
    const center = tileCenter(z, x, y);
    const allMetros = await loadEnabledMetros(supabaseUrl, headers);
    if (allMetros.length === 0) {
      return c.json({ error: "No metros available" }, 404);
    }

    const coverageMetros = selectCoverageMetros(allMetros, center.lat, center.lon, 90, 3);
    if (coverageMetros.length === 0) {
      return c.json({
        status: "no_coverage",
        message: "No metro within range of this tile",
        tile: { z, x, y },
        center,
      });
    }

    const jobs = coverageMetros.flatMap((metro) =>
      DEFAULT_INTENTS.map((intent) => ({
        metro_id: metro.id,
        intent,
        priority: 0,
      }))
    );
    const enqueueResult = await enqueueJobs(supabaseUrl, headers, jobs);

    return c.json({
      status: "scrape_triggered",
      metros: coverageMetros.map((metro) => ({
        slug: metro.slug,
        display_name: metro.display_name,
      })),
      tile: { z, x, y },
      center,
      jobs_created: enqueueResult.inserted,
      skipped_jobs: enqueueResult.skipped,
    });
  } catch (err) {
    return c.json({ error: String(err) }, 500);
  }
});


app.post("/api/trigger-metro-batch", async (c) => {
  const body = await c.req.json().catch(() => ({}));
  const metroSlug = body.metro_slug;

  if (!metroSlug) {
    return c.json({ error: "metro_slug is required" }, 400);
  }

  try {
    const { supabaseUrl, headers } = supabaseEnv();
    const metro = await loadEnabledMetroBySlug(supabaseUrl, headers, metroSlug);
    if (!metro) {
      return c.json({ error: "Metro not found" }, 404);
    }

    const freshIntents = await fetchFreshSnapshotIntents(
      supabaseUrl,
      headers,
      metro,
      DEFAULT_INTENTS
    );
    const staleIntents = DEFAULT_INTENTS.filter((intent) => !freshIntents.has(intent));
    if (staleIntents.length === 0) {
      return c.json({ status: "all_fresh", metro, intents_fresh: DEFAULT_INTENTS.length });
    }

    const jobs = staleIntents.map((intent) => ({
      metro_id: metro.id,
      intent,
      priority: 0,
    }));
    const enqueueResult = await enqueueJobs(supabaseUrl, headers, jobs);
    return c.json({
      status: enqueueResult.inserted > 0 ? "batch_enqueued" : "already_pending",
      metro,
      intents_enqueued: staleIntents,
      intents_fresh: DEFAULT_INTENTS.filter((intent) => freshIntents.has(intent)),
      job_count: enqueueResult.inserted,
      skipped_jobs: enqueueResult.skipped,
    });
  } catch (err) {
    return c.json({ error: String(err) }, 500);
  }
});

app.post("/api/trigger-on-demand-tile", async (c) => {
  const body = await c.req.json().catch(() => ({}));
  const { z, x, y, lat, lon } = body;

  if ((z == null || x == null || y == null) && (lat == null || lon == null)) {
    return c.json({ error: "Provide z/x/y or lat/lon" }, 400);
  }

  try {
    const { supabaseUrl, headers } = supabaseEnv();

    let centerLat: number, centerLon: number;
    if (lat != null && lon != null) {
      centerLat = lat;
      centerLon = lon;
    } else {
      const center = tileCenter(z, x, y);
      centerLat = center.lat;
      centerLon = center.lon;
    }

    const tileZoom = 11;
    const tile = tileFromLatLon(centerLat, centerLon, tileZoom);
    const freshTileIntents = await fetchFreshTileIntents(supabaseUrl, headers, tile);
    const missingIntents = DEFAULT_INTENTS.filter((intent) => !freshTileIntents.has(intent));
    if (missingIntents.length === 0) {
      return c.json({
        status: "tiles_exist",
        tile,
        intents_fresh: DEFAULT_INTENTS.length,
      });
    }

    const allMetros = await loadEnabledMetros(supabaseUrl, headers);
    if (allMetros.length === 0) {
      return c.json({ error: "No metros available" }, 404);
    }

    const coverageMetros = selectCoverageMetros(allMetros, centerLat, centerLon, 90, 3);
    if (coverageMetros.length === 0) {
      return c.json({
        status: "no_coverage",
        message: "No metro within range",
        center: { lat: centerLat, lon: centerLon },
      });
    }

    const jobs = coverageMetros.flatMap((metro) =>
      missingIntents.map((intent) => ({
        metro_id: metro.id,
        intent,
        priority: 0,
      }))
    );
    const enqueueResult = await enqueueJobs(supabaseUrl, headers, jobs);

    return c.json({
      status: "on_demand_triggered",
      metros: coverageMetros.map((metro) => ({
        slug: metro.slug,
        display_name: metro.display_name,
      })),
      tile,
      center: { lat: centerLat, lon: centerLon },
      missing_intents: missingIntents,
      jobs_created: enqueueResult.inserted,
      skipped_jobs: enqueueResult.skipped,
    });
  } catch (err) {
    return c.json({ error: String(err) }, 500);
  }
});


export default app;
