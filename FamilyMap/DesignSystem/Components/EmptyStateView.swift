import SwiftUI

struct EmptyStateView: View {
    /// SF Symbol name; not shown when `showsMascot` is true.
    let systemImage: String
    let title: String
    var message: String? = nil
    /// The Pinny mascot at 60 × 72 pt instead of the symbol, only where DESIGN-SPEC §0 allows it.
    var showsMascot = false

    var body: some View {
        VStack(spacing: FMSpacing.md) {
            if showsMascot {
                Image("PinnyMascot")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 60, height: 72)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 40))
                    .foregroundColor(Color.fm.textSecondary)
            }
            Text(title)
                .font(.headline)
                .foregroundColor(Color.fm.textPrimary)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(Color.fm.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(FMSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
