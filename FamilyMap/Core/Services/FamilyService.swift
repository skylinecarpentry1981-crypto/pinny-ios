import Foundation
import CoreLocation
import FirebaseAuth
import FirebaseFirestore

/// Call to stop a Firestore listener.
typealias ListenerCancel = () -> Void

/// Strings are the DESIGN-SPEC §9.1 table, verbatim.
enum FamilyError: LocalizedError {
    case invalidCode
    case notSignedIn
    case network
    case unknown

    var errorDescription: String? {
        switch self {
        case .invalidCode: return "Code not found. Check it and try again."
        case .notSignedIn: return AppError.generic
        case .network: return AppError.offline
        case .unknown: return AppError.generic
        }
    }

    static func from(_ error: Error) -> FamilyError {
        if let familyError = error as? FamilyError { return familyError }
        if AppError.isOffline(error) { return .network }
        let nsError = error as NSError
        if nsError.domain == FirestoreErrorDomain, nsError.code == FirestoreErrorCode.unavailable.rawValue {
            return .network
        }
        return .unknown
    }
}

/// Stage 10: an Ask location that failed for a reason other than being offline.
struct AskLocationError: LocalizedError {
    let firstName: String

    var errorDescription: String? { AppError.askFailed(firstName) }
}

/// What triggered a share, written as `lastLocation.src` so the server never sends a check-in push
/// for an SOS (STAGE-3.6-CONTRACT §3, §5).
enum LocationSource: String {
    /// Automatic share on app open / foreground. Throttled to one per 2 min.
    case open
    /// Refresh or Check in.
    case manual
    /// Stage 4 SOS.
    case sos
}

/// Everything captured for one share. Battery and accuracy are sampled at share time only.
struct LocationShare {
    let source: LocationSource
    let coordinate: CLLocationCoordinate2D
    /// Metres, 0...100000. Nil when Core Location reports an invalid (negative) accuracy.
    let accuracy: Int?
    /// 0...100. Nil when the level is unknown.
    let battery: Int?
    /// Nil when the battery state is unknown.
    let charging: Bool?
}

/// One event from the `users/{uid}` listener.
enum UserSnapshotEvent {
    /// `nil` user means the document does not exist (yet). `isFromCache` is true until the server
    /// has confirmed the snapshot.
    case user(AppUser?, hasPendingWrites: Bool, isFromCache: Bool)
    case failure(Error)
}

protocol FamilyService: AnyObject {
    func observeUser(id: String, onChange: @escaping (UserSnapshotEvent) -> Void) -> ListenerCancel
    func createUser(_ user: AppUser) async throws
    func updateName(userId: String, name: String) async throws
    /// Settings › Check-in alerts. Affects check-in pushes only; SOS always sends.
    func updateNotifyOnCheckIn(userId: String, enabled: Bool) async throws
    /// Stage 8 profile photo. `nil` clears it (`photoURL: null`, which `validUser` accepts).
    func updatePhotoURL(userId: String, url: String?) async throws
    func createFamily(name: String) async throws -> Family
    func joinFamily(code: String) async throws -> Family
    func leaveFamily(_ family: Family) async throws
    func observeFamily(id: String, onChange: @escaping (Family?) -> Void) -> ListenerCancel
    func observeMembers(familyId: String, onChange: @escaping ([AppUser]) -> Void) -> ListenerCancel
    /// Overwrites `users/{userId}.lastLocation` (latest only, no history) with a server timestamp.
    func updateLocation(userId: String, share: LocationShare) async throws
    /// Stage 10 Ask location: creates `families/{familyId}/pings/{pingId}`; the server pushes `toUid`
    /// and deletes the doc. `fromName` is my display name (clamped to 40 UTF-16 units here).
    func askLocation(familyId: String, to toUid: String, fromName: String) async throws
}

/// Firestore implementation. Every write matches the shapes in `firebase/firestore.rules`.
final class FirebaseFamilyService: FamilyService {
    /// Computed so `Firestore.firestore()` is never called before `FirebaseApp.configure()`.
    private var db: Firestore { Firestore.firestore() }
    private let maxCreateAttempts = 3

    private var users: CollectionReference { db.collection("users") }
    private var families: CollectionReference { db.collection("families") }
    private var inviteCodes: CollectionReference { db.collection("inviteCodes") }

