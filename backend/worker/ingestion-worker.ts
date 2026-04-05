import { loadConfig, type WorkerConfig } from "./lib/config";
import {
  getSupabase,
  claimJob,
  heartbeatJob,
  completeJob,
  failJob,
  reclaimStaleJobs,
  enqueueScheduledRefreshes,
  getMetro,
  insertRefreshRun,
  updateRefreshRun,
  upsertSnapshot,
  recordSourceHealth,
  recordCoverageMetrics,
  upsertViewportTile,
} from "./lib/supabase";
import {
  fetchTicketmaster,
  fetchEventbrite,
  fetchGoogleEvents,
  fetchRunSignup,
  enrichEventsWithReviews,
  enrichEventsWithNightlife,
  type AdapterResult,
  type EventResult,
} from "./adapters";
import { buildSnapshot } from "./lib/snapshot-builder";
import {
  latLonToTile,
  tileBounds,
  tileKeyString,
  tilesForMetro,
  type TileKey,
} from "./lib/tile-math";
import {
  cacheKey,
  isHighDensityMetro,
  sanitizeReviewRating,
} from "./lib/normalize";

let running = false;

export async function startWorker(): Promise<void> {
  const config = loadConfig();
  const supabase = getSupabase(config);

  console.log(`[worker] Starting ${config.workerId}`);
  console.log(`[worker] Poll interval: ${config.pollIntervalMs}ms`);
  console.log(`[worker] Max concurrent: ${config.maxConcurrentJobs}`);

  running = true;
  let schedulerTickCount = 0;

  const schedulerLoop = setInterval(async () => {
    schedulerTickCount++;

    const reclaimed = await reclaimStaleJobs(
      supabase,
      config.heartbeatTimeoutMinutes
    );
    if (reclaimed > 0) {
      console.log(`[scheduler] Reclaimed ${reclaimed} stale jobs`);
    }

    if (schedulerTickCount % 6 === 0) {
      const enqueued = await enqueueScheduledRefreshes(supabase);
      if (enqueued > 0) {
        console.log(`[scheduler] Enqueued ${enqueued} scheduled refreshes`);
      }
    }
  }, 60_000);

  const enqueued = await enqueueScheduledRefreshes(supabase);
  console.log(`[scheduler] Initial enqueue: ${enqueued} jobs`);

  const activeJobs: Set<Promise<void>> = new Set();

  while (running) {
    try {
      if (activeJobs.size < config.maxConcurrentJobs) {
        const job = await claimJob(supabase, config.workerId);

        if (job) {
          console.log(
            `[worker] Claimed job ${job.id} (metro=${job.metro_id}, intent=${job.intent}) [${activeJobs.size + 1}/${config.maxConcurrentJobs} slots]`
          );

          const metro = await getMetro(supabase, job.metro_id);
          if (!metro) {
            console.error(`[worker] Metro ${job.metro_id} not found`);
            await failJob(supabase, job.id, config.workerId, "Metro not found");
            continue;
          }

          const jobPromise = (async () => {
            const heartbeatInterval = setInterval(async () => {
              await heartbeatJob(supabase, job.id, config.workerId);
            }, config.heartbeatIntervalMs);

            try {
              await processJob(config, supabase, job, metro);
              await completeJob(supabase, job.id, config.workerId);
              trackJobCompleted();
              console.log(
                `[worker] Completed job ${job.id} (${metro.display_name} / ${job.intent}) [${activeJobs.size - 1}/${config.maxConcurrentJobs} slots]`
              );
            } catch (err) {
              const msg = err instanceof Error ? err.message : String(err);
              console.error(`[worker] Job ${job.id} failed: ${msg}`);
              trackJobFailed();
              await failJob(supabase, job.id, config.workerId, msg);
            } finally {
              clearInterval(heartbeatInterval);
            }
          })();

          activeJobs.add(jobPromise);
          jobPromise.finally(() => activeJobs.delete(jobPromise));
          continue;
        }
      }

      if (activeJobs.size === 0) {
        await sleep(config.pollIntervalMs);
      } else if (activeJobs.size >= config.maxConcurrentJobs) {
        await Promise.race([...activeJobs, sleep(2000)]);
      } else {
        await sleep(2000);
      }
    } catch (err) {
      console.error("[worker] Loop error:", err);
      await sleep(5000);
    }
  }

  if (activeJobs.size > 0) {
    console.log(`[worker] Waiting for ${activeJobs.size} active jobs to finish...`);
    await Promise.allSettled([...activeJobs]);
  }

  clearInterval(schedulerLoop);
  console.log("[worker] Stopped");
}

