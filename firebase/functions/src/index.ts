/**
 * FamilyMap — Cloud Functions
 *
 *  onLocationUpdated  users/{uid} updated      -> "checked in" push to family (opt-in, debounced, place-aware)
 *  onUserTokenWritten pushTokens/{uid} written -> delete other accounts' docs holding the same token (one phone, one account)
 *  onSOSMessage       chats/{familyId}/messages -> high-priority SOS push to whole family, then starts the reminders
 *  sosReminder        task queue (Stage 9)     -> re-sends the SOS push every 30 s (9x) to members who have not acked
 *  onPingCreated      families/{id}/pings created (Stage 10) -> "asking where you are" push to one member, then deletes the ping
 *  onFamilyUpdated    families/{id} updated    -> purge empty family (+ places, pings, chat) / promote creator
 *  onUserDeleted      Auth user deleted        -> Firestore clean-up (backs in-app "Delete account")
 *  redeemFamilyPass   callable { jws }         -> verify the StoreKit 2 purchase, write users/{uid}.pass (pass.ts)
 *  appStoreNotifications HTTPS (Apple V2)      -> REFUND / REVOKE remove the pass (pass.ts)
 *
 * Region: keep in sync with the Firestore database location (see docs/BACKEND-SETUP.md).
 */

import { createHash } from "node:crypto";
import { initializeApp } from "firebase-admin/app";
import { Timestamp, getFirestore } from "firebase-admin/firestore";
import { getFunctions } from "firebase-admin/functions";
import { getMessaging } from "firebase-admin/messaging";
import { getStorage } from "firebase-admin/storage";
import { logger } from "firebase-functions";
import { setGlobalOptions } from "firebase-functions/v2";
import { onDocumentCreated, onDocumentUpdated, onDocumentWritten } from "firebase-functions/v2/firestore";
import { onTaskDispatched } from "firebase-functions/v2/tasks";
import { GoogleAuth } from "google-auth-library";
import * as functionsV1 from "firebase-functions/v1";
import { shouldNotifyCheckIn } from "./checkin";
import { shouldSendPing } from "./ping";
import { placeFor } from "./places";
import { sosBody } from "./sos";
import {
  SOSReminderTask,
  SOS_REMINDER_DELAY_SECONDS,
  remainingRecipients,
  shouldContinue,
  validTask,
} from "./sosReminder";
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

