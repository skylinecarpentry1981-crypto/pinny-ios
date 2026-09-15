// FamilyMap — Firestore security rules tests
//
// Run with `npm test` (wraps `firebase emulators:exec --only firestore`).
// Uses the demo project id `demo-familymap`; never touches a real project.
// Every test starts from an empty database (clearFirestore in beforeEach).

import { after, before, beforeEach, describe, it } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import {
  arrayRemove,
  arrayUnion,
  collection,
  deleteDoc,
  deleteField,
  doc,
  getDoc,
  getDocs,
  query,
  serverTimestamp,
  setDoc,
  updateDoc,
  where,
  writeBatch,
} from "firebase/firestore";

const RULES = resolve(dirname(fileURLToPath(import.meta.url)), "../firestore.rules");

const A = "uid_alice"; // family creator
const B = "uid_bob";   // joins / leaves
const C = "uid_carol"; // outsider / second family
const FAM = "familyA";
const FAM2 = "familyC";
const CODE = "ABC123";
const CODE2 = "ZZZ999";

let env;
// One Firestore instance per uid (batch refs must share an instance).
const instances = new Map();
function db(uid) {
  if (!instances.has(uid)) instances.set(uid, env.authenticatedContext(uid).firestore());
  return instances.get(uid);
}

const userDoc = (extra = {}) => ({
  name: "Alice",
  notifyOnCheckIn: true,
  updatedAt: serverTimestamp(),
  ...extra,
});

const familyDoc = (uid, extra = {}) => ({
  name: "The Smiths",
  inviteCode: CODE,
  members: [uid],
  createdBy: uid,
  createdAt: serverTimestamp(),
  ...extra,
});

/** Seed data with rules disabled (admin context). */
async function seed(fn) {
  await env.withSecurityRulesDisabled((ctx) => fn(ctx.firestore()));
}

/** Family A (creator A, member B) + invite code + both user docs. */
async function seedFamilyAB() {
  await seed(async (adb) => {
    await setDoc(doc(adb, "families", FAM), {
      name: "The Smiths",
      inviteCode: CODE,
      members: [A, B],
      createdBy: A,
      createdAt: new Date(),
    });
    await setDoc(doc(adb, "inviteCodes", CODE), { familyId: FAM });
    await setDoc(doc(adb, "users", A), { name: "Alice", notifyOnCheckIn: true, updatedAt: new Date(), familyId: FAM });
    await setDoc(doc(adb, "users", B), { name: "Bob", notifyOnCheckIn: true, updatedAt: new Date(), familyId: FAM });
  });
}

/** Family A with only the creator, plus user B with no family. */
async function seedFamilyAOnly() {
  await seed(async (adb) => {
    await setDoc(doc(adb, "families", FAM), {
      name: "The Smiths",
      inviteCode: CODE,
      members: [A],
      createdBy: A,
      createdAt: new Date(),
    });
    await setDoc(doc(adb, "inviteCodes", CODE), { familyId: FAM });
    await setDoc(doc(adb, "users", A), { name: "Alice", notifyOnCheckIn: true, updatedAt: new Date(), familyId: FAM });
    await setDoc(doc(adb, "users", B), { name: "Bob", notifyOnCheckIn: true, updatedAt: new Date() });
  });
}

/** The exact "create family" batch from docs/BACKEND-SETUP.md §7. */
function createFamilyBatch(uid, { family = {}, code = CODE, familyId = FAM } = {}) {
  const batch = writeBatch(db(uid));
  batch.set(doc(db(uid), "families", familyId), familyDoc(uid, { inviteCode: code, ...family }));
  batch.set(doc(db(uid), "inviteCodes", code), { familyId });
  batch.set(doc(db(uid), "users", uid), { familyId }, { merge: true });
  return batch;
}

before(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-familymap",
    firestore: { rules: readFileSync(RULES, "utf8") },
  });
});

beforeEach(async () => {
  await env.clearFirestore();
});

after(async () => {
  await env.cleanup();
});

