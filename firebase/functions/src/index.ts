/**
 * FamilyMap — Cloud Functions
 *
 *  onLocationUpdated  users/{uid} updated      -> "checked in" push to family (opt-in, debounced, place-aware)
 *  onUserTokenWritten pushTokens/{uid} written -> delete other accounts' docs holding the same token (one phone, one account)
 *  onSOSMessage       chats/{familyId}/messages -> high-priority SOS push to whole family
 *  onFamilyUpdated    families/{id} updated    -> purge empty family (+ places, chat) / promote creator
 *  onUserDeleted      Auth user deleted        -> Firestore clean-up (backs in-app "Delete account")
 *  redeemFamilyPass   callable { jws }         -> verify the StoreKit 2 purchase, write users/{uid}.pass (pass.ts)
 *  appStoreNotifications HTTPS (Apple V2)      -> REFUND / REVOKE remove the pass (pass.ts)
 *
 * Region: keep in sync with the Firestore database location (see docs/BACKEND-SETUP.md).
 */

import { initializeApp } from "firebase-admin/app";
import { Timestamp, getFirestore } from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";
import { getStorage } from "firebase-admin/storage";
import { logger } from "firebase-functions";
import { setGlobalOptions } from "firebase-functions/v2";
import { onDocumentCreated, onDocumentUpdated, onDocumentWritten } from "firebase-functions/v2/firestore";
import * as functionsV1 from "firebase-functions/v1";
import { shouldNotifyCheckIn } from "./checkin";
import { placeFor } from "./places";
import { sosBody } from "./sos";
import { tokenChanged } from "./token";

// Stage 7 — Family Pass. Defined in pass.ts with an explicit region (module
// imports run before setGlobalOptions below).
export { appStoreNotifications, redeemFamilyPass } from "./pass";

const REGION = "australia-southeast1";

initializeApp();
setGlobalOptions({ region: REGION, maxInstances: 10 });

const db = getFirestore();
const messaging = getMessaging();

// ---------------------------------------------------------------------------
// Types (mirror docs/BACKEND-SETUP.md schema)
// ---------------------------------------------------------------------------

interface LastLocation {
  lat: number;
  lng: number;
  updatedAt: Timestamp;
  acc?: number; // horizontal accuracy, whole metres (int)
  battery?: number; // 0-100
  charging?: boolean;
  src?: "open" | "manual" | "sos"; // absent on legacy writes
}

interface UserDoc {
  name: string;
  photoURL?: string | null;
  familyId?: string | null;
  lastLocation?: LastLocation | null;
  notifyOnCheckIn: boolean;
  updatedAt: Timestamp;
  /** Stage 7 — server-only (pass.ts). Present = may create a family. */
  pass?: { transactionId: string; productId: string; verifiedAt: Timestamp };
}

/** pushTokens/{uid} — owner-only, so family members can't read the token. */
interface PushTokenDoc {
  token: string;
  updatedAt: Timestamp;
}

interface FamilyDoc {
  name: string;
  inviteCode: string;
  members: string[];
  createdBy: string;
  createdAt: Timestamp;
}

interface PlaceDoc {
  name: string;
  icon: "home" | "school" | "work" | "pin";
  lat: number;
  lng: number;
  radius: number; // metres, int 100-500
  createdBy: string;
  createdAt: Timestamp;
}

interface MessageDoc {
  senderId: string;
  senderName: string;
  text: string;
  type: "normal" | "sos";
  createdAt: Timestamp;
}

interface Recipient {
  uid: string;
  token: string;
}

