import Foundation

enum InviteCode {
    static let length = 6

    /// Uppercase alphanumerics without the look-alikes 0, O, 1, I.
    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    static func generate() -> String {
        String((0..<length).compactMap { _ in alphabet.randomElement() })
    }

    /// Uppercases and strips whitespace so pasted codes match.
    static func normalize(_ raw: String) -> String {
        raw.uppercased().filter { !$0.isWhitespace }
    }

    static func isValid(_ code: String) -> Bool {
        code.count == length && code.allSatisfy { alphabet.contains($0) }
    }
}
