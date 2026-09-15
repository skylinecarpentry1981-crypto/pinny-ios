import Foundation

/// Firestore rules measure strings with `size()`, which counts UTF-16 code units: an emoji counts 2
/// or more (🏠 = 2, 👨‍👩‍👧 = 8), a Korean syllable 1. Name limits are checked with `utf16.count` so
/// a name that passes here also passes the rules.
extension String {
    /// Drops trailing characters until the string fits `limit` UTF-16 units. Never splits a character.
    func clamped(toUTF16 limit: Int) -> String {
        var result = self
        while result.utf16.count > limit {
            result.removeLast()
        }
        return result
    }
}
