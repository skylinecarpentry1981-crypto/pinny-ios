import SwiftUI

struct PrimaryButton: View {
    enum Style {
        case filled
        case bordered
    }

    let title: String
    var isLoading: Bool = false
    var style: Style = .filled
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title)
                    .opacity(isLoading ? 0 : 1)
                if isLoading {
                    ProgressView()
                        .tint(style == .filled ? Color.fm.onAccent : Color.fm.accent)
                }
            }
            .font(.headline)
            // onAccent, not white: white on the dark-mode teal fails contrast (DESIGN-SPEC §5).
            .foregroundColor(style == .filled ? Color.fm.onAccent : Color.fm.accent)
            .frame(maxWidth: .infinity)
            .frame(height: FMSize.buttonHeight)
            .background(style == .filled ? Color.fm.accent : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: FMRadius.card)
                    .stroke(Color.fm.accent, lineWidth: style == .bordered ? 1.5 : 0)
            )
            .cornerRadius(FMRadius.card)
        }
        .disabled(isLoading)
    }
}