// ---------------------------------------------------------------------------
// users/{uid}
// ---------------------------------------------------------------------------
describe("users", () => {
  it("owner creates own doc with valid shape", async () => {
    await assertSucceeds(setDoc(doc(db(A), "users", A), userDoc()));
  });

  it("create without updatedAt fails", async () => {
    const { updatedAt, ...d } = userDoc();
    await assertFails(setDoc(doc(db(A), "users", A), d));
  });

  it("create with 41-char name fails", async () => {
    await assertFails(setDoc(doc(db(A), "users", A), userDoc({ name: "x".repeat(41) })));
  });

  it("create with unknown key fails", async () => {
    await assertFails(setDoc(doc(db(A), "users", A), userDoc({ isAdmin: true })));
  });

  it("another uid cannot create my doc", async () => {
    await assertFails(setDoc(doc(db(B), "users", A), userDoc()));
  });

  it("unauthenticated cannot create", async () => {
    await assertFails(setDoc(doc(env.unauthenticatedContext().firestore(), "users", A), userDoc()));
  });

  it("read own doc", async () => {
    await seedFamilyAB();
    await assertSucceeds(getDoc(doc(db(A), "users", A)));
  });

  it("read a user in the same family", async () => {
    await seedFamilyAB();
    await assertSucceeds(getDoc(doc(db(A), "users", B)));
  });

  it("list users in my family (familyId == mine)", async () => {
    await seedFamilyAB();
    await assertSucceeds(getDocs(query(collection(db(A), "users"), where("familyId", "==", FAM))));
  });

  it("read a user in a different family fails", async () => {
    await seedFamilyAB();
    await seed(async (adb) => {
      await setDoc(doc(adb, "families", FAM2), { name: "Other", inviteCode: CODE2, members: [C], createdBy: C, createdAt: new Date() });
      await setDoc(doc(adb, "users", C), { name: "Carol", notifyOnCheckIn: true, updatedAt: new Date(), familyId: FAM2 });
    });
    await assertFails(getDoc(doc(db(A), "users", C)));
  });

  it("read another user when neither has a family fails", async () => {
    await seed(async (adb) => {
      await setDoc(doc(adb, "users", A), { name: "Alice", notifyOnCheckIn: true, updatedAt: new Date() });
      await setDoc(doc(adb, "users", B), { name: "Bob", notifyOnCheckIn: true, updatedAt: new Date() });
    });
    await assertFails(getDoc(doc(db(A), "users", B)));
  });

  it("update familyId to a family I am not a member of (no batch) fails", async () => {
    await seedFamilyAOnly();
    await assertFails(updateDoc(doc(db(B), "users", B), { familyId: FAM }));
  });

  it("update familyId to a non-existent family fails", async () => {
    await seedFamilyAOnly();
    await assertFails(updateDoc(doc(db(B), "users", B), { familyId: "nope" }));
  });

  it("plain location update (familyId unchanged) succeeds", async () => {
    await seedFamilyAB();
    await assertSucceeds(
      updateDoc(doc(db(A), "users", A), {
        lastLocation: { lat: -37.8, lng: 144.9, updatedAt: serverTimestamp() },
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it("owner deletes own doc", async () => {
    await seedFamilyAB();
    await assertSucceeds(deleteDoc(doc(db(A), "users", A)));
  });

  it("other uid cannot delete my doc", async () => {
    await seedFamilyAB();
    await assertFails(deleteDoc(doc(db(B), "users", A)));
  });
});

// ---------------------------------------------------------------------------
// families — create batch
// ---------------------------------------------------------------------------
describe("families: create", () => {
  beforeEach(async () => {
    await seed((adb) => setDoc(doc(adb, "users", A), { name: "Alice", notifyOnCheckIn: true, updatedAt: new Date() }));
  });

  it("create batch (family + inviteCode + users.familyId) succeeds", async () => {
    await assertSucceeds(createFamilyBatch(A).commit());
  });

  it("members != [uid] fails", async () => {
    await assertFails(createFamilyBatch(A, { family: { members: [A, B] } }).commit());
    await assertFails(createFamilyBatch(A, { family: { members: [B] } }).commit());
  });

  it("createdBy != uid fails", async () => {
    await assertFails(createFamilyBatch(A, { family: { createdBy: B } }).commit());
  });

  it("createdAt as client Date fails", async () => {
    await assertFails(createFamilyBatch(A, { family: { createdAt: new Date(Date.now() - 5000) } }).commit());
  });

  it("lowercase invite code fails", async () => {
    await assertFails(createFamilyBatch(A, { code: "abc123" }).commit());
  });

  it("5-char invite code fails", async () => {
    await assertFails(createFamilyBatch(A, { code: "ABC12" }).commit());
  });

  it("inviteCodes doc alone (no family in batch) fails", async () => {
    await assertFails(setDoc(doc(db(A), "inviteCodes", CODE), { familyId: FAM }));
  });

  it("family alone (no inviteCodes in batch) fails", async () => {
    await assertFails(setDoc(doc(db(A), "families", FAM), familyDoc(A)));
  });

  it("duplicate invite code (collision) fails", async () => {
    await seed(async (adb) => {
      await setDoc(doc(adb, "families", FAM2), { name: "Other", inviteCode: CODE, members: [C], createdBy: C, createdAt: new Date() });
      await setDoc(doc(adb, "inviteCodes", CODE), { familyId: FAM2 });
    });
    await assertFails(createFamilyBatch(A, { code: CODE }).commit());
    // and a fresh code still works after the retry
    await assertSucceeds(createFamilyBatch(A, { code: "NEW001" }).commit());
  });
});

// ---------------------------------------------------------------------------
// families — join
// ---------------------------------------------------------------------------
describe("families: join", () => {
  beforeEach(seedFamilyAOnly);

  it("B reads inviteCodes/{code}", async () => {
    await assertSucceeds(getDoc(doc(db(B), "inviteCodes", CODE)));
  });

  it("unauthenticated cannot read inviteCodes", async () => {
    await assertFails(getDoc(doc(env.unauthenticatedContext().firestore(), "inviteCodes", CODE)));
  });

  it("listing inviteCodes fails", async () => {
    await assertFails(getDocs(collection(db(B), "inviteCodes")));
  });

  it("join batch (arrayUnion self + users.familyId) succeeds", async () => {
    const batch = writeBatch(db(B));
    batch.update(doc(db(B), "families", FAM), { members: arrayUnion(B) });
    batch.set(doc(db(B), "users", B), { familyId: FAM }, { merge: true });
    await assertSucceeds(batch.commit());
  });

  it("arrayUnion of a third uid by B fails", async () => {
    await assertFails(updateDoc(doc(db(B), "families", FAM), { members: arrayUnion(C) }));
    const batch = writeBatch(db(B));
    batch.update(doc(db(B), "families", FAM), { members: arrayUnion(B, C) });
    batch.set(doc(db(B), "users", B), { familyId: FAM }, { merge: true });
    await assertFails(batch.commit());
  });

  it("non-creator updating family name fails", async () => {
    await seedFamilyAB();
    await assertFails(updateDoc(doc(db(B), "families", FAM), { name: "Bob's" }));
  });

  it("creator renames family", async () => {
    await assertSucceeds(updateDoc(doc(db(A), "families", FAM), { name: "Renamed" }));
  });

  it("listing families by inviteCode fails", async () => {
    await assertFails(getDocs(query(collection(db(B), "families"), where("inviteCode", "==", CODE))));
  });

  it("listing families by members array-contains self succeeds", async () => {
    await assertSucceeds(getDocs(query(collection(db(A), "families"), where("members", "array-contains", A))));
  });

  it("non-member cannot read family doc", async () => {
    await assertFails(getDoc(doc(db(B), "families", FAM)));
  });
});

// ---------------------------------------------------------------------------
// families — leave
// ---------------------------------------------------------------------------
describe("families: leave", () => {
  beforeEach(seedFamilyAB);

  it("leave batch with familyId: null succeeds", async () => {
    const batch = writeBatch(db(B));
    batch.update(doc(db(B), "families", FAM), { members: arrayRemove(B) });
    batch.update(doc(db(B), "users", B), { familyId: null });
    await assertSucceeds(batch.commit());
  });

  it("leave batch with familyId: deleteField() succeeds", async () => {
    const batch = writeBatch(db(B));
    batch.update(doc(db(B), "families", FAM), { members: arrayRemove(B) });
    batch.update(doc(db(B), "users", B), { familyId: deleteField() });
    await assertSucceeds(batch.commit());
  });

  it("removing another member fails", async () => {
    await assertFails(updateDoc(doc(db(B), "families", FAM), { members: arrayRemove(A) }));
  });

  it("leave while keeping users.familyId pointing at the family fails", async () => {
    // A departed member must not keep a familyId that would still satisfy the
    // users read rule (familyId == requesterFamilyId) -> location leak.
    const batch = writeBatch(db(B));
    batch.update(doc(db(B), "families", FAM), { members: arrayRemove(B) });
    batch.update(doc(db(B), "users", B), { familyId: FAM, updatedAt: serverTimestamp() });
    await assertFails(batch.commit());
  });

  it("leave without clearing users.familyId (family write alone) fails", async () => {
    await assertFails(updateDoc(doc(db(B), "families", FAM), { members: arrayRemove(B) }));
  });

  it("creator leaves while others remain succeeds (server promotes members[0])", async () => {
    const batch = writeBatch(db(A));
    batch.update(doc(db(A), "families", FAM), { members: arrayRemove(A) });
    batch.update(doc(db(A), "users", A), { familyId: null });
    await assertSucceeds(batch.commit());
  });

  it("last member leaves -> members == [] succeeds (server purges)", async () => {
    await seedFamilyAOnly();
    const batch = writeBatch(db(A));
    batch.update(doc(db(A), "families", FAM), { members: arrayRemove(A) });
    batch.update(doc(db(A), "users", A), { familyId: null });
    await assertSucceeds(batch.commit());
    await env.withSecurityRulesDisabled(async (ctx) => {
      const snap = await getDoc(doc(ctx.firestore(), "families", FAM));
      assert.deepEqual(snap.data().members, []);
    });
  });
});

// ---------------------------------------------------------------------------
// families — delete
// ---------------------------------------------------------------------------
// Clients never delete families or invite codes; the server purges them
// (purgeFamily) once the last member leaves.
describe("families: delete (server only)", () => {
  it("creator as sole member cannot delete family", async () => {
    await seedFamilyAOnly();
    await assertFails(deleteDoc(doc(db(A), "families", FAM)));
  });

  it("creator cannot delete family while others remain", async () => {
    await seedFamilyAB();
    await assertFails(deleteDoc(doc(db(A), "families", FAM)));
  });

  it("non-creator member cannot delete family", async () => {
    await seedFamilyAB();
    await assertFails(deleteDoc(doc(db(B), "families", FAM)));
  });

  it("nobody can delete an empty family", async () => {
    await seed((adb) => setDoc(doc(adb, "families", FAM), { name: "X", inviteCode: CODE, members: [], createdBy: A, createdAt: new Date() }));
    await assertFails(deleteDoc(doc(db(A), "families", FAM)));
  });

  it("creator cannot delete inviteCodes", async () => {
    await seedFamilyAOnly();
    await assertFails(deleteDoc(doc(db(A), "inviteCodes", CODE)));
  });

  it("non-creator cannot delete inviteCodes", async () => {
    await seedFamilyAB();
    await assertFails(deleteDoc(doc(db(B), "inviteCodes", CODE)));
  });

  it("creator cannot delete family + inviteCodes in one batch", async () => {
    await seedFamilyAOnly();
    const batch = writeBatch(db(A));
    batch.delete(doc(db(A), "families", FAM));
    batch.delete(doc(db(A), "inviteCodes", CODE));
    batch.update(doc(db(A), "users", A), { familyId: null });
    await assertFails(batch.commit());
  });
});

// ---------------------------------------------------------------------------
// chats/{familyId}/messages
// ---------------------------------------------------------------------------
describe("messages", () => {
  beforeEach(seedFamilyAB);

  const msg = (uid, extra = {}) => ({
    senderId: uid,
    senderName: "Bob",
    text: "hello",
    type: "normal",
    createdAt: serverTimestamp(),
    ...extra,
  });

  it("member creates a message", async () => {
    await assertSucceeds(setDoc(doc(db(B), "chats", FAM, "messages", "m1"), msg(B)));
  });

  it("member creates an SOS message", async () => {
    await assertSucceeds(setDoc(doc(db(B), "chats", FAM, "messages", "m2"), msg(B, { type: "sos" })));
  });

  it("member reads messages", async () => {
    await seed((adb) => setDoc(doc(adb, "chats", FAM, "messages", "m1"), { ...msg(A), createdAt: new Date() }));
    await assertSucceeds(getDocs(collection(db(B), "chats", FAM, "messages")));
  });

  it("non-member cannot create", async () => {
    await assertFails(setDoc(doc(db(C), "chats", FAM, "messages", "m1"), msg(C)));
  });

  it("non-member cannot read", async () => {
    await assertFails(getDocs(collection(db(C), "chats", FAM, "messages")));
  });

  it("senderId of someone else fails", async () => {
    await assertFails(setDoc(doc(db(B), "chats", FAM, "messages", "m1"), msg(A)));
  });

  it("client createdAt fails", async () => {
    await assertFails(setDoc(doc(db(B), "chats", FAM, "messages", "m1"), msg(B, { createdAt: new Date(Date.now() - 5000) })));
  });

  it("unknown type fails", async () => {
    await assertFails(setDoc(doc(db(B), "chats", FAM, "messages", "m1"), msg(B, { type: "urgent" })));
  });

  it("update and delete fail", async () => {
    await seed((adb) => setDoc(doc(adb, "chats", FAM, "messages", "m1"), { ...msg(B), createdAt: new Date() }));
    await assertFails(updateDoc(doc(db(B), "chats", FAM, "messages", "m1"), { text: "edited" }));
    await assertFails(deleteDoc(doc(db(B), "chats", FAM, "messages", "m1")));
  });

  // Stage 5 — chat limits (DESIGN-SPEC §13.4).
  const msgRef = (id = "m1") => doc(db(B), "chats", FAM, "messages", id);

  it("text of 1 and 1000 chars succeeds", async () => {
    await assertSucceeds(setDoc(msgRef("m1"), msg(B, { text: "x" })));
    await assertSucceeds(setDoc(msgRef("m2"), msg(B, { text: "x".repeat(1000) })));
  });

  it("empty text and 1001-char text fail", async () => {
    await assertFails(setDoc(msgRef(), msg(B, { text: "" })));
    await assertFails(setDoc(msgRef(), msg(B, { text: "x".repeat(1001) })));
  });

  it("text as a number fails", async () => {
    await assertFails(setDoc(msgRef(), msg(B, { text: 42 })));
  });

  it("senderName of 40 chars succeeds; empty, 41 chars and non-string fail", async () => {
    await assertSucceeds(setDoc(msgRef("m1"), msg(B, { senderName: "x".repeat(40) })));
    await assertFails(setDoc(msgRef("m2"), msg(B, { senderName: "" })));
    await assertFails(setDoc(msgRef("m2"), msg(B, { senderName: "x".repeat(41) })));
    await assertFails(setDoc(msgRef("m2"), msg(B, { senderName: 7 })));
  });

  it("extra key (imageURL) fails", async () => {
    await assertFails(setDoc(msgRef(), msg(B, { imageURL: "https://example.com/a.png" })));
  });

  it("missing type / senderName / createdAt fails", async () => {
    for (const key of ["type", "senderName", "createdAt"]) {
      const { [key]: _omit, ...d } = msg(B);
      await assertFails(setDoc(msgRef(), d));
    }
  });
});

// ---------------------------------------------------------------------------
// Stage 4 — push token, check-in setting, SOS (DESIGN-SPEC §13)
// ---------------------------------------------------------------------------
describe("stage 4: push token, settings, SOS", () => {
  beforeEach(seedFamilyAB);

  const me = (uid = A) => doc(db(uid), "users", A);
  /** A shared a location an hour ago. */
  const seedOldLocation = () =>
    seed((adb) =>
      updateDoc(doc(adb, "users", A), {
        lastLocation: { lat: -37.8, lng: 144.9, updatedAt: new Date(Date.now() - 60 * 60 * 1000), src: "open" },
      }),
    );

  // pushTokens/{uid} — owner-only { token, updatedAt }.
  const tokenRef = (uid = A, target = A) => doc(db(uid), "pushTokens", target);
  const tokenDoc = (extra = {}) => ({ token: "tok-A", updatedAt: serverTimestamp(), ...extra });
  const seedToken = () =>
    seed((adb) => setDoc(doc(adb, "pushTokens", A), { token: "old-token", updatedAt: new Date(Date.now() - 60 * 1000) }));

  it("owner creates, reads, replaces and deletes own push token", async () => {
    await assertSucceeds(setDoc(tokenRef(), tokenDoc()));
    const snap = await assertSucceeds(getDoc(tokenRef()));
    assert.equal(snap.data().token, "tok-A");
    await assertSucceeds(setDoc(tokenRef(), tokenDoc({ token: "tok-A2" })));
    await assertSucceeds(deleteDoc(tokenRef()));
  });

  it("family member cannot read my push token (get or list)", async () => {
    await seedToken();
    await assertFails(getDoc(tokenRef(B)));
    await assertFails(getDocs(collection(db(B), "pushTokens")));
    await assertFails(getDocs(query(collection(db(B), "pushTokens"), where("token", "==", "old-token"))));
  });

  it("another user cannot create, overwrite or delete my push token", async () => {
    await assertFails(setDoc(tokenRef(B), tokenDoc({ token: "bobs-device" })));
    await seedToken();
    await assertFails(setDoc(tokenRef(B), tokenDoc({ token: "bobs-device" })));
    await assertFails(deleteDoc(tokenRef(B)));
  });

  it("unauthenticated cannot read or write push tokens", async () => {
    await seedToken();
    const anon = env.unauthenticatedContext().firestore();
    await assertFails(getDoc(doc(anon, "pushTokens", A)));
    await assertFails(setDoc(doc(anon, "pushTokens", A), tokenDoc()));
  });

  it("token of 4096 chars succeeds; empty, 4097 chars and non-string fail", async () => {
    await assertSucceeds(setDoc(tokenRef(), tokenDoc({ token: "t".repeat(4096) })));
    await assertFails(setDoc(tokenRef(), tokenDoc({ token: "" })));
    await assertFails(setDoc(tokenRef(), tokenDoc({ token: "t".repeat(4097) })));
    await assertFails(setDoc(tokenRef(), tokenDoc({ token: 12345 })));
  });

  it("bad shape fails: extra key, missing token, missing updatedAt, client updatedAt", async () => {
    await assertFails(setDoc(tokenRef(), tokenDoc({ platform: "ios" })));
    await assertFails(setDoc(tokenRef(), { updatedAt: serverTimestamp() }));
    await assertFails(setDoc(tokenRef(), { token: "tok-A" }));
    await assertFails(setDoc(tokenRef(), tokenDoc({ updatedAt: new Date(Date.now() - 5000) })));
  });

  it("token-only update without a new updatedAt fails", async () => {
    await seedToken();
    await assertFails(updateDoc(tokenRef(), { token: "tok-A2" }));
    await assertSucceeds(updateDoc(tokenRef(), { token: "tok-A2", updatedAt: serverTimestamp() }));
  });

  it("users doc with fcmToken now fails (create and update)", async () => {
    await assertFails(setDoc(doc(db(C), "users", C), userDoc({ fcmToken: "tok-C" })));
    await assertFails(setDoc(doc(db(C), "users", C), userDoc({ fcmToken: null })));
    await seedOldLocation();
    await assertFails(updateDoc(me(), { fcmToken: "tok-A" }));
    await assertFails(updateDoc(me(), { fcmToken: null }));
  });

  it("owner toggles notifyOnCheckIn alone", async () => {
    await assertSucceeds(updateDoc(me(), { notifyOnCheckIn: false }));
    await assertSucceeds(updateDoc(me(), { notifyOnCheckIn: true }));
  });

  it("notifyOnCheckIn as a string or null fails", async () => {
    await assertFails(updateDoc(me(), { notifyOnCheckIn: "false" }));
    await assertFails(updateDoc(me(), { notifyOnCheckIn: null }));
  });

  it("owner toggles notifyOnCheckIn with an old stored lastLocation", async () => {
    await seedOldLocation();
    await assertSucceeds(updateDoc(me(), { notifyOnCheckIn: false }));
  });

  it("another member cannot write my notifyOnCheckIn", async () => {
    await assertFails(updateDoc(me(B), { notifyOnCheckIn: false }));
  });

  it("SOS flow: lastLocation with src 'sos', then a type 'sos' message", async () => {
    await seedOldLocation();
    await assertSucceeds(
      updateDoc(me(), {
        lastLocation: { lat: -37.8136, lng: 144.9631, updatedAt: serverTimestamp(), acc: 8, battery: 55, charging: false, src: "sos" },
        updatedAt: serverTimestamp(),
      }),
    );
    await assertSucceeds(
      setDoc(doc(db(A), "chats", FAM, "messages", "sos1"), {
        senderId: A,
        senderName: "Alice",
        text: "SOS",
        type: "sos",
        createdAt: serverTimestamp(),
      }),
    );
  });

  it("SOS retry with the same message id is rejected once the first write landed (one SOS, never two)", async () => {
    const sos = { senderId: A, senderName: "Alice", text: "SOS", type: "sos", createdAt: serverTimestamp() };
    const ref = doc(db(A), "chats", FAM, "messages", "sos1");
    await assertSucceeds(setDoc(ref, sos));
    await assertFails(setDoc(ref, sos)); // exists -> update -> denied
    const snap = await assertSucceeds(getDoc(ref)); // client sees it exists -> shows Sent
    assert.equal(snap.exists(), true);
  });
});

// ---------------------------------------------------------------------------
// users/{uid}.lastLocation — the client write on app open / refresh:
//   update { lastLocation: { lat, lng, updatedAt: serverTimestamp() },
//            updatedAt: serverTimestamp() }
// ---------------------------------------------------------------------------
describe("location", () => {
  beforeEach(seedFamilyAB);

  const HOUR_MS = 60 * 60 * 1000;
  const loc = (extra = {}) => ({ lat: -37.8136, lng: 144.9631, updatedAt: serverTimestamp(), ...extra });
  const writeLoc = (uid, target, lastLocation) =>
    updateDoc(doc(db(uid), "users", target), { lastLocation, updatedAt: serverTimestamp() });

  /** A shared a location an hour ago (stored updatedAt is old). */
  const seedOldLocation = () =>
    seed((adb) =>
      updateDoc(doc(adb, "users", A), {
        lastLocation: { lat: -37.8, lng: 144.9, updatedAt: new Date(Date.now() - HOUR_MS) },
      }),
    );

  it("owner writes lastLocation with serverTimestamp (replacing an old one)", async () => {
    await seedOldLocation();
    await assertSucceeds(writeLoc(A, A, loc()));
  });

  it("client Date for updatedAt fails (5 s ago spoofed as fresh, and future)", async () => {
    // Not `new Date()`: it can equal the emulator's request.time to the ms (flaky).
    await assertFails(writeLoc(A, A, loc({ updatedAt: new Date(Date.now() - 5000) })));
    await assertFails(writeLoc(A, A, loc({ updatedAt: new Date(Date.now() + HOUR_MS) })));
  });

  it("create with lastLocation requires serverTimestamp", async () => {
    await assertFails(setDoc(doc(db(C), "users", C), userDoc({ lastLocation: loc({ updatedAt: new Date(Date.now() - 5000) }) })));
    await assertSucceeds(setDoc(doc(db(C), "users", C), userDoc({ lastLocation: loc() })));
  });

  it("lat 91 fails", async () => {
    await assertFails(writeLoc(A, A, loc({ lat: 91 })));
  });

  it("lng -181 fails", async () => {
    await assertFails(writeLoc(A, A, loc({ lng: -181 })));
  });

  it("lat as string fails", async () => {
    await assertFails(writeLoc(A, A, loc({ lat: "-37.8" })));
  });

  it("extra key (accuracy) fails", async () => {
    await assertFails(writeLoc(A, A, loc({ accuracy: 5 })));
  });

  it("missing lng fails", async () => {
    const { lng, ...noLng } = loc();
    await assertFails(writeLoc(A, A, noLng));
  });

  // Stage 3.5 — optional acc (metres), battery (int %), charging (bool).
  const full = (extra = {}) => loc({ acc: 12, battery: 80, charging: false, ...extra });

  it("full shape with acc / battery / charging succeeds", async () => {
    await seedOldLocation();
    await assertSucceeds(writeLoc(A, A, full()));
  });

  it("shape without the optional fields still succeeds", async () => {
    await assertSucceeds(writeLoc(A, A, loc()));
  });

  it("battery 101 fails", async () => {
    await assertFails(writeLoc(A, A, full({ battery: 101 })));
  });

  it("battery -1 fails", async () => {
    await assertFails(writeLoc(A, A, full({ battery: -1 })));
  });

  it("battery \"50\" (string) fails", async () => {
    await assertFails(writeLoc(A, A, full({ battery: "50" })));
  });

  it("battery 50.5 (not an int) fails", async () => {
    await assertFails(writeLoc(A, A, full({ battery: 50.5 })));
  });

  it("acc 12.5 (not an int) fails", async () => {
    await assertFails(writeLoc(A, A, full({ acc: 12.5 })));
  });

  it("acc -5 fails", async () => {
    await assertFails(writeLoc(A, A, full({ acc: -5 })));
  });

  it("charging \"yes\" fails", async () => {
    await assertFails(writeLoc(A, A, full({ charging: "yes" })));
  });

  it("unknown key (speed) fails", async () => {
    await assertFails(writeLoc(A, A, full({ speed: 3 })));
  });

  // Stage 3.6 — optional src: 'open' | 'manual' | 'sos'.
  it("src 'open' succeeds", async () => {
    await seedOldLocation();
    await assertSucceeds(writeLoc(A, A, full({ src: "open" })));
  });

  it("src 'background' fails", async () => {
    await assertFails(writeLoc(A, A, full({ src: "background" })));
  });

  it("src as a number fails", async () => {
    await assertFails(writeLoc(A, A, full({ src: 1 })));
  });

  it("battery-only change without a new updatedAt fails", async () => {
    // Dot-path update keeps the old updatedAt -> lastLocation changed but not re-stamped.
    await seedOldLocation();
    await assertFails(updateDoc(doc(db(A), "users", A), { "lastLocation.battery": 50, updatedAt: serverTimestamp() }));
  });

  it("clearing lastLocation with null succeeds", async () => {
    await seedOldLocation();
    await assertSucceeds(updateDoc(doc(db(A), "users", A), { lastLocation: null, updatedAt: serverTimestamp() }));
  });

  it("clearing lastLocation with deleteField() succeeds", async () => {
    await seedOldLocation();
    await assertSucceeds(updateDoc(doc(db(A), "users", A), { lastLocation: deleteField(), updatedAt: serverTimestamp() }));
  });

  it("dotted-path lat update without a new updatedAt fails", async () => {
    await seedOldLocation();
    await assertFails(updateDoc(doc(db(A), "users", A), { "lastLocation.lat": -33.87, updatedAt: serverTimestamp() }));
  });

  it("name-only update with an old stored lastLocation succeeds", async () => {
    await seedOldLocation();
    await assertSucceeds(updateDoc(doc(db(A), "users", A), { name: "Alice B", updatedAt: serverTimestamp() }));
  });

  it("another user cannot write my lastLocation", async () => {
    await assertFails(writeLoc(B, A, loc()));
  });

  it("same-family member reads my lastLocation", async () => {
    await seedOldLocation();
    const snap = await assertSucceeds(getDoc(doc(db(B), "users", A)));
    assert.equal(snap.data().lastLocation.lat, -37.8);
  });

  it("ex-member loses read access as soon as they leave", async () => {
    await seedOldLocation();
    await assertSucceeds(getDoc(doc(db(B), "users", A)));
    const batch = writeBatch(db(B));
    batch.update(doc(db(B), "families", FAM), { members: arrayRemove(B) });
    batch.update(doc(db(B), "users", B), { familyId: null, updatedAt: serverTimestamp() });
    await assertSucceeds(batch.commit());
    await assertFails(getDoc(doc(db(B), "users", A)));
    await assertFails(getDocs(query(collection(db(B), "users"), where("familyId", "==", FAM))));
  });

  it("user with no family cannot read a family member", async () => {
    await seedOldLocation();
    await seed((adb) => setDoc(doc(adb, "users", C), { name: "Carol", notifyOnCheckIn: true, updatedAt: new Date() }));
    await assertFails(getDoc(doc(db(C), "users", A)));
    await assertFails(getDocs(query(collection(db(C), "users"), where("familyId", "==", FAM))));
  });
});

// ---------------------------------------------------------------------------
// families/{familyId}/places — Stage 3.6 Family Places
// ---------------------------------------------------------------------------
describe("places", () => {
  beforeEach(seedFamilyAB);

  const place = (uid, extra = {}) => ({
    name: "Home",
    icon: "home",
    lat: -37.8136,
    lng: 144.9631,
    radius: 150,
    createdBy: uid,
    createdAt: serverTimestamp(),
    ...extra,
  });
  const placeRef = (uid, id = "p1") => doc(db(uid), "families", FAM, "places", id);
  const placesCol = (uid) => collection(db(uid), "families", FAM, "places");
  /** A saved "Home" (created by A) already exists. */
  const seedPlace = () =>
    seed((adb) => setDoc(doc(adb, "families", FAM, "places", "p1"), { ...place(A), createdAt: new Date() }));

  it("member creates a place", async () => {
    await assertSucceeds(setDoc(placeRef(B), place(B)));
  });

  it("non-member create fails", async () => {
    await assertFails(setDoc(placeRef(C), place(C)));
  });

  it("31-char name fails", async () => {
    await assertFails(setDoc(placeRef(B), place(B, { name: "x".repeat(31) })));
  });

  // Overseer 3.6 #1 — name length is counted in UTF-16 units (an emoji counts 2+).
  it("name of 15 emoji (30 UTF-16 units) succeeds", async () => {
    await assertSucceeds(setDoc(placeRef(B), place(B, { name: "🏠".repeat(15) })));
  });

  it("name of 29 chars + 1 emoji (31 UTF-16 units) fails", async () => {
    await assertFails(setDoc(placeRef(B), place(B, { name: "x".repeat(29) + "🏠" })));
  });

  // Overseer 3.6 #7 — shape and membership abuse.
  it("create with an extra key fails", async () => {
    await assertFails(setDoc(placeRef(B), place(B, { color: "red" })));
  });

  it("create missing a key (icon / createdAt) fails", async () => {
    const { icon, ...noIcon } = place(B);
    const { createdAt, ...noCreatedAt } = place(B);
    await assertFails(setDoc(placeRef(B), noIcon));
    await assertFails(setDoc(placeRef(B), noCreatedAt));
  });

  it("update createdAt fails", async () => {
    await seedPlace();
    await assertFails(updateDoc(placeRef(B), { createdAt: serverTimestamp() }));
  });

  it("update adding a key fails", async () => {
    await seedPlace();
    await assertFails(updateDoc(placeRef(B), { note: "gate code 1234" }));
  });

  it("update radius 600 or icon 'car' fails", async () => {
    await seedPlace();
    await assertFails(updateDoc(placeRef(B), { radius: 600 }));
    await assertFails(updateDoc(placeRef(B), { icon: "car" }));
  });

  it("non-member update and delete fail", async () => {
    await seedPlace();
    await assertFails(updateDoc(placeRef(C), { name: "Mine now" }));
    await assertFails(deleteDoc(placeRef(C)));
  });

  it("icon 'car' fails", async () => {
    await assertFails(setDoc(placeRef(B), place(B, { icon: "car" })));
  });

  it("radius 50, 550 and 150.5 fail", async () => {
    await assertFails(setDoc(placeRef(B), place(B, { radius: 50 })));
    await assertFails(setDoc(placeRef(B), place(B, { radius: 550 })));
    await assertFails(setDoc(placeRef(B), place(B, { radius: 150.5 })));
  });

  it("createdBy of someone else fails", async () => {
    await assertFails(setDoc(placeRef(B), place(A)));
  });

  it("client createdAt fails", async () => {
    // Not `new Date()`: it can equal the emulator's request.time to the ms (flaky).
    await assertFails(setDoc(placeRef(B), place(B, { createdAt: new Date(Date.now() - 5000) })));
  });

  it("member updates name (place created by another member)", async () => {
    await seedPlace();
    await assertSucceeds(updateDoc(placeRef(B), { name: "Nan's" }));
  });

  it("update createdBy fails", async () => {
    await seedPlace();
    await assertFails(updateDoc(placeRef(B), { createdBy: B }));
  });

  it("member deletes a place", async () => {
    await seedPlace();
    await assertSucceeds(deleteDoc(placeRef(B)));
  });

  it("non-member read fails", async () => {
    await seedPlace();
    await assertFails(getDoc(placeRef(C)));
    await assertFails(getDocs(placesCol(C)));
  });

  it("ex-member loses read access as soon as they leave", async () => {
    await seedPlace();
    await assertSucceeds(getDocs(placesCol(B)));
    const batch = writeBatch(db(B));
    batch.update(doc(db(B), "families", FAM), { members: arrayRemove(B) });
    batch.update(doc(db(B), "users", B), { familyId: null, updatedAt: serverTimestamp() });
    await assertSucceeds(batch.commit());
    await assertFails(getDoc(placeRef(B)));
    await assertFails(getDocs(placesCol(B)));
  });
});
