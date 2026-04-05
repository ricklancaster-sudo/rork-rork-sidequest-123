import type { Metro } from "../lib/supabase";
import type { AdapterResult, EventResult } from "./ticketmaster";

interface EventbriteListPayload {
  itemListElement?: Array<{
    item?: {
      name?: string;
      description?: string;
      url?: string;
      image?: string;
      startDate?: string;
      endDate?: string;
      location?: {
        name?: string;
        address?: {
          streetAddress?: string;
          addressLocality?: string;
          addressRegion?: string;
          postalCode?: string;
          addressCountry?: string;
        };
        geo?: {
          latitude?: string;
          longitude?: string;
        };
      };
    };
  }>;
}

interface EventbriteItem {
  name?: string;
  description?: string;
  url?: string;
  image?: string;
  startDate?: string;
  endDate?: string;
  location?: {
    name?: string;
    address?: {
      streetAddress?: string;
      addressLocality?: string;
      addressRegion?: string;
      postalCode?: string;
      addressCountry?: string;
    };
    geo?: {
      latitude?: string;
      longitude?: string;
    };
  };
}

interface EventbriteChannel {
  label: string;
  path: string;
  fallbackType: string;
}

const DESKTOP_USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";

export async function fetchEventbrite(
  metro: Metro,
  intent: string,
  _token?: string
): Promise<AdapterResult> {
  const result: AdapterResult = {
    source: "eventbrite",
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
    result.requestCount++;
    const startedAt = Date.now();

    try {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 15_000);
      const response = await fetch(channel.path, {
        signal: controller.signal,
        headers: {
          "User-Agent": DESKTOP_USER_AGENT,
          "Accept-Language": "en-US,en;q=0.9",
          Accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        },
      });
      clearTimeout(timeout);

      latencies.push(Date.now() - startedAt);

      if (!response.ok) {
        result.failureCount++;
        result.notes.push(`Eventbrite ${channel.label}: HTTP ${response.status}`);
        continue;
      }

      const html = await response.text();
      const payload = extractJsonLd(html);
      if (!payload?.itemListElement?.length) {
        result.failureCount++;
        result.notes.push(`Eventbrite ${channel.label}: no JSON-LD listings found`);
        continue;
      }

      result.successCount++;
      const normalized = payload.itemListElement
        .map((entry) => normalizeEventbriteListing(entry.item, channel))
        .filter((event): event is EventResult => event !== null);
      result.events.push(...normalized);
    } catch (error) {
      latencies.push(Date.now() - startedAt);
      if (error instanceof DOMException && error.name === "AbortError") {
        result.timeoutCount++;
        result.notes.push(`Eventbrite ${channel.label}: timeout`);
      } else {
        result.failureCount++;
        result.notes.push(`Eventbrite ${channel.label}: ${String(error)}`);
      }
    }
  }

  result.events = dedupeEvents(result.events);
  result.avgLatencyMs =
    latencies.length > 0
      ? Math.round(latencies.reduce((sum, value) => sum + value, 0) / latencies.length)
      : 0;

  if (result.events.length === 0 && result.notes.length === 0) {
    result.notes.push("Eventbrite returned no local listings");
  }

  return result;
}

function buildChannels(metro: Metro, intent: string): EventbriteChannel[] {
  const state = slugifyState(metro.state);
  const city = slugify(metro.city);
  const base = `https://www.eventbrite.com/d/${state}--${city}`;

  switch (intent) {
    case "biggest_tonight":
      return [
        { label: "all-events", path: `${base}/events/`, fallbackType: "other live event" },
        { label: "music", path: `${base}/music--events/`, fallbackType: "concert" },
      ];
    case "exclusive_hot":
      return [
        { label: "nightlife", path: `${base}/nightlife--events/`, fallbackType: "party / nightlife" },
        { label: "music", path: `${base}/music--events/`, fallbackType: "concert" },
      ];
    case "last_minute_plans":
      return [
        { label: "all-events", path: `${base}/events/`, fallbackType: "social / community event" },
        { label: "nightlife", path: `${base}/nightlife--events/`, fallbackType: "party / nightlife" },
      ];
    default:
      return [
        { label: "all-events", path: `${base}/events/`, fallbackType: "social / community event" },
        { label: "nightlife", path: `${base}/nightlife--events/`, fallbackType: "party / nightlife" },
        { label: "sports-fitness", path: `${base}/sports-and-fitness--events/`, fallbackType: "sports event" },
      ];
  }
}

