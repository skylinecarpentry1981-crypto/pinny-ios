import Foundation
import FirebaseAuth
import FirebaseFirestore

enum ChatError: LocalizedError {
    /// Empty after trimming, or over 1000 characters.
    case invalidMessage
    /// A write that hasn't committed after 10 s. A commit already in flight may still land; nothing
    /// is queued, so it is never replayed later.
    case timedOut

    var errorDescription: String? {
        AppError.generic
    }
}

/// One update from the live message window.
enum ChatFeedEvent {
    /// The newest messages, oldest first. `isFull`: the window hit `ChatLimits.pageSize`, so older
    /// messages may exist.
    case messages([ChatMessage], isFull: Bool)
    case failure(Error)
}

/// One family thread: chats/{familyId}/messages.
protocol ChatService: AnyObject {
    /// Live window of the newest `ChatLimits.pageSize` messages, including our own pending writes.
    func observeRecentMessages(familyId: String, onEvent: @escaping (ChatFeedEvent) -> Void) -> ListenerCancel
    /// The `ChatLimits.pageSize` messages before `message`, oldest first. A one-off server read.
    func loadEarlier(familyId: String, before message: ChatMessage) async throws -> [ChatMessage]
    /// A fresh document ID, made before the first write so a retry can't post twice.
    func newMessageId(familyId: String) -> String
    /// Creates a normal message. Succeeds if `messageId` already exists (an earlier attempt landed).
    func send(text: String, familyId: String, sender: AppUser, messageId: String) async throws
    /// Creates the SOS message (§13.3). Succeeds if `messageId` already exists, so the SOS flow's
    /// Try again can reuse the ID: one SOS, never two.
    func sendSOS(familyId: String, sender: AppUser, messageId: String) async throws
    /// Stage 9: writes my ack for an SOS message so the server stops repeating the alert to me.
    /// Best effort: an ack that already exists counts as done, and a failure is only logged.
    func acknowledgeSOS(familyId: String, messageId: String) async
    /// Stage 9: acknowledges every SOS from someone else in the newest 20 messages that is younger
    /// than `ChatMessage.sosAckWindow`. One query; best effort like `acknowledgeSOS`.
    func acknowledgeRecentSOS(familyId: String) async
}

/// Firestore implementation. Creates match the messages rules exactly: five keys, `senderId` = my uid,
/// `createdAt` a server timestamp. Every create is a write-only transaction, so nothing ever sits in
/// Firestore's offline queue: a failed send is never replayed later, and only Retry / Try again resends.
final class FirestoreChatService: ChatService {
    /// Computed so `Firestore.firestore()` is never called before `FirebaseApp.configure()`.
    private var db: Firestore { Firestore.firestore() }

    private func messages(_ familyId: String) -> CollectionReference {
        db.collection("chats").document(familyId).collection("messages")
    }

    /// Acks written (or found already written) this session, as "uid/messageId", so the app-active
    /// check and the chat listener don't repeat the write. Locked: callers run on any executor.
    private var ackedKeys: Set<String> = []
    private let ackedLock = NSLock()

    private func newestFirst(_ familyId: String) -> Query {
        messages(familyId).order(by: "createdAt", descending: true)
    }

    func observeRecentMessages(familyId: String, onEvent: @escaping (ChatFeedEvent) -> Void) -> ListenerCancel {
        // Metadata changes too, so a pending write flips to sent when the server confirms it.
        let registration = newestFirst(familyId)
            .limit(to: ChatLimits.pageSize)
            .addSnapshotListener(includeMetadataChanges: true) { snapshot, error in
                guard let snapshot else {
                    if let error {
                        onEvent(.failure(error))
                    }
                    return
                }
                let newest = snapshot.documents.compactMap(ChatMessage.init(document:))
                onEvent(.messages(
                    Array(newest.reversed()),
                    isFull: snapshot.documents.count >= ChatLimits.pageSize
                ))
            }
        return { registration.remove() }
    }

