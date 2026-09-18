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

    /// For the text field: uppercase, keep ASCII letters and digits only, cap at 6.
    static func sanitizeTyped(_ raw: String) -> String {
        String(raw.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(length))
    }

    static func isValid(_ code: String) -> Bool {
        code.count == length && code.allSatisfy { alphabet.contains($0) }
    }
}
