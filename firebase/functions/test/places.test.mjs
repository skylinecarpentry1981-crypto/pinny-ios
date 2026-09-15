// Unit test for the "inside a place" rule (pure logic, no emulator).
// `npm test` builds first, then runs this against lib/.

import { it } from "node:test";
import assert from "node:assert/strict";
import { distanceMetres, placeFor } from "../lib/places.js";

const LAT = -37.8136; // Melbourne CBD
const LNG = 144.9631;
const M_PER_DEG_LAT = 111_195; // ~1° of latitude in metres

/** A point `m` metres due north of the centre. */
const north = (m, extra = {}) => ({ lat: LAT + m / M_PER_DEG_LAT, lng: LNG, ...extra });
const home = { name: "Home", icon: "home", lat: LAT, lng: LNG, radius: 150 };

it("inside the radius -> that place", () => {
  assert.equal(placeFor(north(100, { acc: 10 }), [home]), home);
});

it("outside the radius -> null", () => {
  assert.equal(placeFor(north(200, { acc: 10 }), [home]), null);
});

it("boundary: distance == radius is inside, just beyond is outside", () => {
  const fix = north(100);
  const d = distanceMetres(LAT, LNG, fix.lat, fix.lng);
  assert.ok(Math.abs(d - 100) < 0.5, `haversine ~100 m, got ${d}`);
  const exact = { ...home, radius: d };
  assert.equal(placeFor(fix, [exact]), exact);
  assert.equal(placeFor(fix, [{ ...home, radius: d - 0.001 }]), null);
});

it("acc 300 with radius 150 -> null even at the centre (fix less precise than the place)", () => {
  assert.equal(placeFor({ lat: LAT, lng: LNG, acc: 300 }, [home]), null);
});

it("acc 100 with radius 150 -> inside", () => {
  assert.equal(placeFor({ lat: LAT, lng: LNG, acc: 100 }, [home]), home);
});

it("acc == radius -> inside", () => {
  assert.equal(placeFor({ lat: LAT, lng: LNG, acc: 150 }, [home]), home);
});

it("acc absent (legacy) -> inside", () => {
  assert.equal(placeFor({ lat: LAT, lng: LNG }, [home]), home);
});

it("acc is checked per place: acc 300 skips a 150 m place but can match a 500 m one", () => {
  const bigPark = { name: "Park", icon: "pin", lat: LAT + 200 / M_PER_DEG_LAT, lng: LNG, radius: 500 };
  // At Home's centre: nearest is Home (0 m) but acc 300 > 150, so Park (200 m) wins.
  assert.equal(placeFor({ lat: LAT, lng: LNG, acc: 300 }, [home, bigPark]), bigPark);
});

it("two overlapping places -> nearest centre wins", () => {
  const school = { name: "School", icon: "school", lat: LAT + 300 / M_PER_DEG_LAT, lng: LNG, radius: 500 };
  const bigHome = { ...home, radius: 500 };
  // 250 m north: 250 m from Home, 50 m from School — inside both.
  assert.equal(placeFor(north(250), [bigHome, school]), school);
  assert.equal(placeFor(north(250), [school, bigHome]), school); // order-independent
  // 100 m north: 100 m from Home, 200 m from School.
  assert.equal(placeFor(north(100), [school, bigHome]), bigHome);
});

it("empty list -> null", () => {
  assert.equal(placeFor(north(0), []), null);
});