interface PushContent {
  title: string;
  body: string;
  data: Record<string, string>;
  /** SOS pushes are delivered at APNs priority 10 + time-sensitive. */
  urgent?: boolean;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Family members (other than `excludeUid`, passing `filter`) that have a
 * push token: the members come from users (familyId ==), their tokens from
 * pushTokens/{uid} in one getAll.
 */
async function familyRecipients(
  familyId: string,
  excludeUid: string,
  filter: (u: UserDoc) => boolean = () => true,
): Promise<Recipient[]> {
  const snap = await db.collection("users").where("familyId", "==", familyId).get();
  const uids = snap.docs
    .filter((d) => d.id !== excludeUid && filter(d.data() as UserDoc))
    .map((d) => d.id);
  if (uids.length === 0) return []; // getAll needs at least one ref

  const tokens = await db.getAll(...uids.map((u) => db.doc(`pushTokens/${u}`)));
  const out: Recipient[] = [];
  for (const t of tokens) {
    const token = (t.data() as PushTokenDoc | undefined)?.token;
    if (token) out.push({ uid: t.id, token });
  }
  return out;
}

/** Multicast a push and delete the pushTokens docs APNs/FCM report as dead. */
async function sendToTokens(recipients: Recipient[], content: PushContent): Promise<void> {
  if (recipients.length === 0) return;

  const res = await messaging.sendEachForMulticast({
    tokens: recipients.map((r) => r.token),
    notification: { title: content.title, body: content.body },
    data: content.data,
    apns: {
      headers: { "apns-priority": content.urgent ? "10" : "5" },
      payload: {
        aps: {
          sound: "default",
          ...(content.urgent ? { "interruption-level": "time-sensitive" } : {}),
        },
      },
    },
  });

  const dead: Recipient[] = [];
  res.responses.forEach((r, i) => {
    if (r.success) return;
    const code = r.error?.code ?? "";
    if (
      code === "messaging/registration-token-not-registered" ||
      code === "messaging/invalid-registration-token"
    ) {
      dead.push(recipients[i]);
    } else {
      logger.warn("push failed", { uid: recipients[i].uid, code });
    }
  });

  if (dead.length > 0) {
    const batch = db.batch();
    for (const r of dead) {
      batch.delete(db.doc(`pushTokens/${r.uid}`));
    }
    await batch.commit();
    logger.info("removed dead fcm tokens", { count: dead.length });
  }

  logger.info("push sent", { success: res.successCount, failure: res.failureCount });
}

/**
 * Delete a family that has no members left: the family doc, its invite code,
 * its saved places and every chat message. Idempotent — re-checks inside a
 * transaction so a concurrent join or a duplicate trigger delivery cannot
 * purge a live family. If the family doc is already gone, places and chat are
 * still swept, so a previous run that committed but failed during
 * recursiveDelete cannot orphan them.
 * Returns true when the family doc was deleted by this call.
 */
async function purgeFamily(familyId: string, inviteCode: string): Promise<boolean> {
  const famRef = db.doc(`families/${familyId}`);
  const outcome = await db.runTransaction(async (tx): Promise<"purged" | "gone" | "live"> => {
    const snap = await tx.get(famRef);
    if (!snap.exists) return "gone"; // purged earlier — still sweep the chat
    if ((snap.data() as FamilyDoc).members.length > 0) return "live"; // someone joined
    tx.delete(famRef);
    tx.delete(db.doc(`inviteCodes/${inviteCode}`));
    return "purged";
  });
  if (outcome === "live") return false;

  // Chat messages can exceed the 500-op transaction limit, so they (and the
  // places subcollection, which deleting the family doc does not remove) are
  // deleted afterwards in batches via recursiveDelete (BulkWriter).
  // No-op when already empty. Rules deny place writes once the family doc is
  // gone, so nothing can be re-added mid-sweep.
  await Promise.all([
    db.recursiveDelete(db.collection(`families/${familyId}/places`)),
    db.recursiveDelete(db.doc(`chats/${familyId}`)),
  ]);
  logger.info("family purged", { familyId, outcome });
  return outcome === "purged";
}

// ---------------------------------------------------------------------------
// onLocationUpdated — optional "check-in" notification
// Fires on every users/{uid} update; shouldNotifyCheckIn (checkin.ts) drops
// non-location writes, SOS shares (src "sos"), users without a family and
// shares within 10 min. The body names the saved place the member is inside
// (placeFor in places.ts, contract §4).
// ---------------------------------------------------------------------------

export const onLocationUpdated = onDocumentUpdated("users/{uid}", async (event) => {
  const before = event.data?.before.data() as UserDoc | undefined;
  const after = event.data?.after.data() as UserDoc | undefined;
  if (!after || !shouldNotifyCheckIn(before, after)) return;

  const familyId = after.familyId as string; // non-null: checked by shouldNotifyCheckIn
  const recipients = await familyRecipients(
    familyId,
    event.params.uid,
    (u) => u.notifyOnCheckIn === true,
  );
  if (recipients.length === 0) return; // skip the places read

  // Oldest first, like the app, so an exact distance tie picks the same place.
  const placesSnap = await db.collection(`families/${familyId}/places`).orderBy("createdAt").get();
  const place = placeFor(
    after.lastLocation as LastLocation, // non-null: checked by shouldNotifyCheckIn
    placesSnap.docs.map((d) => d.data() as PlaceDoc),
  );

  await sendToTokens(recipients, {
    title: `${after.name} checked in`,
    body: place ? `At ${place.name}.` : "Tap to see where they are.",
    data: { type: "checkin", uid: event.params.uid, familyId },
  });
});

// ---------------------------------------------------------------------------
// onUserTokenWritten — one phone, one account
// An FCM token belongs to one app install. If someone signed out offline, the
// delete never reached the server, so their pushTokens doc still holds this
// phone's token. When the next account on the phone saves it, delete every
// other account's doc with that token, so the old family's pushes stop
// reaching this phone.
// Loop-safe: tokenChanged (token.ts) ignores deletes, which is all this
// function writes.
// ---------------------------------------------------------------------------

export const onUserTokenWritten = onDocumentWritten("pushTokens/{uid}", async (event) => {
  const before = event.data?.before.data() as PushTokenDoc | undefined;
  const after = event.data?.after.data() as PushTokenDoc | undefined;
  if (!tokenChanged(before, after)) return;

  const token = after?.token as string; // non-empty: checked by tokenChanged
  const snap = await db.collection("pushTokens").where("token", "==", token).get();
  const stale = snap.docs.filter((d) => d.id !== event.params.uid);
  if (stale.length === 0) return;

  const batch = db.batch();
  for (const d of stale) batch.delete(d.ref);
  await batch.commit();
  logger.info("removed push token from other accounts", { uid: event.params.uid, count: stale.length });
});

// ---------------------------------------------------------------------------
// onSOSMessage — mandatory SOS broadcast (DESIGN-SPEC §13.3)
// Body from sosBody (sos.ts): "Tap to see where they are." only when the
// sender's lastLocation is a fresh SOS share. Normal chat messages return
// early: chat sends no pushes (§13.5).
// ---------------------------------------------------------------------------

export const onSOSMessage = onDocumentCreated(
  "chats/{familyId}/messages/{messageId}",
  async (event) => {
    const msg = event.data?.data() as MessageDoc | undefined;
    if (!msg || msg.type !== "sos") return;

    const { familyId } = event.params;
    const senderSnap = await db.doc(`users/${msg.senderId}`).get();
    const sender = senderSnap.data() as UserDoc | undefined;
    const name = sender?.name ?? msg.senderName;

    // Everyone in the family, regardless of notifyOnCheckIn.
    const recipients = await familyRecipients(familyId, msg.senderId);

    await sendToTokens(recipients, {
      title: `🚨 SOS from ${name}`,
      body: sosBody(msg, sender?.lastLocation),
      data: { type: "sos", uid: msg.senderId, familyId },
      urgent: true,
    });
  },
);

// ---------------------------------------------------------------------------
// onFamilyUpdated — housekeeping after a client-side leave
//   * members empty            -> purge the family (doc, invite code, places, chat)
//   * creator no longer member -> promote members[0] to createdBy
// Loop guard: purge deletes the doc (no further update events); promotion
// re-triggers once, then createdBy is in members and nothing happens.
// ---------------------------------------------------------------------------

export const onFamilyUpdated = onDocumentUpdated("families/{familyId}", async (event) => {
  const after = event.data?.after.data() as FamilyDoc | undefined;
  if (!after) return;
  const { familyId } = event.params;

  if (after.members.length === 0) {
    await purgeFamily(familyId, after.inviteCode);
    return;
  }

  if (!after.members.includes(after.createdBy)) {
    const createdBy = after.members[0];
    await db.doc(`families/${familyId}`).update({ createdBy });
    logger.info("family creator promoted", { familyId, createdBy });
  }
});

// ---------------------------------------------------------------------------
// onUserDeleted — clean up Firestore when an Auth account is deleted
// (1st-gen auth trigger; 2nd gen has no onDelete auth event yet.)
// ---------------------------------------------------------------------------

export const onUserDeleted = functionsV1
  .region(REGION)
  .auth.user()
  .onDelete(async (user) => {
    const uid = user.uid;
    const userRef = db.doc(`users/${uid}`);
    const userSnap = await userRef.get();
    const familyId = (userSnap.data() as UserDoc | undefined)?.familyId ?? null;

    // Remove the user from the family and delete the profile and push token atomically.
    // Returns the invite code when the family is now empty (to purge below).
    const emptyInviteCode = await db.runTransaction(async (tx): Promise<string | null> => {
      let inviteCode: string | null = null;
      if (familyId) {
        const famRef = db.doc(`families/${familyId}`);
        const famSnap = await tx.get(famRef);
        if (famSnap.exists) {
          const fam = famSnap.data() as FamilyDoc;
          const remaining = fam.members.filter((m) => m !== uid);
          // Hand ownership to the next member if the creator is leaving.
          const createdBy = fam.createdBy === uid && remaining.length > 0 ? remaining[0] : fam.createdBy;
          tx.update(famRef, { members: remaining, createdBy });
          if (remaining.length === 0) inviteCode = fam.inviteCode;
        }
      }
      tx.delete(userRef);
      tx.delete(db.doc(`pushTokens/${uid}`)); // no-op when absent
      return inviteCode;
    });

    // onFamilyUpdated will also see members == [] and call purgeFamily; the
    // helper is idempotent, so purging here just makes deletion self-contained.
    if (emptyInviteCode && familyId) {
      await purgeFamily(familyId, emptyInviteCode);
    }

    // Stage 7: release the Apple purchase bound to this account, so a restore
    // on a re-created account (same Apple ID) succeeds instead of already-exists.
    const passes = await db.collection("passes").where("uid", "==", uid).get();
    if (!passes.empty) {
      const batch = db.batch();
      for (const d of passes.docs) batch.delete(d.ref);
      await batch.commit();
    }

    // Stage 8: the profile photo, avatars/{uid}.jpg in the default bucket.
    // Best effort: the Firestore clean-up above is already committed, and the
    // bucket may not exist yet on a fresh project (BACKEND-SETUP §6.1).
    try {
      await getStorage().bucket().file(`avatars/${uid}.jpg`).delete({ ignoreNotFound: true });
    } catch (err) {
      logger.warn("onUserDeleted: could not delete profile photo", { uid, err: String(err) });
    }

    logger.info("user cleaned up", { uid, familyId, passesReleased: passes.size });
  });