function extractJsonLd(html: string): EventbriteListPayload | null {
  const match = html.match(
    /<script[^>]*type=\"application\/ld\+json\"[^>]*>([\s\S]*?)<\/script>/
  );
  if (!match?.[1]) return null;

  try {
    return JSON.parse(match[1].trim()) as EventbriteListPayload;
  } catch {
    return null;
  }
}

function normalizeEventbriteListing(
  item: EventbriteItem | undefined,
  channel: EventbriteChannel
): EventResult | null {
  if (!item?.url || !item.name) {
    return null;
  }

  const address = item.location?.address;
  const eventType = inferEventbriteType(item, channel);
  const sourceEventId = eventbriteIdFromUrl(item.url);

  return {
    id: `eventbrite:${sourceEventId}`,
    source: "eventbrite",
    sourceEventId,
    sourceUrl: item.url,
    title: item.name,
    shortDescription: shorten(item.description),
    fullDescription: item.description || undefined,
    eventType,
    startAtUTC: toIsoString(item.startDate),
    endAtUTC: toIsoString(item.endDate),
    startLocal: toIsoString(item.startDate),
    endLocal: toIsoString(item.endDate),
    venueName: item.location?.name || undefined,
    addressLine1: address?.streetAddress || undefined,
    city: address?.addressLocality || undefined,
    state: address?.addressRegion || undefined,
    postalCode: address?.postalCode || undefined,
    country: address?.addressCountry || "US",
    latitude: item.location?.geo?.latitude ? parseFloat(item.location.geo.latitude) : undefined,
    longitude: item.location?.geo?.longitude ? parseFloat(item.location.geo.longitude) : undefined,
    imageUrl: item.image || undefined,
    status: "scheduled",
    ticketUrl: item.url,
    tags: [channel.label].filter(Boolean),
    rawSourcePayload: {
      eventbrite_url: item.url,
      eventbrite_channel: channel.label,
      eventbrite_location_name: item.location?.name,
    },
  };
}

function inferEventbriteType(
  item: EventbriteItem | undefined,
  channel: EventbriteChannel
): string {
  const content = `${item?.name || ""} ${item?.description || ""}`.toLowerCase();
  const channelHint = channel.label.toLowerCase();
  if (
    content.includes("kids") ||
    content.includes("family") ||
    content.includes("playdate") ||
    content.includes("workshop") ||
    content.includes("screening") ||
    content.includes("panel")
  ) {
    return "social / community event";
  }
  if (
    content.includes("nightlife") ||
    content.includes("party") ||
    content.includes("dj") ||
    (content.includes("club") &&
      !content.includes("kids club") &&
      !content.includes("clubhouse"))
  ) {
    return "party / nightlife";
  }
  if (content.includes("music") || content.includes("concert") || content.includes("festival")) {
    return "concert";
  }
  if (content.includes("sports") || content.includes("fitness") || content.includes("run")) {
    return "sports event";
  }
  if (content.includes("comedy")) {
    return "other live event";
  }
  if (content.includes("market") || content.includes("community")) {
    return "social / community event";
  }
  if (channelHint.includes("nightlife")) return "party / nightlife";
  if (channelHint.includes("music")) return "concert";
  if (channelHint.includes("sports")) return "sports event";
  return channel.fallbackType;
}

function dedupeEvents(events: EventResult[]): EventResult[] {
  const deduped = new Map<string, EventResult>();
  for (const event of events) {
    const key = event.ticketUrl || event.sourceEventId;
    if (!deduped.has(key)) {
      deduped.set(key, event);
    }
  }
  return [...deduped.values()];
}

function eventbriteIdFromUrl(url: string): string {
  const match = url.match(/-tickets-(\d+)/);
  return match?.[1] || slugify(url);
}

function slugify(value: string): string {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

function slugifyState(value: string): string {
  return value.trim().toLowerCase();
}

function shorten(value?: string, maxLength: number = 220): string | undefined {
  if (!value) return undefined;
  const cleaned = value.replace(/\s+/g, " ").trim();
  if (cleaned.length <= maxLength) return cleaned;
  return `${cleaned.slice(0, maxLength - 3).trim()}...`;
}

function toIsoString(value?: string): string | undefined {
  if (!value) return undefined;
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? undefined : parsed.toISOString();
}