    private func requireUid() throws -> String {
        guard let uid = Auth.auth().currentUser?.uid else { throw FamilyError.notSignedIn }
        return uid
    }

    // MARK: - users/{uid}

    func observeUser(id: String, onChange: @escaping (UserSnapshotEvent) -> Void) -> ListenerCancel {
        // includeMetadataChanges so the caller sees the snapshot again once a local write is acknowledged.
        let registration = users.document(id).addSnapshotListener(includeMetadataChanges: true) { snapshot, error in
            if let error {
                onChange(.failure(error))
                return
            }
            guard let snapshot else { return }
            let pending = snapshot.metadata.hasPendingWrites
            let fromCache = snapshot.metadata.isFromCache
            guard snapshot.exists else {
                // A cache miss is not proof the doc is absent; wait for the server before creating it.
                if !fromCache {
                    onChange(.user(nil, hasPendingWrites: pending, isFromCache: fromCache))
                }
                return
            }
            do {
                let user = try snapshot.data(as: AppUser.self)
                onChange(.user(user, hasPendingWrites: pending, isFromCache: fromCache))
            } catch {
                onChange(.failure(error))
            }
        }
        return { registration.remove() }
    }

    /// Creates `users/{uid}` with exactly the keys `validUser()` accepts. Nil optionals are omitted
    /// by `Firestore.Encoder`; `@ServerTimestamp updatedAt` becomes `FieldValue.serverTimestamp()`.
    func createUser(_ user: AppUser) async throws {
        let uid = try requireUid()
        do {
            let data = try Firestore.Encoder().encode(user)
            try await users.document(uid).setData(data)
        } catch {
            throw FamilyError.from(error)
        }
    }

    func updateName(userId: String, name: String) async throws {
        do {
            try await users.document(userId).updateData([
                "name": name,
                "updatedAt": FieldValue.serverTimestamp()
            ])
        } catch {
            throw FamilyError.from(error)
        }
    }

