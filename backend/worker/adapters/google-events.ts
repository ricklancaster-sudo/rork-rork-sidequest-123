import type { Metro } from "../lib/supabase";
import type { AdapterResult, EventResult } from "./ticketmaster";

interface SearchChannel {
  label: string;
  queryText: string;
  fallbackType: string;
}

interface ParsedGoogleCard {
  docId: string | undefined;
  title: string;
  when: string | undefined;
  day: string | undefined;
  month: string | undefined;
  venueName: string | undefined;
  address: string | undefined;
  ticketUrls: string[];
  imageUrl: string | undefined;
  venueRating: number | undefined;
  venueReviewCount: number | undefined;
}

const SEARCH_BASE_URL = "https://www.google.com/search";
const DESKTOP_USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";
const MONTH_INDEX: Record<string, number> = {
  jan: 1,
  feb: 2,
  mar: 3,
  apr: 4,
  may: 5,
  jun: 6,
  jul: 7,
  aug: 8,
  sep: 9,
  sept: 9,
  oct: 10,
  nov: 11,
  dec: 12,
};

export async function fetchGoogleEvents(
  metro: Metro,
  intent: string
): Promise<AdapterResult> {
  const result: AdapterResult = {
    source: "google_events",
    events: [],
    requestCount: 0,
    successCount: 0,
    failureCount: 0,
    timeoutCount: 0,
    avgLatencyMs: 0,
    notes: [],
  };

  const channels = buildChannels(metro, intent);
  const latencies: number[] = [];

  for (const channel of channels) {
    const url = new URL(SEARCH_BASE_URL);
    url.searchParams.set("q", channel.queryText);
    url.searchParams.set("ibp", "htl;events");
    url.searchParams.set("hl", "en");
    url.searchParams.set("gl", "us");

    result.requestCount++;
    const startedAt = Date.now();

    try {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 15_000);
      const response = await fetch(url.toString(), {
        signal: controller.signal,
        headers: {
          "User-Agent": DESKTOP_USER_AGENT,
          "Accept-Language": "en-US,en;q=0.9",
          Accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
          Referer: "https://www.google.com/",
          "Upgrade-Insecure-Requests": "1",
        },
      });
      clearTimeout(timeout);

      latencies.push(Date.now() - startedAt);

      if (!response.ok) {
        result.failureCount++;
        result.notes.push(`Google Events ${channel.label}: HTTP ${response.status}`);
        continue;
      }

      const html = await response.text();
      if (!html.includes("PaEvOc") || !html.includes("gws-horizon-textlists__li-ed")) {
        result.failureCount++;
        result.notes.push(`Google Events ${channel.label}: no event cards detected`);
        continue;
      }

      result.successCount++;
      const cards = parseGoogleCards(html);
      const normalized = cards
        .map((card) => normalizeGoogleCard(card, metro, channel))
        .filter((event): event is EventResult => event !== null);
      result.events.push(...normalized);
    } catch (error) {
      latencies.push(Date.now() - startedAt);
      if (error instanceof DOMException && error.name === "AbortError") {
        result.timeoutCount++;
        result.notes.push(`Google Events ${channel.label}: timeout`);
      } else {
        result.failureCount++;
        result.notes.push(`Google Events ${channel.label}: ${String(error)}`);
      }
    }
  }

  result.events = dedupeGoogleEvents(result.events);
  result.avgLatencyMs =
    latencies.length > 0
      ? Math.round(latencies.reduce((sum, value) => sum + value, 0) / latencies.length)
      : 0;

  if (result.events.length === 0 && result.notes.length === 0) {
    result.notes.push("Google Events returned no local event cards");
  }

  return result;
}

function buildChannels(metro: Metro, intent: string): SearchChannel[] {
  const metroLabel = `${metro.city}, ${metro.state}`;

  switch (intent) {
    case "biggest_tonight":
      return [
        { label: "tonight-events", queryText: `events tonight in ${metroLabel}`, fallbackType: "other live event" },
        { label: "tonight-concerts", queryText: `concerts tonight in ${metroLabel}`, fallbackType: "concert" },
        { label: "tonight-sports", queryText: `sports tonight in ${metroLabel}`, fallbackType: "sports event" },
      ];
    case "exclusive_hot":
      return [
        { label: "nightlife-tonight", queryText: `nightlife tonight in ${metroLabel}`, fallbackType: "party / nightlife" },
        { label: "club-nights", queryText: `club nights tonight in ${metroLabel}`, fallbackType: "party / nightlife" },
        { label: "dj-events", queryText: `DJ events tonight in ${metroLabel}`, fallbackType: "party / nightlife" },
      ];
    case "last_minute_plans":
      return [
        { label: "things-tonight", queryText: `things to do tonight in ${metroLabel}`, fallbackType: "social / community event" },
        { label: "events-tomorrow", queryText: `events tomorrow in ${metroLabel}`, fallbackType: "social / community event" },
        { label: "community-week", queryText: `community events this week in ${metroLabel}`, fallbackType: "social / community event" },
      ];
    default:
      return [
        { label: "events-today", queryText: `events today in ${metroLabel}`, fallbackType: "social / community event" },
        { label: "things-week", queryText: `things to do this week in ${metroLabel}`, fallbackType: "weekend activity" },
        { label: "comedy-week", queryText: `comedy shows this week in ${metroLabel}`, fallbackType: "other live event" },
      ];
  }
}

