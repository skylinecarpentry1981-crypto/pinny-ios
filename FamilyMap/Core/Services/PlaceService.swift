import Foundation
import FirebaseAuth
import FirebaseFirestore

/// DESIGN-SPEC §12 strings. Shown only through `error.userMessage`.
enum PlaceError: LocalizedError {
    case saveFailed
    case deleteFailed
    case searchFailed
    case invalidName
    case limitReached
    case network

    var errorDescription: String? {
        switch self {
        case .saveFailed: return "Couldn't save the place. Try again."
        case .deleteFailed: return "Couldn't delete the place. Try again."
        case .searchFailed: return "Search didn't work. Try again."
        case .invalidName: return "Give the place a name (1–30 characters)."
        case .limitReached: return "Your family has 10 places. Delete one first."
        case .network: return AppError.offline
        }
    }

    /// Offline / unavailable -> `.network`; anything else -> `fallback`.
    static func from(_ error: Error, fallback: PlaceError) -> PlaceError {
        if let placeError = error as? PlaceError { return placeError }
        if case .network = FamilyError.from(error) { return .network }
        return fallback
    }
}

/// Family Places: families/{familyId}/places. Any member may read, add, edit and delete.
protocol PlaceService: AnyObject {
    func observePlaces(familyId: String, onChange: @escaping ([Place]) -> Void) -> ListenerCancel
    /// A fresh document ID, made once per editor session so a retried save can't create a second place.
    func newPlaceId(familyId: String) -> String
    /// Creates the place at `placeId`. Succeeds if that place already exists (an earlier attempt landed).
    func addPlace(familyId: String, placeId: String, draft: PlaceDraft) async throws
    func updatePlace(familyId: String, placeId: String, draft: PlaceDraft) async throws
    func deletePlace(familyId: String, placeId: String) async throws
}

/// Firestore implementation. Writes match the places rules exactly: create sends every field with
/// `createdAt` as a server timestamp; update sends only name, icon, lat, lng and radius.
final class FirebasePlaceService: PlaceService {
    /// Computed so `Firestore.firestore()` is never called before `FirebaseApp.configure()`.
    private var db: Firestore { Firestore.firestore() }

    private func places(_ familyId: String) -> CollectionReference {
        db.collection("families").document(familyId).collection("places")
    }

    /// Oldest first (a place being created, with no server time yet, goes last), then by name.
    func observePlaces(familyId: String, onChange: @escaping ([Place]) -> Void) -> ListenerCancel {
        let registration = places(familyId).addSnapshotListener { snapshot, _ in
            guard let snapshot else {
                onChange([])
                return
            }
            let decoded = snapshot.documents.compactMap { try? $0.data(as: Place.self) }
            onChange(decoded.sorted { lhs, rhs in
                let left = lhs.createdAt ?? .distantFuture
                let right = rhs.createdAt ?? .distantFuture
                return left != right ? left < right : lhs.name < rhs.name
            })
        }
        return { registration.remove() }
    }

    func newPlaceId(familyId: String) -> String {
        places(familyId).document().documentID
    }

    func addPlace(familyId: String, placeId: String, draft: PlaceDraft) async throws {
        guard let uid = Auth.auth().currentUser?.uid else { throw PlaceError.saveFailed }
        let ref = places(familyId).document(placeId)
        do {
            try await ref.setData([
                "name": draft.name,
                "icon": draft.icon.rawValue,
                "lat": draft.coordinate.latitude,
                "lng": draft.coordinate.longitude,
                "radius": draft.radius,
                "createdBy": uid,
                "createdAt": FieldValue.serverTimestamp()
            ])
        } catch {
            // A retry after a timed-out save that landed re-sets `createdAt`, which the rules refuse
            // (permission denied). The place is there, so this save succeeded.
            if Self.isPermissionDenied(error),
               let existing = try? await ref.getDocument(source: .server), existing.exists {
                return
            }
            throw PlaceError.from(error, fallback: .saveFailed)
        }
    }

    func updatePlace(familyId: String, placeId: String, draft: PlaceDraft) async throws {
        do {
            try await places(familyId).document(placeId).updateData([
                "name": draft.name,
                "icon": draft.icon.rawValue,
                "lat": draft.coordinate.latitude,
                "lng": draft.coordinate.longitude,
                "radius": draft.radius
            ])
        } catch {
            throw PlaceError.from(error, fallback: .saveFailed)
        }
    }

    func deletePlace(familyId: String, placeId: String) async throws {
        do {
            try await places(familyId).document(placeId).delete()
        } catch {
            throw PlaceError.from(error, fallback: .deleteFailed)
        }
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == FirestoreErrorDomain
            && nsError.code == FirestoreErrorCode.permissionDenied.rawValue
    }
}