export function stopWorker(): void {
  running = false;
}

async function processJob(
  config: WorkerConfig,
  supabase: ReturnType<typeof getSupabase>,
  job: { id: string; metro_id: string; intent: string },
  metro: NonNullable<Awaited<ReturnType<typeof getMetro>>>
): Promise<void> {
  const startTime = Date.now();

  const runId = await insertRefreshRun(supabase, {
    job_id: job.id,
    metro_id: job.metro_id,
    worker_id: config.workerId,
    intent: job.intent,
  });

  const adapterResults: AdapterResult[] = [];
  const notes: string[] = [];

  const settledAdapterResults = await Promise.allSettled([
    config.ticketmasterApiKey
      ? fetchTicketmaster(metro, job.intent, config.ticketmasterApiKey)
      : Promise.resolve(emptyAdapterResult("ticketmaster", "No API key")),
    fetchEventbrite(metro, job.intent, config.eventbriteToken),
    fetchGoogleEvents(metro, job.intent),
    fetchRunSignup(metro, job.intent),
  ]);

  const adapterLabels = ["Ticketmaster", "Eventbrite", "Google Events", "RunSignup"];
  for (let index = 0; index < settledAdapterResults.length; index++) {
    const settled = settledAdapterResults[index];
    if (settled.status === "fulfilled") {
      adapterResults.push(settled.value);
      notes.push(...settled.value.notes);
    } else {
      notes.push(`${adapterLabels[index]} adapter error: ${String(settled.reason)}`);
    }
  }

  let allEvents: EventResult[] = [];
  const eventsBySource = new Map<string, EventResult[]>();

  for (const result of adapterResults) {
    allEvents.push(...result.events);
    const existing = eventsBySource.get(result.source) || [];
    existing.push(...result.events);
    eventsBySource.set(result.source, existing);

    await recordSourceHealth(supabase, {
      source: result.source,
      metro_id: job.metro_id,
      request_count: result.requestCount,
      success_count: result.successCount,
      failure_count: result.failureCount,
      timeout_count: result.timeoutCount,
      event_count: result.events.length,
      avg_latency_ms: result.avgLatencyMs,
    });
  }

  console.log(
    `[worker] ${metro.display_name}: ${allEvents.length} raw events from ${adapterResults.length} sources`
  );

  const nightlifeResult = await enrichEventsWithNightlife(
    allEvents,
    metro,
    config
  );
  allEvents = nightlifeResult.events;
  notes.push(...nightlifeResult.notes);
  if (nightlifeResult.venueCount > 0) {
    console.log(
      `[worker] ${metro.display_name}: ${nightlifeResult.venueCount} nightlife venues discovered`
    );
  }

  const reviewResult = await enrichEventsWithReviews(
    allEvents,
    config,
    supabase
  );
  allEvents = reviewResult.events;

  for (const [source, events] of eventsBySource) {
    const enrichedForSource = allEvents.filter((e) => e.source === source);
    eventsBySource.set(source, enrichedForSource);
  }

  const nightlifeEvents = allEvents.filter(
    (e) => e.source === "discotech" || e.source === "clubbable" || e.source === "hwood"
  );
  if (nightlifeEvents.length > 0) {
    for (const event of nightlifeEvents) {
      const existing = eventsBySource.get(event.source) || [];
      existing.push(event);
      eventsBySource.set(event.source, existing);
    }
  }

  const snapshot = buildSnapshot(metro, job.intent, eventsBySource, notes);

  const isHighDensity = isHighDensityMetro(metro.city);
  const key = cacheKey(
    job.intent,
    metro.country_code,
    metro.latitude,
    metro.longitude,
    isHighDensity
  );

  const ttlHours = ttlForIntent(job.intent);
  const fetchedAt = new Date().toISOString();
  const expiresAt = new Date(
    Date.now() + ttlHours * 60 * 60 * 1000
  ).toISOString();

  const nightlifeCount = snapshot.mergedEvents.filter(
    (e) => e.eventType === "party / nightlife"
  ).length;
  const exclusiveCount = snapshot.mergedEvents.filter((e) => {
    const payload = JSON.parse(e.rawSourcePayload || "{}");
    return (
      e.eventType === "party / nightlife" &&
      (payload.discotech_url || payload.clubbable_url)
    );
  }).length;

  const reviewEligible = snapshot.mergedEvents.filter(
    (e) => e.eventType !== "party / nightlife"
  );
  const reviewCovered = reviewEligible.filter(
    (e) => sanitizeReviewRating(e.venueRating) !== null
  );
  const reviewCoveragePct =
    reviewEligible.length > 0
      ? reviewCovered.length / reviewEligible.length
      : 0;

  const bucket = {
    latitude:
      Math.round(metro.latitude / (isHighDensity ? 0.12 : 0.08)) *
      (isHighDensity ? 0.12 : 0.08),
    longitude:
      Math.round(metro.longitude / (isHighDensity ? 0.12 : 0.08)) *
      (isHighDensity ? 0.12 : 0.08),
  };

  const snapshotStored = await upsertSnapshot(supabase, {
    cache_key: key,
    intent: job.intent,
    quality: "full",
    country_code: metro.country_code,
    display_name: metro.display_name,
    city: metro.city,
    state: metro.state,
    postal_code: metro.postal_code ?? undefined,
    latitude: metro.latitude,
    longitude: metro.longitude,
    bucket_latitude: bucket.latitude,
    bucket_longitude: bucket.longitude,
    event_count: snapshot.mergedEvents.length,
    exclusive_count: exclusiveCount,
    nightlife_count: nightlifeCount,
    snapshot,
    fetched_at: fetchedAt,
    expires_at: expiresAt,
    worker_id: config.workerId,
    run_id: runId ?? undefined,
    review_coverage_pct: reviewCoveragePct,
    is_server_generated: true,
  });
  if (!snapshotStored) {
    throw new Error(`Failed to persist snapshot for ${metro.display_name}/${job.intent}`);
  }

  try {
    const tileZoom = 11;
    const tilePadding = isHighDensity ? 4 : 3;
    const eventsWithCoords = snapshot.mergedEvents.filter(
      (e: any) => typeof e.latitude === "number" && typeof e.longitude === "number"
    );
    const tiles = buildViewportTileCoverage(
      metro.latitude,
      metro.longitude,
      eventsWithCoords,
      tileZoom,
      tilePadding,
      isHighDensity ? 1 : 0,
      isHighDensity ? 225 : 144
    );

    let tileSuccessCount = 0;
    let tileFailureCount = 0;

    await runWithConcurrency(8, tiles, async (tile) => {
      const bounds = tileBounds(tile);
      const tileEvents = eventsWithCoords.filter((e: any) =>
        e.latitude >= bounds.southLatitude &&
        e.latitude <= bounds.northLatitude &&
        e.longitude >= bounds.westLongitude &&
        e.longitude <= bounds.eastLongitude
      );

      const tileKey = tileKeyString(
        job.intent, metro.country_code, metro.state, tile.z, tile.x, tile.y
      );

      const tileNightlife = tileEvents.filter(
        (e: any) => e.eventType === "party / nightlife"
      ).length;
      const tileExclusive = tileEvents.filter((e: any) => {
        const payload = JSON.parse(e.rawSourcePayload || "{}");
        return e.eventType === "party / nightlife" && (payload.discotech_url || payload.clubbable_url);
      }).length;

      const tileSnapshot = {
        tile: { intent: job.intent, countryCode: metro.country_code, state: metro.state, z: tile.z, x: tile.x, y: tile.y },
        bounds,
        searchLocations: [{ city: metro.city, state: metro.state, latitude: metro.latitude, longitude: metro.longitude, displayName: metro.display_name }],
        mergedEvents: tileEvents,
        notes: [],
        quality: tileEvents.length > 0 ? "full" : "empty",
        fetchedAt,
        expiresAt: expiresAt,
        eventCount: tileEvents.length,
        exclusiveCount: tileExclusive,
        nightlifeCount: tileNightlife,
      };

      const persisted = await upsertViewportTile(supabase, {
        tile_key: tileKey,
        intent: job.intent,
        z: tile.z,
        x: tile.x,
        y: tile.y,
        quality: tileEvents.length > 0 ? "full" : "empty",
        country_code: metro.country_code,
        state: metro.state,
        bounds,
        source_snapshot_keys: [key],
        event_count: tileEvents.length,
        exclusive_count: tileExclusive,
        nightlife_count: tileNightlife,
        snapshot: tileSnapshot,
        fetched_at: fetchedAt,
        expires_at: expiresAt,
      });

      if (persisted) {
        tileSuccessCount++;
      } else {
        tileFailureCount++;
      }
    });

    console.log(
      `[worker] ${metro.display_name}/${job.intent}: materialized ` +
        `${tileSuccessCount}/${tiles.length} viewport tiles ` +
        `(padding=${tilePadding}, failed=${tileFailureCount})`
    );

    if (tiles.length > 0 && tileSuccessCount === 0) {
      throw new Error(`Viewport tile writes failed for all ${tiles.length} tiles`);
    }
    if (tileFailureCount > Math.max(3, Math.floor(tiles.length * 0.25))) {
      throw new Error(
        `Viewport tile writes failed for ${tileFailureCount}/${tiles.length} tiles`
      );
    }
  } catch (tileErr) {
    console.error("[worker] viewport tile materialization error:", tileErr);
    throw tileErr;
  }

  const uniqueVenues = new Set(
    snapshot.mergedEvents
      .map((e) => e.venueName)
      .filter(Boolean)
  ).size;

  const sportsCount = snapshot.mergedEvents.filter(
    (e) => e.eventType === "sports event"
  ).length;
  const concertCount = snapshot.mergedEvents.filter(
    (e) => e.eventType === "concert"
  ).length;
  const communityCount = snapshot.mergedEvents.filter(
    (e) =>
      e.eventType === "social / community event" ||
      e.eventType === "weekend activity"
  ).length;

  await recordCoverageMetrics(supabase, {
    metro_id: job.metro_id,
    intent: job.intent,
    total_events: snapshot.mergedEvents.length,
    unique_venues: uniqueVenues,
    review_eligible_count: reviewEligible.length,
    review_covered_count: reviewCovered.length,
    review_coverage_pct: reviewCoveragePct,
    nightlife_count: nightlifeCount,
    sports_count: sportsCount,
    concert_count: concertCount,
    community_count: communityCount,
    poisoned_review_count: reviewResult.poisonedCount ?? 0,
    stale_reason:
      snapshot.mergedEvents.length === 0 ? "No events returned" : undefined,
    degraded_reason:
      reviewCoveragePct < 0.3 && reviewEligible.length >= 8
        ? `Low review coverage: ${(reviewCoveragePct * 100).toFixed(1)}%`
        : undefined,
    notes,
  });

  const durationMs = Date.now() - startTime;

  if (runId) {
    await updateRefreshRun(supabase, runId, {
      status: "completed",
      completed_at: new Date().toISOString(),
      duration_ms: durationMs,
      event_count: snapshot.mergedEvents.length,
      venue_count: uniqueVenues,
      review_hit_count: reviewResult.hitCount,
      review_miss_count: reviewResult.missCount,
      review_error_count: reviewResult.errorCount,
      review_poisoned_count: reviewResult.poisonedCount ?? 0,
      nightlife_venue_count: nightlifeResult.venueCount,
      source_results: adapterResults.map((r) => ({
        source: r.source,
        event_count: r.events.length,
        request_count: r.requestCount,
        success_count: r.successCount,
        failure_count: r.failureCount,
      })),
      notes,
    });
  }

  console.log(
    `[worker] ${metro.display_name}/${job.intent}: ` +
      `${snapshot.mergedEvents.length} events, ` +
      `${uniqueVenues} venues, ` +
      `review coverage ${(reviewCoveragePct * 100).toFixed(1)}% ` +
      `(${reviewResult.poisonedCount ?? 0} poisoned), ` +
      `${nightlifeResult.venueCount} nightlife venues, ` +
      `${durationMs}ms`
  );
}

