import Foundation
import FirebaseFirestore

/// Firestore: families/{familyId}
struct Family: Codable, Identifiable {
    @DocumentID var id: String?
    var name: String
    var inviteCode: String
    var members: [String]
    var createdBy: String
    @ServerTimestamp var createdAt: Date?

    init(
        id: String? = nil,
        name: String,
        inviteCode: String,
        members: [String] = [],
        createdBy: String,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.inviteCode = inviteCode
        self.members = members
        self.createdBy = createdBy
        self.createdAt = createdAt
    }
}
