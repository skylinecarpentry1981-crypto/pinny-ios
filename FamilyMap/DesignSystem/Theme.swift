import SwiftUI
import UIKit

extension Color {
    /// Pinny colour tokens (DESIGN-SPEC §5). Usage: `Color.fm.accent`.
    enum fm {
        static let accent = Color.accentColor
        /// Text and icons on an `accent` fill (white in light mode, black in dark).
        static let onAccent = Color("OnAccent")
        /// Fills only: SOS button, SOS card, error banner tint.
        static let sosRed = Color("SOSRed")
        /// Red text and small red glyphs only (low battery, destructive rows, failures).
        static let sosRedText = Color("SOSRedText")
        static let background = Color(uiColor: .systemBackground)
        static let surface = Color(uiColor: .secondarySystemBackground)
        static let textPrimary = Color.primary
        static let textSecondary = Color.secondary
        static let stale = Color(uiColor: .systemGray3)
    }
}

enum FMSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum FMRadius {
    static let small: CGFloat = 8
    static let card: CGFloat = 16
    static let pill: CGFloat = 28
}

enum FMSize {
    static let minTapTarget: CGFloat = 44
    static let buttonHeight: CGFloat = 50
    static let sosHeight: CGFloat = 56
}
