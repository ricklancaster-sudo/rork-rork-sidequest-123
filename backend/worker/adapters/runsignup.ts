import type { Metro } from "../lib/supabase";
import type { AdapterResult, EventResult } from "./ticketmaster";

interface RunSignupListResponse {
  races?: Array<{
    race?: {
      race_id?: number;
      name?: string;
      next_date?: string;
      url?: string;
      address?: {
        city?: string;
        state?: string;
        zipcode?: string;
      };
    };
  }>;
}

interface RunSignupDetailResponse {
  race?: {
    race_id?: number;
    name?: string;
    description?: string;
    url?: string;
    timezone?: string;
    logo_url?: string;
    is_registration_open?: string;
    next_date?: string;
    address?: {
      street?: string;
      street2?: string;
      city?: string;
      state?: string;
      zipcode?: string;
      country_code?: string;
    };
    events?: Array<{
      event_id?: number;
      name?: string;
      details?: string | null;
      start_time?: string;
      end_time?: string;
      event_type?: string;
      distance?: string;
      registration_periods?: Array<{
        race_fee?: string;
      }>;
    }>;
  };
}

export async function fetchRunSignup(
  metro: Metro,
  intent: string
): Promise<AdapterResult> {
  const result: AdapterResult = {
    source: "runsignup",
    events: [],
    requestCount: 0,
    successCount: 0,
    failureCount: 0,
    timeoutCount: 0,
    avgLatencyMs: 0,
    notes: [],
  };

  const listUrl = new URL("https://api.runsignup.com/rest/races");
  listUrl.searchParams.set("format", "json");
  listUrl.searchParams.set("results_per_page", String(limitForIntent(intent)));
  listUrl.searchParams.set("page", "1");
  listUrl.searchParams.set("start_date", "today");
  listUrl.searchParams.set("sort", "date ASC");

  if (metro.postal_code) {
    listUrl.searchParams.set("zipcode", metro.postal_code);
    listUrl.searchParams.set("radius", intent === "biggest_tonight" ? "50" : "35");
  } else {
    listUrl.searchParams.set("city", metro.city);
    listUrl.searchParams.set("state", metro.state);
  }

  const latencies: number[] = [];
  const listResponse = await fetchJsonWithTracking<RunSignupListResponse>(listUrl, result, latencies);
  if (!listResponse?.races?.length) {
    if (result.notes.length === 0) {
      result.notes.push("RunSignup returned no local races");
    }
    finalizeLatency(result, latencies);
    return result;
  }

  const raceIds = listResponse.races
    .map((entry) => entry.race?.race_id)
    .filter((value): value is number => typeof value === "number")
    .slice(0, limitForIntent(intent));

  const settled = await Promise.allSettled(
    raceIds.map(async (raceId) => {
      const detailUrl = new URL(`https://api.runsignup.com/rest/race/${raceId}`);
      detailUrl.searchParams.set("format", "json");
      const detail = await fetchJsonWithTracking<RunSignupDetailResponse>(
        detailUrl,
        result,
        latencies
      );
      if (!detail?.race?.events?.length) return [];
      return detail.race.events
        .map((event) => normalizeRunSignupEvent(detail.race!, event))
        .filter((event): event is EventResult => event !== null);
    })
  );

  for (const entry of settled) {
    if (entry.status === "fulfilled") {
      result.events.push(...entry.value);
    } else {
      result.failureCount++;
      result.notes.push(`RunSignup detail error: ${String(entry.reason)}`);
    }
  }

  result.events = dedupeEvents(result.events);
  finalizeLatency(result, latencies);
  return result;
}

function limitForIntent(intent: string): number {
  switch (intent) {
    case "biggest_tonight":
      return 10;
    case "last_minute_plans":
      return 8;
    default:
      return 6;
  }
}

