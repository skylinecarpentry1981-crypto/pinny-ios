# Stage 3.6 — Family Places (app-open only)

Owner decisions (2026-09-15): keep the **app-open-only** principle, and fill the Life360 "place alerts" gap within that, with **no extra battery use**.
No background location, no Always permission, no location history. This contract is the single source of truth for Designer, Frontend, Backend and Overseer in Stage 3.6.
The Designer folds the UI parts into DESIGN-SPEC §12; the Backend folds the data parts into BACKEND-SETUP.

## 1. Principle (unchanged)

- Location is shared only on app open, Refresh, Check in and SOS.
- Banned APIs stay banned (Overseer greps): `requestAlwaysAuthorization`, `allowsBackgroundLocationUpdates`, `startUpdatingLocation`,
  `startMonitoringSignificantLocationChanges`, `startMonitoring(for:)`, `CLCircularRegion` monitoring, `startMonitoringVisits`,
  `CLBackgroundActivitySession`, `CLLocationUpdate`, `CLMonitor`, `location` in `UIBackgroundModes`, CoreMotion.
- Places are used only to **label** a location that was already shared. Nothing is monitored.

## 2. What Stage 3.6 adds

1. **Family Places.** Members save up to 10 named places (Home, School, Work, custom) with a radius.
2. **"At {place}" label.** The drawer row's place line shows "At Home" when that member's last shared location is inside a Place.
3. **Place annotations** on the Map tab (icon + name).
4. **Place-aware check-in push.** When a member opens the app inside a Place, the existing check-in push says where they are.
5. **`src` on every location write**, so SOS in Stage 4 does not also trigger a check-in push.

## 3. Data

### `families/{familyId}/places/{placeId}` (new subcollection)
| Field | Type | Rule |
|---|---|---|
| `name` | string | 1–30 chars |
| `icon` | string | one of `"home" | "school" | "work" | "pin"` |
| `lat`, `lng` | number | valid ranges |
| `radius` | int | 100–500 (metres) |
| `createdBy` | string | == auth uid on create; immutable |
| `createdAt` | timestamp | == request.time on create; immutable |

- Read, create, update, delete: any member of the family. Update may change only `name`, `icon`, `lat`, `lng`, `radius`.
- At most 10 places per family, enforced by the client (rules cannot count documents).

### `users/{uid}.lastLocation` — new optional field
`src`: `"open" | "manual" | "sos"`. Every client location write sets it from Stage 3.6 on (`open` = automatic share on app open or foreground, `manual` = Refresh or Check in, `sos` = Stage 4).

## 4. "Inside a place" (computed on the viewer's device, never stored)

- Inside when the distance from `lastLocation` to the place centre is ≤ `radius`.
- Not inside when `acc` > `radius` (the fix is less precise than the place): show the normal address line instead. Docs without `acc` (legacy) are allowed to match.
- If several places match, the nearest centre wins.
- Place line priority: "At {placeName}" > "Near {street}, {suburb}" > "Near {suburb}" > "Location shared" > "No location yet".
- VoiceOver: "Mum, at Home, updated 12 min ago, battery 40 percent".

## 5. Cloud Functions

- `onLocationUpdated`:
  - Send the check-in push only when `src` is `"open"`, `"manual"` or absent (legacy). Never for `"sos"`.
  - Before sending, read the family's `places` and apply the §4 rule on the server.
  - Push copy: title "{name} checked in"; body "At {placeName}." when inside a place, otherwise "Tap to see where they are."
  - Keep the existing 10-minute debounce and `notifyOnCheckIn` opt-in.
- `purgeFamily` also deletes the `places` subcollection.
- No new triggers.

## 6. UI (Designer details in DESIGN-SPEC §12)

- **Family tab → Places section:** list of places (icon, name, radius). "Add place" row. Swipe to delete (confirmation). Tap to edit. "Add place" is hidden at 10 places, with a footnote "Up to 10 places."
- **Place editor:** full-screen map with a fixed centre pin and a radius circle drawn over the map in screen space (the iOS 16 SwiftUI Map has no overlays). Search field (Apple `MKLocalSearch`; the search text is sent to Apple, nothing is stored by FamilyMap). "Use my location" button. Radius slider 100–500 m in 50 m steps. Name field with preset chips Home / School / Work (sets name and icon). Save / Cancel.
- **Map tab:** place annotations drawn below member pins; tapping one does nothing in 3.6.
- **Drawer row:** place line per §4.
- **Empty state (no places):** a Places row in the Family tab: "Add places like Home or School to see who's there."

## 7. Copy

- Settings privacy line: last sentence becomes "Delete your account at any time to remove your account and location data." (places are shared family data and stay with the family).
- BACKEND §9 adds: "Saved places are visible to your family only." and "Place search text is sent to Apple to find addresses."
- No permission strings change.