function emptyAdapterResult(source: string, note: string): AdapterResult {
  return {
    source,
    events: [],
    requestCount: 0,
    successCount: 0,
    failureCount: 0,
    timeoutCount: 0,
    avgLatencyMs: 0,
    notes: [note],
  };
}

function ttlForIntent(intent: string): number {
  switch (intent) {
    case "biggest_tonight":
      return 48;
    case "last_minute_plans":
      return 24;
    case "exclusive_hot":
      return 72;
    case "nearby_and_worth_it":
      return 96;
    default:
      return 48;
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function buildViewportTileCoverage(
  metroLatitude: number,
  metroLongitude: number,
  events: Array<{ latitude?: number; longitude?: number }>,
  zoom: number,
  metroPadding: number,
  eventHalo: number,
  maxTiles: number
): TileKey[] {
  const baseTiles = tilesForMetro(metroLatitude, metroLongitude, zoom, metroPadding);
  const centerTile = latLonToTile(metroLatitude, metroLongitude, zoom);
  const maxIndex = Math.pow(2, zoom) - 1;
  const deduped = new Map<string, TileKey>();

  for (const tile of baseTiles) {
    deduped.set(`${tile.z}:${tile.x}:${tile.y}`, tile);
  }

  for (const event of events) {
    if (typeof event.latitude !== "number" || typeof event.longitude !== "number") {
      continue;
    }
    const eventTile = latLonToTile(event.latitude, event.longitude, zoom);
    for (let dx = -eventHalo; dx <= eventHalo; dx++) {
      for (let dy = -eventHalo; dy <= eventHalo; dy++) {
        const tile: TileKey = {
          z: zoom,
          x: Math.min(Math.max(eventTile.x + dx, 0), maxIndex),
          y: Math.min(Math.max(eventTile.y + dy, 0), maxIndex),
        };
        deduped.set(`${tile.z}:${tile.x}:${tile.y}`, tile);
      }
    }
  }

  return [...deduped.values()]
    .sort((a, b) => tileGridDistance(a, centerTile) - tileGridDistance(b, centerTile))
    .slice(0, maxTiles);
}

function tileGridDistance(a: TileKey, b: TileKey): number {
  return Math.abs(a.x - b.x) + Math.abs(a.y - b.y);
}

async function runWithConcurrency<T>(
  limit: number,
  items: T[],
  worker: (item: T) => Promise<void>
): Promise<void> {
  const queue = [...items];
  const active = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (queue.length > 0) {
      const item = queue.shift();
      if (!item) return;
      await worker(item);
    }
  });
  await Promise.all(active);
}

