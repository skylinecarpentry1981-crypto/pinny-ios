import Foundation
import FirebaseFirestore

/// Firestore: users/{uid}
struct AppUser: Codable, Identifiable {
    @DocumentID var id: String?
    var name: String
    var photoURL: String?
    var familyId: String?
    var lastLocation: LocationPoint?
    /// The push token is not here: it lives in owner-only pushTokens/{uid} (family can read users docs).
    var notifyOnCheckIn: Bool
    @ServerTimestamp var updatedAt: Date?

    init(
        id: String? = nil,
        name: String,
        photoURL: String? = nil,
        familyId: String? = nil,
        lastLocation: LocationPoint? = nil,
        notifyOnCheckIn: Bool = true
    ) {
        self.id = id
        self.name = name
        self.photoURL = photoURL
        self.familyId = familyId
        self.lastLocation = lastLocation
        self.notifyOnCheckIn = notifyOnCheckIn
    }
}

extension AppUser {
    /// First word of the display name ("Jinho Kim" -> "Jinho"); used for map pin labels.
    var firstName: String {
        name.split(separator: " ").first.map(String.init) ?? name
    }
}