async function fetchJsonWithTracking<T>(
  url: URL,
  result: AdapterResult,
  latencies: number[]
): Promise<T | null> {
  result.requestCount++;
  const startedAt = Date.now();

  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 15_000);
    const response = await fetch(url.toString(), {
      signal: controller.signal,
      headers: { Accept: "application/json" },
    });
    clearTimeout(timeout);

    latencies.push(Date.now() - startedAt);

    if (!response.ok) {
      result.failureCount++;
      result.notes.push(`RunSignup ${url.pathname}: HTTP ${response.status}`);
      return null;
    }

    result.successCount++;
    return (await response.json()) as T;
  } catch (error) {
    latencies.push(Date.now() - startedAt);
    if (error instanceof DOMException && error.name === "AbortError") {
      result.timeoutCount++;
      result.notes.push(`RunSignup ${url.pathname}: timeout`);
    } else {
      result.failureCount++;
      result.notes.push(`RunSignup ${url.pathname}: ${String(error)}`);
    }
    return null;
  }
}

function normalizeRunSignupEvent(
  race: NonNullable<RunSignupDetailResponse["race"]>,
  event: NonNullable<NonNullable<RunSignupDetailResponse["race"]>["events"]>[number]
): EventResult | null {
  if (!race.race_id || !event.event_id || !event.name || !event.start_time) {
    return null;
  }

  const eventType = classifyRunEvent(event.name, event.distance, event.event_type);
  if (eventType === "other live event") {
    return null;
  }

  const raceName = race.name || "RunSignup Event";
  const timezone = race.timezone || undefined;
  const startAtUTC = localRunSignupDateToUTC(event.start_time, timezone);
  const endAtUTC = event.end_time
    ? localRunSignupDateToUTC(event.end_time, timezone)
    : undefined;
  if (startAtUTC) {
    const startMs = new Date(startAtUTC).getTime();
    const now = Date.now();
    if (startMs < now - 12 * 60 * 60 * 1000) {
      return null;
    }
    if (startMs > now + 400 * 24 * 60 * 60 * 1000) {
      return null;
    }
  }
  const price = extractRunSignupPrice(event.registration_periods);

  const addressParts = [race.address?.street, race.address?.street2].filter(Boolean);

  return {
    id: `runsignup:${race.race_id}:${event.event_id}`,
    source: "runsignup",
    sourceEventId: String(event.event_id),
    sourceParentId: String(race.race_id),
    sourceUrl: race.url,
    title: `${raceName}${event.name.toLowerCase() === raceName.toLowerCase() ? "" : ` - ${event.name}`}`,
    shortDescription: shorten(stripHtml(event.details || race.description || "")),
    fullDescription: stripHtml(event.details || race.description || ""),
    category: "fitness",
    subcategory: event.distance || event.event_type || undefined,
    eventType,
    startAtUTC,
    endAtUTC,
    startLocal: toIsoLocalLike(event.start_time),
    endLocal: event.end_time ? toIsoLocalLike(event.end_time) : undefined,
    timezone,
    venueName: raceName,
    venueId: String(race.race_id),
    addressLine1: addressParts.join(", ") || undefined,
    city: race.address?.city || undefined,
    state: race.address?.state || undefined,
    postalCode: race.address?.zipcode || undefined,
    country: race.address?.country_code || "US",
    imageUrl: race.logo_url || undefined,
    status: race.is_registration_open === "T" ? "onsale" : "scheduled",
    priceMin: price ?? undefined,
    priceMax: price ?? undefined,
    currency: price != null ? "USD" : undefined,
    ticketUrl: race.url,
    tags: [event.distance, event.event_type].filter((value): value is string => Boolean(value)),
    rawSourcePayload: {
      runsignup_race_id: race.race_id,
      runsignup_event_id: event.event_id,
      runsignup_distance: event.distance,
      runsignup_registration_open: race.is_registration_open === "T",
    },
  };
}