/** families/{familyId}/pings/{pingId} — Stage 10, shape enforced by the rules. */
interface PingDoc {
  fromUid: string;
  fromName: string;
  toUid: string;
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
  /** `apns-priority` override; default "10" when urgent, else "5". */
  priority?: "5" | "10";
  /** `apns-collapse-id`: a later push with the same id replaces the earlier banner. */
  collapseId?: string;
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
      headers: {
        "apns-priority": content.priority ?? (content.urgent ? "10" : "5"),
        // APNs rejects a collapse id over 64 bytes, and message ids are
        // client-chosen: never let an odd id cost the SOS push itself.
        ...(content.collapseId && Buffer.byteLength(content.collapseId) <= 64
          ? { "apns-collapse-id": content.collapseId }
          : {}),
      },
      payload: {
        aps: {
          // SOS plays the bundled 29 s siren (FamilyMap/Resources/sos.wav); everything else the default sound.
          sound: content.urgent
            ? process.env.CRITICAL_ALERTS_ENABLED === "true"
              ? { critical: true, name: "sos.wav", volume: 1.0 } // needs Apple's Critical Alerts entitlement
              : "sos.wav"
            : "default",
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
 * its saved places, pings (+ pingState) and every chat message. Idempotent — re-checks inside a
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
    db.recursiveDelete(db.collection(`families/${familyId}/pings`)),
    db.recursiveDelete(db.collection(`families/${familyId}/pingState`)),
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

    const { familyId, messageId } = event.params;
    const senderSnap = await db.doc(`users/${msg.senderId}`).get();
    const sender = senderSnap.data() as UserDoc | undefined;

    // Everyone in the family, regardless of notifyOnCheckIn.
    const recipients = await familyRecipients(familyId, msg.senderId);

    try {
      await sendToTokens(recipients, sosContent(familyId, messageId, msg, sender));
    } catch (err) {
      // A failed first push must not cancel the reminders: they are the second chance.
      logger.warn("first sos push failed", { familyId, messageId, err: String(err) });
    }

    // Stage 9: keep alerting until each receiver acknowledges.
    if (shouldContinue(0, recipients.length)) {
      await enqueueSOSReminder({ familyId, messageId, senderUid: msg.senderId, attempt: 1 });
    }
  },
);

/** The SOS push — identical for the first send and every reminder. */
function sosContent(
  familyId: string,
  messageId: string,
  msg: MessageDoc,
  sender: UserDoc | undefined,
): PushContent {
  return {
    title: `🚨 SOS from ${sender?.name ?? msg.senderName}`,
    body: sosBody(msg, sender?.lastLocation),
    data: { type: "sos", uid: msg.senderId, familyId, messageId },
    urgent: true,
    collapseId: messageId, // reminders replace the earlier banner instead of stacking
  };
}

// ---------------------------------------------------------------------------
// sosReminder — SOS keeps alerting until acknowledged (Stage 9)
// A Cloud Tasks queue function. onSOSMessage enqueues attempt 1 for 30 s
// later; each run re-sends the SOS push to the members who have no ack doc
// (chats/{familyId}/messages/{messageId}/acks/{uid}) and enqueues the next,
// up to attempt 9 (about 5 minutes). The chain stops early when the message
// is gone (family purged) or nobody un-acknowledged with a push token is left.
// No Cloud Tasks retries (maxAttempts 1): the next reminder is 30 s away.
// ---------------------------------------------------------------------------

const SOS_REMINDER_QUEUE = `locations/${REGION}/functions/sosReminder`;

let googleAuth: GoogleAuth | undefined;
let sosReminderUri: string | undefined;

/**
 * Cloud Run URL of the 2nd-gen sosReminder function. The Admin SDK would
 * target https://{region}-{project}.cloudfunctions.net/{name} by default, so
 * the documented way for 2nd gen is to look the URL up and pass it as `uri`
 * (firebase.google.com/docs/functions/task-functions). Cached per instance.
 */
async function sosReminderUrl(): Promise<string> {
  if (sosReminderUri) return sosReminderUri;
  googleAuth ??= new GoogleAuth({ scopes: "https://www.googleapis.com/auth/cloud-platform" });
  const projectId = await googleAuth.getProjectId();
  const url =
    "https://cloudfunctions.googleapis.com/v2beta/" +
    `projects/${projectId}/locations/${REGION}/functions/sosReminder`;
  const client = await googleAuth.getClient();
  const res = await client.request<{ serviceConfig?: { uri?: string } }>({ url });
  const uri = res.data?.serviceConfig?.uri;
  if (!uri) throw new Error(`no uri for function at ${url}`);
  sosReminderUri = uri;
  return uri;
}

/**
 * Enqueue one reminder, 30 s from now. Never throws: a queue problem (API not
 * enabled, missing IAM role, …) must not fail the push that was just sent.
 * The task id is a hash of message + attempt, so a duplicate trigger delivery
 * cannot start a second reminder chain for the same SOS.
 */
async function enqueueSOSReminder(task: SOSReminderTask): Promise<void> {
  try {
    let uri: string | undefined;
    if (process.env.FUNCTIONS_EMULATOR !== "true") {
      try {
        uri = await sosReminderUrl();
      } catch (err) {
        // Fall back to the SDK's default cloudfunctions.net URL.
        logger.warn("sosReminder: could not resolve the function url", { err: String(err) });
      }
    }
    const id = createHash("sha256")
      .update(`${task.familyId}/${task.messageId}/${task.attempt}`)
      .digest("hex");
    await getFunctions()
      .taskQueue<SOSReminderTask>(SOS_REMINDER_QUEUE)
      .enqueue(task, {
        scheduleDelaySeconds: SOS_REMINDER_DELAY_SECONDS,
        dispatchDeadlineSeconds: 60,
        id,
        ...(uri ? { uri } : {}),
      });
  } catch (err) {
    if ((err as { code?: string }).code === "functions/task-already-exists") {
      logger.info("sos reminder already enqueued", { ...task });
      return;
    }
    logger.warn("could not enqueue sos reminder", { ...task, err: String(err) });
  }
}

export const sosReminder = onTaskDispatched<SOSReminderTask>(
  {
    region: REGION,
    retryConfig: { maxAttempts: 1 },
    rateLimits: { maxConcurrentDispatches: 10, maxDispatchesPerSecond: 5 },
    timeoutSeconds: 60,
  },
  async (req) => {
    if (!validTask(req.data)) {
      logger.warn("sosReminder: bad payload", { data: req.data });
      return;
    }
    const { familyId, messageId, senderUid, attempt } = req.data;

    const msgRef = db.doc(`chats/${familyId}/messages/${messageId}`);
    let msgSnap, acksSnap, senderSnap, withToken;
    try {
      [msgSnap, acksSnap, senderSnap, withToken] = await Promise.all([
        msgRef.get(),
        msgRef.collection("acks").get(),
        db.doc(`users/${senderUid}`).get(),
        // Current members with a push token, minus the sender.
        familyRecipients(familyId, senderUid),
      ]);
    } catch (err) {
      // No task retries: a transient read failure skips this attempt but keeps the (bounded) chain alive.
      logger.warn("sos reminder read failed", { familyId, messageId, attempt, err: String(err) });
      if (shouldContinue(attempt, 1)) {
        await enqueueSOSReminder({ familyId, messageId, senderUid, attempt: attempt + 1 });
      }
      return;
    }
    const msg = msgSnap.data() as MessageDoc | undefined;
    if (!msg || msg.type !== "sos") return; // message gone (family purged): stop

    const remaining = new Set(
      remainingRecipients(withToken.map((r) => r.uid), senderUid, acksSnap.docs.map((d) => d.id)),
    );
    const recipients = withToken.filter((r) => remaining.has(r.uid));
    if (recipients.length === 0) {
      logger.info("sos reminders done: nobody left to alert", { familyId, messageId, attempt });
      return;
    }

    try {
      const sender = senderSnap.data() as UserDoc | undefined;
      await sendToTokens(recipients, sosContent(familyId, messageId, msg, sender));
    } catch (err) {
      // Keep the chain alive: there are no task retries.
      logger.warn("sos reminder push failed", { familyId, messageId, attempt, err: String(err) });
    }

    if (shouldContinue(attempt, recipients.length)) {
      await enqueueSOSReminder({ familyId, messageId, senderUid, attempt: attempt + 1 });
    }
  },
);

// ---------------------------------------------------------------------------
// onPingCreated — "Ask location" (Stage 10)
// A member asks another member where they are. One push to that member only
// (the rules already checked both are in the family and fromUid is the
// caller); tapping it opens the app, which shares once. No background
// tracking. Rate limit: one push per fromUid -> toUid pair per 60 s, kept in
// server-only families/{familyId}/pingState/{fromUid}_{toUid} = { at }; the
// transaction also makes a duplicate trigger delivery harmless. The ping doc
// is always deleted afterwards, so who-asked-whom is stored for seconds only.
// ---------------------------------------------------------------------------

export const onPingCreated = onDocumentCreated(
  "families/{familyId}/pings/{pingId}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const ping = snap.data() as PingDoc;
    const { familyId } = event.params;

    try {
      const stateRef = db.doc(`families/${familyId}/pingState/${ping.fromUid}_${ping.toUid}`);
      const send = await db.runTransaction(async (tx) => {
        const last = (await tx.get(stateRef)).data()?.at as Timestamp | undefined;
        const now = Timestamp.now();
        if (!shouldSendPing(last?.toMillis(), now.toMillis())) return false;
        tx.set(stateRef, { at: now });
        return true;
      });
      if (!send) {
        logger.info("ping rate-limited", { familyId, fromUid: ping.fromUid, toUid: ping.toUid });
        return;
      }

      const tokenSnap = await db.doc(`pushTokens/${ping.toUid}`).get();
      const token = (tokenSnap.data() as PushTokenDoc | undefined)?.token;
      if (!token) return; // recipient has notifications off / signed out

      await sendToTokens([{ uid: ping.toUid, token }], {
        title: `${ping.fromName} is asking where you are`,
        body: "Tap to share your location.",
        data: { type: "ping", uid: ping.fromUid, familyId },
        priority: "10", // deliver now, but default sound and no time-sensitive level
      });
    } finally {
      await snap.ref.delete();
    }
  },
);

// ---------------------------------------------------------------------------
// onFamilyUpdated — housekeeping after a client-side leave
//   * members empty            -> purge the family (doc, invite code, places, pings, chat)
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