function parseGoogleCards(html: string): ParsedGoogleCard[] {
  const blocks = html.match(/<li class=\"PaEvOc[^\"]*gws-horizon-textlists__li-ed\".*?<\/li>/gs) || [];
  return blocks
    .map((block) => {
      const title = decodeHtml(firstCapture(/jsname=\"r4nke\"[^>]*>(.*?)<\/div>/s, block));
      if (!title) return null;

      const ticketUrls = [...new Set(extractExternalUrls(block))];
      const rating = parseFloatSafe(
        decodeHtml(firstCapture(/aria-label=\"Rated ([0-9.]+) out of 5,/s, block)) ||
          decodeHtml(firstCapture(/<span class=\"UIHjI[^\"]*\"[^>]*>([0-9.]+)<\/span>/s, block))
      );
      const reviewCount = parseCompactInt(
        decodeHtml(
          firstCapture(/aria-label=\"Rated [0-9.]+ out of 5, ([0-9][0-9,\.KkMm]*) reviews/s, block)
        ) ||
          decodeHtml(firstCapture(/>([0-9][0-9,\.KkMm]*) reviews</, block))
      );

      return {
        docId: decodeHtml(firstCapture(/data-encoded-docid=\"([^\"]+)\"/, block)) || undefined,
        title,
        day: decodeHtml(firstCapture(/<div class=\"FTUoSb\">(.*?)<\/div>/s, block)) || undefined,
        month: decodeHtml(firstCapture(/<div class=\"omoMNe\">(.*?)<\/div>/s, block)) || undefined,
        when: decodeHtml(firstCapture(/<div class=\"Gkoz3\">(.*?)<\/div>/s, block)) || undefined,
        venueName: decodeHtml(firstCapture(/<span class=\"n3VjZe\">(.*?)<\/span>/s, block)) || undefined,
        address: decodeHtml(firstCapture(/<span class=\"U6txu\">(.*?)<\/span>/s, block)) || undefined,
        ticketUrls,
        imageUrl:
          decodeUrl(firstCapture(/href=\"(https:\/\/[^\"]+\.(?:jpg|jpeg|png|webp)[^\"]*)\"/s, block)) ||
          undefined,
        venueRating: rating ?? undefined,
        venueReviewCount: reviewCount ?? undefined,
      };
    })
    .filter((value): value is ParsedGoogleCard => value !== null);
}

function normalizeGoogleCard(
  card: ParsedGoogleCard,
  metro: Metro,
  channel: SearchChannel
): EventResult | null {
  const parsedAddress = parseAddress(card.address, metro);
  if (parsedAddress.state && normalizeState(parsedAddress.state) !== normalizeState(metro.state)) {
    return null;
  }

  const timeZone = timeZoneForMetro(metro);
  const start = parseGoogleWhen(card.when, card.day, card.month, timeZone);
  const sourceEventId =
    card.docId ||
    stableId([card.title, card.when, card.venueName, parsedAddress.city || metro.city]);
  const ticketUrl = card.ticketUrls[0];
  const eventType = inferGoogleEventType(card, channel);

  return {
    id: `google_events:${sourceEventId}`,
    source: "google_events",
    sourceEventId,
    sourceUrl: ticketUrl || SEARCH_BASE_URL,
    title: card.title,
    shortDescription: card.when,
    eventType,
    startAtUTC: start.startAtUTC,
    endAtUTC: start.endAtUTC,
    startLocal: start.startLocal,
    endLocal: start.endLocal,
    timezone: timeZone,
    venueName: card.venueName,
    addressLine1: parsedAddress.addressLine1,
    city: parsedAddress.city || metro.city,
    state: parsedAddress.state || metro.state,
    postalCode: parsedAddress.postalCode,
    country: "US",
    imageUrl: card.imageUrl,
    status: start.startAtUTC && new Date(start.startAtUTC).getTime() < Date.now() ? "ended" : "scheduled",
    ticketUrl,
    tags: [channel.label, card.when].filter((value): value is string => Boolean(value)),
    rawSourcePayload: {
      google_doc_id: card.docId,
      google_when: card.when,
      google_ticket_urls: card.ticketUrls,
      google_venue_rating: card.venueRating,
      google_venue_review_count: card.venueReviewCount,
      google_channel: channel.label,
    },
  };
}

function inferGoogleEventType(card: ParsedGoogleCard, channel: SearchChannel): string {
  const haystack = `${channel.label} ${channel.queryText} ${card.title} ${card.venueName || ""}`.toLowerCase();
  if (
    haystack.includes("nightlife") ||
    haystack.includes("club") ||
    haystack.includes("dj") ||
    haystack.includes("party")
  ) {
    return "party / nightlife";
  }
  if (haystack.includes("concert") || haystack.includes("music") || haystack.includes("festival")) {
    return "concert";
  }
  if (haystack.includes("sports")) {
    return "sports event";
  }
  if (haystack.includes("comedy")) {
    return "other live event";
  }
  if (haystack.includes("market") || haystack.includes("community") || haystack.includes("things")) {
    return "social / community event";
  }
  return channel.fallbackType;
}

function parseGoogleWhen(
  rawWhen: string | undefined,
  fallbackDay: string | undefined,
  fallbackMonth: string | undefined,
  timeZone: string
): {
  startAtUTC?: string;
  endAtUTC?: string;
  startLocal?: string;
  endLocal?: string;
} {
  if (!rawWhen && !(fallbackDay && fallbackMonth)) {
    return {};
  }

  const normalized = (rawWhen || `${fallbackMonth || ""} ${fallbackDay || ""}`)
    .replace(/\u202f/g, " ")
    .replace(/\s+/g, " ")
    .trim();

  const firstDate = normalized.match(
    /(?:[A-Za-z]{3},\s*)?([A-Za-z]{3,9})\s+(\d{1,2})(?:,\s*(\d{1,2})(?::(\d{2}))?\s*([AP]M))?/i
  );

  const now = new Date();
  const year = now.getUTCFullYear();
  const monthToken = firstDate?.[1] || fallbackMonth || "";
  const month = MONTH_INDEX[monthToken.toLowerCase()];
  const day = parseInt(firstDate?.[2] || fallbackDay || "", 10);
  if (!month || !Number.isFinite(day)) {
    return {};
  }

  let hour = 19;
  let minute = 0;
  if (firstDate?.[3]) {
    hour = parseInt(firstDate[3], 10);
    minute = parseInt(firstDate[4] || "0", 10);
    const meridiem = (firstDate[5] || "PM").toUpperCase();
    if (meridiem === "PM" && hour < 12) hour += 12;
    if (meridiem === "AM" && hour === 12) hour = 0;
  }

  const localYear = resolveEventYear(year, month, day);
  const startAtUTC = zonedTimeToUTC(localYear, month, day, hour, minute, timeZone);
  const startLocal = formatLocalIso(localYear, month, day, hour, minute);
  const defaultDurationHours =
    normalized.toLowerCase().includes("festival") || normalized.toLowerCase().includes("market") ? 4 : 3;
  const end = new Date(new Date(startAtUTC).getTime() + defaultDurationHours * 60 * 60 * 1000);

  return {
    startAtUTC,
    endAtUTC: end.toISOString(),
    startLocal,
    endLocal: formatLocalIso(
      parseInt(end.toISOString().slice(0, 4), 10),
      parseInt(end.toISOString().slice(5, 7), 10),
      parseInt(end.toISOString().slice(8, 10), 10),
      parseInt(end.toISOString().slice(11, 13), 10),
      parseInt(end.toISOString().slice(14, 16), 10)
    ),
  };
}

function resolveEventYear(currentYear: number, month: number, day: number): number {
  const now = new Date();
  const currentMonth = now.getUTCMonth() + 1;
  if (currentMonth === 12 && month === 1) return currentYear + 1;
  if (currentMonth === 1 && month === 12) return currentYear - 1;
  return currentYear;
}

function parseAddress(
  rawAddress: string | undefined,
  metro: Metro
): {
  addressLine1?: string;
  city?: string;
  state?: string;
  postalCode?: string;
} {
  if (!rawAddress) {
    return {};
  }

  const cleaned = rawAddress.replace(/\s+/g, " ").trim();
  const segments = cleaned.split(",").map((segment) => segment.trim()).filter(Boolean);
  const lastSegment = segments[segments.length - 1] || "";
  const statePostalMatch = lastSegment.match(/([A-Z]{2})(?:\s+(\d{5}))?/i);

  return {
    addressLine1: segments[0],
    city: segments.length >= 2 ? segments[1] : metro.city,
    state: statePostalMatch?.[1] || metro.state,
    postalCode: statePostalMatch?.[2],
  };
}

function extractExternalUrls(block: string): string[] {
  const matches = [...block.matchAll(/href=\"(https:\/\/[^\"]+)\"/g)];
  return matches
    .map((match) => decodeUrl(match[1]))
    .filter((value): value is string => Boolean(value))
    .filter((url) => !url.includes("google.com") && !url.includes("gstatic.com"));
}

function firstCapture(pattern: RegExp, input: string): string | undefined {
  return input.match(pattern)?.[1];
}

function dedupeGoogleEvents(events: EventResult[]): EventResult[] {
  const deduped = new Map<string, EventResult>();
  for (const event of events) {
    const key = [event.title, event.startAtUTC || event.startLocal, event.venueName]
      .filter(Boolean)
      .join("::")
      .toLowerCase();
    if (!deduped.has(key)) {
      deduped.set(key, event);
    }
  }
  return [...deduped.values()];
}

function parseFloatSafe(value: string | undefined): number | null {
  if (!value) return null;
  const parsed = parseFloat(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function parseCompactInt(value: string | undefined): number | null {
  if (!value) return null;
  const normalized = value.replace(/,/g, "").trim().toUpperCase();
  if (normalized.endsWith("K")) {
    return Math.round(parseFloat(normalized.slice(0, -1)) * 1_000);
  }
  if (normalized.endsWith("M")) {
    return Math.round(parseFloat(normalized.slice(0, -1)) * 1_000_000);
  }
  const parsed = parseInt(normalized, 10);
  return Number.isFinite(parsed) ? parsed : null;
}

function decodeUrl(value: string | undefined): string | undefined {
  if (!value) return undefined;
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

function decodeHtml(value: string | undefined): string | undefined {
  if (!value) return undefined;
  return value
    .replace(/&#(\d+);/g, (_match, code) => String.fromCharCode(parseInt(code, 10)))
    .replace(/&#x([0-9a-f]+);/gi, (_match, code) =>
      String.fromCharCode(parseInt(code, 16))
    )
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, "\"")
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&nbsp;/g, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function normalizeState(value: string): string {
  return value.trim().toLowerCase();
}

function stableId(parts: Array<string | undefined>): string {
  return parts
    .filter(Boolean)
    .join("::")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 120);
}

function timeZoneForMetro(metro: Metro): string {
  const state = normalizeState(metro.state);
  const city = metro.city.trim().toLowerCase();

  if (["ca", "wa", "or", "nv"].includes(state)) return "America/Los_Angeles";
  if (["az"].includes(state)) return "America/Phoenix";
  if (["co", "ut", "nm"].includes(state)) return "America/Denver";
  if (["tx", "il", "tn", "mn", "mo", "wi", "la", "al", "ok"].includes(state)) {
    return "America/Chicago";
  }
  if (["ny", "fl", "ga", "nc", "dc", "ma", "pa", "nj", "va", "oh", "mi", "ky", "sc", "md", "ct", "ri"].includes(state)) {
    return "America/New_York";
  }
  if (state === "ak") return "America/Anchorage";
  if (state === "hi") return "Pacific/Honolulu";
  if (city.includes("phoenix")) return "America/Phoenix";
  return "America/Los_Angeles";
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
  const partMap = Object.fromEntries(
    formatter
      .formatToParts(utcGuess)
      .filter((part) => part.type !== "literal")
      .map((part) => [part.type, part.value])
  ) as Record<string, string>;
  const zonedAsUtc = Date.UTC(
    parseInt(partMap.year, 10),
    parseInt(partMap.month, 10) - 1,
    parseInt(partMap.day, 10),
    parseInt(partMap.hour, 10),
    parseInt(partMap.minute, 10)
  );

  return new Date(utcGuess.getTime() - (zonedAsUtc - utcGuess.getTime())).toISOString();
}

function formatLocalIso(
  year: number,
  month: number,
  day: number,
  hour: number,
  minute: number
): string {
  return `${String(year).padStart(4, "0")}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}T${String(hour).padStart(2, "0")}:${String(minute).padStart(2, "0")}:00`;
}
