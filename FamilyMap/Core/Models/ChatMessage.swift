import Foundation
import FirebaseFirestore

enum MessageType: String {
    case normal
    case sos
}

/// Firestore: chats/{familyId}/messages/{messageId}. Immutable once written (rules: no update/delete).
/// Parsed by hand rather than Codable so a pending server timestamp can use the local estimate.
struct ChatMessage: Identifiable, Equatable {
    let id: String
    let senderId: String
    let senderName: String
    let text: String
    let type: MessageType
    /// Server time; the local estimate while our own write is still pending.
    let createdAt: Date
    /// Our own write that the server hasn't confirmed yet (`hasPendingWrites`).
    var isPending: Bool

    /// Stored text of every SOS message (DESIGN-SPEC §13.3). Fixed and never shown.
    static let sosText = "SOS"

    init(
        id: String,
        senderId: String,
        senderName: String,
        text: String,
        type: MessageType = .normal,
        createdAt: Date,
        isPending: Bool = false
    ) {
        self.id = id
        self.senderId = senderId
        self.senderName = senderName
        self.text = text
        self.type = type
        self.createdAt = createdAt
        self.isPending = isPending
    }

    /// Nil when a required field is missing (the rules make that impossible, but never crash on it).
    init?(document: QueryDocumentSnapshot) {
        let data = document.data(with: .estimate)
        guard
            let senderId = data["senderId"] as? String,
            let senderName = data["senderName"] as? String,
            let text = data["text"] as? String
        else { return nil }
        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
        self.init(
            id: document.documentID,
            senderId: senderId,
            senderName: senderName,
            text: text,
            type: (data["type"] as? String).flatMap(MessageType.init(rawValue:)) ?? .normal,
            createdAt: createdAt,
            isPending: document.metadata.hasPendingWrites
        )
    }

    /// Stage 9: an SOS older than this is no longer acknowledged (the server repeats for about 5 minutes).
    static let sosAckWindow: TimeInterval = 10 * 60

    /// Stage 9: an SOS from someone else, younger than `sosAckWindow`. Opening Pinny acknowledges it.
    func needsSOSAck(myUid: String, now: Date = Date()) -> Bool {
        type == .sos && senderId != myUid && now.timeIntervalSince(createdAt) < Self.sosAckWindow
    }

    /// "Mum" from "Mum Kim"; the label above a run of bubbles.
    var senderFirstName: String {
        senderName.split(separator: " ").first.map(String.init) ?? senderName
    }
}

/// Chat limits shared by the service and the input bar (DESIGN-SPEC §13.4, firestore.rules).
enum ChatLimits {
    /// Messages per listener window and per "Load earlier" page.
    static let pageSize = 100
    static let maxLength = 1000
    /// The character counter shows from here.
    static let counterThreshold = 900
    /// `senderName` must be 1–40 characters (rules `validName`).
    static let maxNameLength = 40

    /// Length as the rules count it: UTF-16 units (an emoji is 2 or more). Used for the cap, the
    /// counter and `senderName`, so nothing that passes here is refused by the server.
    static func length(_ text: String) -> Int {
        text.utf16.count
    }

    /// Cuts `text` to `limit` at a character boundary (never splits an emoji).
    static func clamp(_ text: String, to limit: Int = maxLength) -> String {
        guard length(text) > limit else { return text }
        var result = ""
        var used = 0
        for character in text {
            let size = character.utf16.count
            if used + size > limit { break }
            result.append(character)
            used += size
        }
        return result
    }

    /// Trimmed text that the rules accept, or nil.
    static func validText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, length(trimmed) <= maxLength else { return nil }
        return trimmed
    }

    /// The sender's name as stored on a message: trimmed, 1–40 characters.
    static func storedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return clamp(trimmed.isEmpty ? "Family member" : trimmed, to: maxNameLength)
    }
}
