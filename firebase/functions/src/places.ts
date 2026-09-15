/**
 * "Inside a place" rule (docs/STAGE-3.6-CONTRACT.md §4), server side.
 *
 * Kept pure (no firebase-admin initialisation) so it can be unit-tested:
 * test/places.test.mjs runs against the compiled lib/places.js.
 */

const EARTH_RADIUS_M = 6_371_008.8; // mean Earth radius

/** The slice of a places doc the rule needs (PlaceDoc satisfies it). */
export interface PlaceArea {
  lat: number;
  lng: number;
  radius: number; // metres
}

/** The slice of lastLocation the rule needs. */
export interface PlaceFix {
  lat: number;
  lng: number;
  acc?: number; // metres
}

/** Great-circle (haversine) distance in metres. */
export function distanceMetres(aLat: number, aLng: number, bLat: number, bLng: number): number {
  const rad = Math.PI / 180;
  const dLat = (bLat - aLat) * rad;
  const dLng = (bLng - aLng) * rad;
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(aLat * rad) * Math.cos(bLat * rad) * Math.sin(dLng / 2) ** 2;
  return 2 * EARTH_RADIUS_M * Math.asin(Math.min(1, Math.sqrt(h)));
}

/**
 * The place `location` is inside, or null. A place matches when:
 *   - distance to its centre <= radius, AND
 *   - acc is absent (legacy) or acc <= radius (the fix is at least as
 *     precise as the place)
 * Several matches -> the nearest centre wins.
 */
export function placeFor<P extends PlaceArea>(location: PlaceFix, places: readonly P[]): P | null {
  let best: P | null = null;
  let bestDistance = Infinity;
  for (const p of places) {
    if (location.acc !== undefined && location.acc > p.radius) continue;
    const d = distanceMetres(location.lat, location.lng, p.lat, p.lng);
    if (d <= p.radius && d < bestDistance) {
      best = p;
      bestDistance = d;
    }
  }
  return best;
}