function classifyRunEvent(
  name?: string,
  distance?: string,
  eventType?: string
): string {
  const haystack = `${name || ""} ${distance || ""} ${eventType || ""}`.toLowerCase();
  if (
    haystack.includes("5k") ||
    haystack.includes("10k") ||
    haystack.includes("half") ||
    haystack.includes("marathon") ||
    haystack.includes("mile") ||
    haystack.includes("running")
  ) {
    return "weekend activity";
  }
  return "other live event";
}

function extractRunSignupPrice(
  periods?: Array<{ race_fee?: string }>
): number | null {
  for (const period of periods || []) {
    if (!period.race_fee) continue;
    const numeric = parseFloat(period.race_fee.replace(/[^0-9.]/g, ""));
    if (Number.isFinite(numeric) && numeric >= 0) {
      return numeric;
    }
  }
  return null;
}

function localRunSignupDateToUTC(value: string, timeZone?: string): string | undefined {
  const match = value.match(
    /^(\d{1,2})\/(\d{1,2})\/(\d{4})\s+(\d{1,2}):(\d{2})$/
  );
  if (!match) return undefined;

  const month = parseInt(match[1], 10);
  const day = parseInt(match[2], 10);
  const year = parseInt(match[3], 10);
  const hour = parseInt(match[4], 10);
  const minute = parseInt(match[5], 10);

  if (!timeZone) {
    return new Date(year, month - 1, day, hour, minute).toISOString();
  }

  return zonedTimeToUTC(year, month, day, hour, minute, timeZone);
}

function zonedTimeToUTC(
  year: number,
  month: number,
  day: number,
  hour: number,
  minute: number,
  timeZone: string
): string {
  const utcGuess = new Date(Date.UTC(year, month - 1, day, hour, minute));
  const formatter = new Intl.DateTimeFormat("en-US", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });

  const parts = formatter.formatToParts(utcGuess);
  const partMap = Object.fromEntries(
    parts.filter((part) => part.type !== "literal").map((part) => [part.type, part.value])
  );
  const zonedAsUtc = Date.UTC(
    parseInt(partMap.year, 10),
    parseInt(partMap.month, 10) - 1,
    parseInt(partMap.day, 10),
    parseInt(partMap.hour, 10),
    parseInt(partMap.minute, 10)
  );

  return new Date(utcGuess.getTime() - (zonedAsUtc - utcGuess.getTime())).toISOString();
}

function toIsoLocalLike(value: string): string | undefined {
  const match = value.match(
    /^(\d{1,2})\/(\d{1,2})\/(\d{4})\s+(\d{1,2}):(\d{2})$/
  );
  if (!match) return undefined;
  const month = match[1].padStart(2, "0");
  const day = match[2].padStart(2, "0");
  const year = match[3];
  const hour = match[4].padStart(2, "0");
  const minute = match[5].padStart(2, "0");
  return `${year}-${month}-${day}T${hour}:${minute}:00`;
}

function stripHtml(value: string): string {
  return value
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&#39;/g, "'")
    .replace(/&quot;/g, "\"")
    .replace(/\s+/g, " ")
    .trim();
}

function shorten(value: string, maxLength: number = 200): string | undefined {
  if (!value) return undefined;
  if (value.length <= maxLength) return value;
  return `${value.slice(0, maxLength - 3).trim()}...`;
}

function dedupeEvents(events: EventResult[]): EventResult[] {
  const seen = new Set<string>();
  const deduped: EventResult[] = [];
  for (const event of events) {
    const key = [event.title, event.startAtUTC || event.startLocal, event.venueName]
      .filter(Boolean)
      .join("::")
      .toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    deduped.push(event);
  }
  return deduped;
}

function finalizeLatency(result: AdapterResult, latencies: number[]): void {
  result.avgLatencyMs =
    latencies.length > 0
      ? Math.round(latencies.reduce((sum, value) => sum + value, 0) / latencies.length)
      : 0;
}