    func loadEarlier(familyId: String, before message: ChatMessage) async throws -> [ChatMessage] {
        let anchorRef = messages(familyId).document(message.id)
        do {
            // The listener has already cached the anchor; fall back to the server if it hasn't.
            let anchor: DocumentSnapshot
            if let cached = try? await anchorRef.getDocument(source: .cache), cached.exists {
                anchor = cached
            } else {
                anchor = try await anchorRef.getDocument()
            }
            let snapshot = try await newestFirst(familyId)
                .start(afterDocument: anchor)
                .limit(to: ChatLimits.pageSize)
                .getDocuments(source: .server)
            return Array(snapshot.documents.compactMap(ChatMessage.init(document:)).reversed())
        } catch {
            throw FamilyError.from(error)
        }
    }

    func newMessageId(familyId: String) -> String {
        messages(familyId).document().documentID
    }

    func send(text: String, familyId: String, sender: AppUser, messageId: String) async throws {
        guard let text = ChatLimits.validText(text) else { throw ChatError.invalidMessage }
        try await create(messageId: messageId, familyId: familyId, sender: sender, text: text, type: .normal)
    }

    func sendSOS(familyId: String, sender: AppUser, messageId: String) async throws {
        try await create(messageId: messageId, familyId: familyId, sender: sender, text: ChatMessage.sosText, type: .sos)
    }

    private func create(
        messageId: String,
        familyId: String,
        sender: AppUser,
        text: String,
        type: MessageType
    ) async throws {
        guard let uid = sender.id else { throw FamilyError.notSignedIn }
        let ref = messages(familyId).document(messageId)
        let fields: [String: Any] = [
            "senderId": uid,
            "senderName": ChatLimits.storedName(sender.name),
            "text": text,
            "type": type.rawValue,
            "createdAt": FieldValue.serverTimestamp()
        ]
        do {
            // A transaction, not `setData`: it fails when the connection is gone and is never queued,
            // so an SOS that showed "Couldn't send" can't reach the family hours later (same pattern
            // as `FamilyService.updateLocation`).
            _ = try await db.runTransaction { transaction, _ in
                transaction.setData(fields, forDocument: ref)
                return nil
            }
        } catch {
            // A retry after an earlier attempt landed is an update, which the rules refuse.
            // The message is there, so this send succeeded.
            if let existing = try? await ref.getDocument(source: .server), existing.exists {
                return
            }
            throw FamilyError.from(error)
        }
    }

    // MARK: - SOS acknowledgement (Stage 9)

    func acknowledgeSOS(familyId: String, messageId: String) async {
        guard let uid = Auth.auth().currentUser?.uid, !familyId.isEmpty, !messageId.isEmpty else { return }
        let key = "\(uid)/\(messageId)"
        guard markAcked(key) else { return }
        let ref = messages(familyId).document(messageId).collection("acks").document(uid)
        let fields: [String: Any] = ["at": FieldValue.serverTimestamp()]
        do {
            // Write-only transaction, like `create`: never queued offline.
            _ = try await db.runTransaction { transaction, _ in
                transaction.setData(fields, forDocument: ref)
                return nil
            }
        } catch {
            // Writing over an ack that is already there is an update, which the rules refuse.
            // The ack exists, so this is done.
            if let existing = try? await ref.getDocument(source: .server), existing.exists {
                return
            }
            unmarkAcked(key)
            print("SOS ack failed: \(error.localizedDescription)")
        }
    }

    func acknowledgeRecentSOS(familyId: String) async {
        guard let uid = Auth.auth().currentUser?.uid, !familyId.isEmpty else { return }
        do {
            let snapshot = try await newestFirst(familyId).limit(to: 20).getDocuments()
            let now = Date()
            for message in snapshot.documents.compactMap(ChatMessage.init(document:))
            where message.needsSOSAck(myUid: uid, now: now) {
                await acknowledgeSOS(familyId: familyId, messageId: message.id)
            }
        } catch {
            print("SOS ack check failed: \(error.localizedDescription)")
        }
    }

    /// False when this ack was already written (or is being written) this session.
    private func markAcked(_ key: String) -> Bool {
        ackedLock.lock()
        defer { ackedLock.unlock() }
        return ackedKeys.insert(key).inserted
    }

    private func unmarkAcked(_ key: String) {
        ackedLock.lock()
        defer { ackedLock.unlock() }
        ackedKeys.remove(key)
    }
}