    /// A write-only transaction, like `updateLocation`: a save that failed or timed out is never
    /// replayed later, so the toggle that flipped back stays true.
    func updateNotifyOnCheckIn(userId: String, enabled: Bool) async throws {
        let fields: [String: Any] = [
            "notifyOnCheckIn": enabled,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        let userRef = users.document(userId)
        do {
            _ = try await db.runTransaction { transaction, _ in
                transaction.updateData(fields, forDocument: userRef)
                return nil
            }
        } catch {
            throw FamilyError.from(error)
        }
    }

    func updatePhotoURL(userId: String, url: String?) async throws {
        do {
            try await users.document(userId).updateData([
                "photoURL": url.map { $0 as Any } ?? NSNull(),
                "updatedAt": FieldValue.serverTimestamp()
            ])
        } catch {
            throw FamilyError.from(error)
        }
    }

    // MARK: - Family

    func createFamily(name: String) async throws -> Family {
        let uid = try requireUid()
        var lastError: Error?
        for _ in 0..<maxCreateAttempts {
            let code = InviteCode.generate()
            let familyRef = families.document()
            let batch = db.batch()
            batch.setData([
                "name": name,
                "inviteCode": code,
                "members": [uid],
                "createdBy": uid,
                "createdAt": FieldValue.serverTimestamp()
            ], forDocument: familyRef)
            batch.setData(["familyId": familyRef.documentID], forDocument: inviteCodes.document(code))
            batch.setData([
                "familyId": familyRef.documentID,
                "updatedAt": FieldValue.serverTimestamp()
            ], forDocument: users.document(uid), merge: true)
            do {
                try await batch.commit()
                return Family(id: familyRef.documentID, name: name, inviteCode: code, members: [uid], createdBy: uid)
            } catch {
                lastError = error
                // Permission denied is how the rules report an invite-code collision: regenerate and retry.
                guard Self.isPermissionDenied(error) else { throw FamilyError.from(error) }
            }
        }
        throw FamilyError.from(lastError ?? FamilyError.unknown)
    }

    func joinFamily(code rawCode: String) async throws -> Family {
        let uid = try requireUid()
        let code = InviteCode.normalize(rawCode)
        guard InviteCode.isValid(code) else { throw FamilyError.invalidCode }
        do {
            let codeSnapshot = try await inviteCodes.document(code).getDocument()
            guard codeSnapshot.exists, let familyId = codeSnapshot.get("familyId") as? String else {
                throw FamilyError.invalidCode
            }
            let batch = db.batch()
            batch.updateData(["members": FieldValue.arrayUnion([uid])], forDocument: families.document(familyId))
            batch.setData([
                "familyId": familyId,
                "updatedAt": FieldValue.serverTimestamp()
            ], forDocument: users.document(uid), merge: true)
            try await batch.commit()

            let familySnapshot = try await families.document(familyId).getDocument()
            return try familySnapshot.data(as: Family.self)
        } catch {
            throw FamilyError.from(error)
        }
    }

    func leaveFamily(_ family: Family) async throws {
        let uid = try requireUid()
        guard let familyId = family.id else { throw FamilyError.unknown }
        do {
            let batch = db.batch()
            batch.updateData(["members": FieldValue.arrayRemove([uid])], forDocument: families.document(familyId))
            // Rules accept `familyId == null`; keep the key so the doc shape matches BACKEND-SETUP §7.
            batch.updateData([
                "familyId": NSNull(),
                "updatedAt": FieldValue.serverTimestamp()
            ], forDocument: users.document(uid))
            try await batch.commit()
        } catch {
            throw FamilyError.from(error)
        }
    }

    func observeFamily(id: String, onChange: @escaping (Family?) -> Void) -> ListenerCancel {
        let registration = families.document(id).addSnapshotListener { snapshot, _ in
            guard let snapshot, snapshot.exists, let family = try? snapshot.data(as: Family.self) else {
                onChange(nil)
                return
            }
            onChange(family)
        }
        return { registration.remove() }
    }

    func observeMembers(familyId: String, onChange: @escaping ([AppUser]) -> Void) -> ListenerCancel {
        // The equality filter on familyId is what makes the users list rule provable.
        let registration = users
            .whereField("familyId", isEqualTo: familyId)
            .addSnapshotListener { snapshot, _ in
                guard let snapshot else {
                    onChange([])
                    return
                }
                onChange(snapshot.documents.compactMap { try? $0.data(as: AppUser.self) })
            }
        return { registration.remove() }
    }

    /// Matches `validLocation()`: { lat, lng, updatedAt, src, acc?, battery?, charging? }, both
    /// timestamps server-set, unknown fields omitted (never null). Replaces the whole `lastLocation`
    /// map, so no stray keys or history survive.
    ///
    /// Written as a write-only transaction, not `updateData`: a transaction fails while offline and is
    /// never replayed, whereas a plain write is queued and sent on reconnect, where the server would
    /// stamp an old position as fresh.
    func updateLocation(userId: String, share: LocationShare) async throws {
        var lastLocation: [String: Any] = [
            "lat": share.coordinate.latitude,
            "lng": share.coordinate.longitude,
            "updatedAt": FieldValue.serverTimestamp(),
            "src": share.source.rawValue
        ]
        if let accuracy = share.accuracy { lastLocation["acc"] = accuracy }
        if let battery = share.battery { lastLocation["battery"] = battery }
        if let charging = share.charging { lastLocation["charging"] = charging }
        let fields: [String: Any] = [
            "lastLocation": lastLocation,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        let userRef = users.document(userId)
        do {
            _ = try await db.runTransaction { transaction, _ in
                transaction.updateData(fields, forDocument: userRef)
                return nil
            }
        } catch {
            throw FamilyError.from(error)
        }
    }

    /// Matches the `pings` create rule: exactly { fromUid, fromName, toUid, createdAt }, `createdAt`
    /// server-set. A write-only transaction, like `updateLocation`: it fails while offline and is never
    /// replayed, so nobody is asked minutes later on reconnect.
    func askLocation(familyId: String, to toUid: String, fromName: String) async throws {
        let uid = try requireUid()
        let trimmed = fromName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields: [String: Any] = [
            "fromUid": uid,
            "fromName": (trimmed.isEmpty ? "Family member" : trimmed).clamped(toUTF16: 40),
            "toUid": toUid,
            "createdAt": FieldValue.serverTimestamp()
        ]
        let pingRef = families.document(familyId).collection("pings").document()
        do {
            _ = try await db.runTransaction { transaction, _ in
                transaction.setData(fields, forDocument: pingRef)
                return nil
            }
        } catch {
            throw FamilyError.from(error)
        }
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == FirestoreErrorDomain
            && nsError.code == FirestoreErrorCode.permissionDenied.rawValue
    }
}