let workerStartedAt: Date | null = null;
let lastJobCompletedAt: Date | null = null;
let totalJobsCompleted = 0;
let totalJobsFailed = 0;

function startHealthServer(port: number): void {
  const http = require("http");
  const server = http.createServer(
    (
      _req: { url?: string },
      res: { writeHead: (s: number, h: Record<string, string>) => void; end: (b: string) => void }
    ) => {
      const uptimeMs = workerStartedAt
        ? Date.now() - workerStartedAt.getTime()
        : 0;
      const body = JSON.stringify({
        status: running ? "running" : "stopped",
        uptime_ms: uptimeMs,
        uptime_human: `${Math.floor(uptimeMs / 3600000)}h ${Math.floor((uptimeMs % 3600000) / 60000)}m`,
        started_at: workerStartedAt?.toISOString() ?? null,
        last_job_completed_at: lastJobCompletedAt?.toISOString() ?? null,
        total_jobs_completed: totalJobsCompleted,
        total_jobs_failed: totalJobsFailed,
      });
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(body);
    }
  );
  server.listen(port, () => {
    console.log(`[health] Listening on port ${port}`);
  });
}

const originalCompleteJob = completeJob;
const trackJobCompleted = () => {
  lastJobCompletedAt = new Date();
  totalJobsCompleted++;
};
const trackJobFailed = () => {
  totalJobsFailed++;
};

if (require.main === module) {
  workerStartedAt = new Date();

  const healthPort = parseInt(process.env.HEALTH_PORT || "8080", 10);
  startHealthServer(healthPort);

  const origProcess = processJob;

  startWorker().catch((err) => {
    console.error("[worker] Fatal error:", err);
    process.exit(1);
  });

  process.on("SIGINT", () => {
    console.log("[worker] SIGINT received, shutting down...");
    stopWorker();
  });

  process.on("SIGTERM", () => {
    console.log("[worker] SIGTERM received, shutting down...");
    stopWorker();
  });
}
