import SwiftUI

/// Inline notice with an optional action, e.g. "Location is off. Open Settings".
struct InfoBanner: View {
    enum Style {
        case info
        /// Orange: something the user should fix, e.g. location off.
        case warning
        case error
    }

    let systemImage: String
    /// Optional bold first line above `message`.
    var title: String? = nil
    let message: String
    var style: Style = .info
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: FMSpacing.md) {
            Image(systemName: systemImage)
                .foregroundColor(iconColor)
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Color.fm.textPrimary)
                }
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(Color.fm.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: FMSize.minTapTarget)
            }
        }
        .padding(.horizontal, FMSpacing.lg)
        .padding(.vertical, FMSpacing.sm)
        .background(background)
        .cornerRadius(FMRadius.card)
    }

    private var iconColor: Color {
        switch style {
        case .info: return Color.fm.accent
        case .warning: return Color.orange
        // A small red glyph, so the text token (the fill below keeps sosRed).
        case .error: return Color.fm.sosRedText
        }
    }

    private var background: Color {
        switch style {
        case .info: return Color.fm.surface
        case .warning: return Color.orange.opacity(0.15)
        case .error: return Color.fm.sosRed.opacity(0.12)
        }
    }
}

/// Error variant of InfoBanner; every async action shows one of these on failure.
struct ErrorBanner: View {
    let message: String

    var body: some View {
        InfoBanner(systemImage: "exclamationmark.circle", message: message, style: .error)
    }
}
