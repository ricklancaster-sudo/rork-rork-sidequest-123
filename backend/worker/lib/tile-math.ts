export interface TileKey {
  z: number;
  x: number;
  y: number;
}

export interface TileBounds {
  northLatitude: number;
  southLatitude: number;
  eastLongitude: number;
  westLongitude: number;
}

export function latLonToTile(lat: number, lon: number, zoom: number): TileKey {
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

export function tileBounds(tile: TileKey): TileBounds {
  const scale = Math.pow(2, tile.z);
  const westLongitude = (tile.x / scale) * 360 - 180;
  const eastLongitude = ((tile.x + 1) / scale) * 360 - 180;
  const northLatitude = tileYToLat(tile.y, tile.z);
  const southLatitude = tileYToLat(tile.y + 1, tile.z);
  return { northLatitude, southLatitude, eastLongitude, westLongitude };
}

function tileYToLat(y: number, zoom: number): number {
  const scale = Math.pow(2, zoom);
  const mercator = Math.PI - (2 * Math.PI * y) / scale;
  return (Math.atan(Math.sinh(mercator)) * 180) / Math.PI;
}

export function recommendedZoom(latSpan: number, lonSpan: number): number {
  const span = Math.max(latSpan, lonSpan);
  if (span < 0.02) return 14;
  if (span < 0.05) return 13;
  if (span < 0.12) return 12;
  if (span < 0.3) return 11;
  if (span < 0.75) return 10;
  if (span < 1.5) return 9;
  if (span < 3.0) return 8;
  if (span < 7.0) return 7;
  if (span < 14.0) return 6;
  return 5;
}

export function tileKeyString(intent: string, countryCode: string, state: string | null, z: number, x: number, y: number): string {
  const parts = [intent, countryCode.toUpperCase(), z.toString(), x.toString(), y.toString()];
  if (state) parts.splice(2, 0, state);
  return parts.join("::");
}

export function tilesForMetro(lat: number, lon: number, zoom: number, padding: number = 2): TileKey[] {
  const center = latLonToTile(lat, lon, zoom);
  const tiles: TileKey[] = [];
  const maxTile = Math.pow(2, zoom) - 1;
  for (let dx = -padding; dx <= padding; dx++) {
    for (let dy = -padding; dy <= padding; dy++) {
      const x = Math.min(Math.max(center.x + dx, 0), maxTile);
      const y = Math.min(Math.max(center.y + dy, 0), maxTile);
      tiles.push({ z: zoom, x, y });
    }
  }
  return tiles;
}
