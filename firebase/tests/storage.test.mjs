// FamilyMap — Cloud Storage security rules tests (Stage 8, profile photos)
//
// Run with `npm test` (wraps `firebase emulators:exec --only firestore,storage`).
// Uses the demo project id `demo-familymap`; never touches a real project.
// Every test starts from an empty bucket (clearStorage in beforeEach).

import { after, before, beforeEach, describe, it } from "node:test";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import { deleteObject, getMetadata, ref, uploadBytes } from "firebase/storage";

const RULES = resolve(dirname(fileURLToPath(import.meta.url)), "../storage.rules");

const A = "uid_alice";
const B = "uid_bob";
const PATH_A = `avatars/${A}.jpg`;

const JPEG = { contentType: "image/jpeg" };
const small = () => new Uint8Array(1024);
const threeMB = () => new Uint8Array(3 * 1024 * 1024);

let env;
const store = (uid) => env.authenticatedContext(uid).storage();

/** Put Alice's photo in place with rules off (what a successful upload leaves behind). */
async function seedPhotoA() {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await uploadBytes(ref(ctx.storage(), PATH_A), small(), JPEG);
  });
}

before(async () => {
  env = await initializeTestEnvironment({
    projectId: "demo-familymap",
    storage: { rules: readFileSync(RULES, "utf8") },
  });
});

beforeEach(async () => {
  await env.clearStorage();
});

after(async () => {
  await env.cleanup();
});

describe("storage: avatars", () => {
  it("owner uploads own jpeg", async () => {
    await assertSucceeds(uploadBytes(ref(store(A), PATH_A), small(), JPEG));
  });

  it("owner replaces own jpeg", async () => {
    await seedPhotoA();
    await assertSucceeds(uploadBytes(ref(store(A), PATH_A), small(), JPEG));
  });

  it("another uid cannot upload my photo", async () => {
    await assertFails(uploadBytes(ref(store(B), PATH_A), small(), JPEG));
  });

  it("unauthenticated cannot upload", async () => {
    await assertFails(uploadBytes(ref(env.unauthenticatedContext().storage(), PATH_A), small(), JPEG));
  });

  it("png fails", async () => {
    await assertFails(uploadBytes(ref(store(A), PATH_A), small(), { contentType: "image/png" }));
  });

  it("3 MB fails", async () => {
    await assertFails(uploadBytes(ref(store(A), PATH_A), threeMB(), JPEG));
  });

  it("wrong file name (not <uid>.jpg) fails", async () => {
    await assertFails(uploadBytes(ref(store(A), `avatars/${A}.png`), small(), JPEG));
    await assertFails(uploadBytes(ref(store(A), `avatars/${A}/photo.jpg`), small(), JPEG));
  });

  it("path outside avatars/ fails", async () => {
    await assertFails(uploadBytes(ref(store(A), `uploads/${A}.jpg`), small(), JPEG));
  });

  it("signed-in user reads another user's photo", async () => {
    await seedPhotoA();
    await assertSucceeds(getMetadata(ref(store(B), PATH_A)));
  });

  it("unauthenticated read fails", async () => {
    await seedPhotoA();
    await assertFails(getMetadata(ref(env.unauthenticatedContext().storage(), PATH_A)));
  });

  it("owner deletes own photo", async () => {
    await seedPhotoA();
    await assertSucceeds(deleteObject(ref(store(A), PATH_A)));
  });

  it("another uid cannot delete my photo", async () => {
    await seedPhotoA();
    await assertFails(deleteObject(ref(store(B), PATH_A)));
  });
});
