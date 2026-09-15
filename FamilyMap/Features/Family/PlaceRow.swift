import SwiftUI

/// Family tab → Places (DESIGN-SPEC 12.1): icon circle, name, radius, chevron. Tap to edit.
struct PlaceRow: View {
    let place: Place
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: FMSpacing.md) {
                Image(systemName: place.icon.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color.fm.accent)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.fm.accent.opacity(0.15)))
                Text(place.name)
                    .font(.body)
                    .foregroundColor(Color.fm.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: FMSpacing.sm)
                Text(place.radiusText)
                    .font(.subheadline)
                    .foregroundColor(Color.fm.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Color(uiColor: .tertiaryLabel))
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(place.name), radius \(place.radiusSpoken)")
        .accessibilityHint("Double-tap to edit")
        .accessibilityAddTraits(.isButton)
    }
}

/// "Add place" row; hidden by the Family tab at 10 places.
struct AddPlaceRow: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: FMSpacing.md) {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .frame(width: 32, height: 32)
                Text("Add place")
                    .font(.body)
            }
            .foregroundColor(Color.fm.accent)
            .frame(minHeight: FMSize.minTapTarget)
            .contentShape(Rectangle())
        }
    }
}

/// One skeleton row until the first `places` snapshot arrives.
struct PlaceSkeletonRow: View {
    var body: some View {
        HStack(spacing: FMSpacing.md) {
            Circle()
                .fill(Color(uiColor: .secondarySystemFill))
                .frame(width: 32, height: 32)
            Capsule()
                .fill(Color(uiColor: .secondarySystemFill))
                .frame(width: 120, height: 12)
        }
        .frame(minHeight: 52)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading places")
    }
}
