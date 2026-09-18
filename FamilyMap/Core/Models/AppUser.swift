import Foundation
import FirebaseFirestore

/// `users/{uid}.pass` — the Family Pass entitlement (STAGE-7-CONTRACT §2). Written only by the
/// `redeemFamilyPass` Cloud Function; rules deny every client write to it. Decode only.
struct PassInfo: Codable {
    var transactionId: String
    var productId: String
    @ServerTimestamp var verifiedAt: Date?
}

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
    /// Server-only (see `PassInfo`); `nil` until the server confirms a purchase.
    var pass: PassInfo?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case photoURL
        case familyId
        case lastLocation
        case notifyOnCheckIn
        case updatedAt
        case pass
    }

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

    /// Hand-written so `pass` is never sent by the client (rules would reject the whole write:
    /// `validUser` is a `hasOnly` key list). Decoding stays synthesized. `id` is a `@DocumentID`,
    /// which `Firestore.Encoder` skips anyway; `updatedAt` encodes as `FieldValue.serverTimestamp()`
    /// when nil, exactly as the synthesized encoder did.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(photoURL, forKey: .photoURL)
        try container.encodeIfPresent(familyId, forKey: .familyId)
        try container.encodeIfPresent(lastLocation, forKey: .lastLocation)
        try container.encode(notifyOnCheckIn, forKey: .notifyOnCheckIn)
        try container.encode(_updatedAt, forKey: .updatedAt)
        // `pass` deliberately omitted.
    }
}

extension AppUser {
    /// First word of the display name ("Jinho Kim" -> "Jinho"); used for map pin labels.
    var firstName: String {
        name.split(separator: " ").first.map(String.init) ?? name
    }

    /// Server-confirmed Family Pass; the only thing that gates "Create family".
    var hasPass: Bool { pass != nil }
}
