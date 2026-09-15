import SwiftUI

/// Map SOS (DESIGN-SPEC 11.3): 64 pt red circle, or the 44 pt capsule shown in the full drawer header.
/// Tapping only opens the confirmation sheet; sending happens there.
struct SOSButton: View {
    enum Style {
        case circle
        case headerCapsule
    }

    var style: Style = .circle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            switch style {
            case .circle:
                Text("SOS")
                    .font(.headline.bold())
                    .foregroundColor(.white)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Color.fm.sosRed))
                    .shadow(color: Color.black.opacity(0.2), radius: 4, x: 0, y: 2)
            case .headerCapsule:
                Text("SOS")
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, FMSpacing.lg)
                    .frame(minHeight: FMSize.minTapTarget)
                    .background(Capsule().fill(Color.fm.sosRed))
            }
        }
        .accessibilityLabel("SOS")
        .accessibilityHint("Opens confirmation to alert your family")
    }
}
