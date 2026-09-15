import SwiftUI

/// A saved place on the Map tab (DESIGN-SPEC 12.3): icon in a rounded square with the name underneath.
/// Drawn below member pins, no shadow (it sits on the ground), and not tappable in Stage 3.6: no hit
/// testing, so taps reach any pin underneath. VoiceOver: "Place, Home".
struct PlaceAnnotationView: View {
    let place: Place

    private static let size: CGFloat = 28
    private static let cornerRadius: CGFloat = 8

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: place.icon.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color.fm.accent)
                .frame(width: Self.size, height: Self.size)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                            .fill(.regularMaterial)
                        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                            .fill(Color.fm.accent.opacity(0.2))
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .stroke(Color.white, lineWidth: 1)
                )
            Text(place.name)
                .font(.caption2)
                .foregroundColor(Color.fm.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .frame(maxWidth: 80)
                .background(.thinMaterial, in: Capsule())
                .fixedSize(horizontal: false, vertical: true)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Place, \(place.name)")
        .accessibilityAddTraits(.isStaticText)
    }
}
