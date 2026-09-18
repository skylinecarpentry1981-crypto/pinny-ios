import SwiftUI

/// One member in the Map drawer (DESIGN-SPEC 11.4): avatar, name, place line, time line, battery.
/// Tapping selects the member; the selected row expands inline with its actions.
struct DrawerMemberRow: View {
    let member: AppUser
    let isMe: Bool
    let place: PlaceNameResolver.PlaceName
    let isExpanded: Bool
    /// Disables Check in while any share is in flight.
    let isSharing: Bool
    /// Stage 10: true while an ask is in flight and for 60 s after a successful one.
    let isAskDisabled: Bool
    let onTap: () -> Void
    let onOpenInMaps: () -> Void
    let onAskLocation: () -> Void
    let onMessage: () -> Void
    let onCheckIn: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var point: LocationPoint? { member.lastLocation }
    /// Other members without a location are greyed and offer Ask location and Message.
    private var isGreyed: Bool { !isMe && point == nil }
    private var name: String { isMe ? "You" : member.name }
    private var askLabel: String { "Ask \(member.firstName) for their location" }

    private var ringColor: Color {
        guard let point else { return .clear }
        if point.isStale { return Color.fm.stale }
        return isMe ? Color.fm.accent : Color.white
    }

    /// "Mum, near George St Parramatta, updated 12 min ago, battery 40 percent, charging".
    private var accessibilityText: String {
        guard let point else { return "\(name), no location yet" }
        var parts = [name, place.spoken]
        parts.append("\(point.isStale ? "last seen" : "updated") \(point.displayDate.relativePhrase)")
        if let battery = point.battery {
            parts.append("battery \(battery) percent")
            if point.charging == true { parts.append("charging") }
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onTap) {
                summary
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(point == nil ? "Double-tap to show actions" : "Double-tap to show on map")
            .modifier(RowAccessibilityActions(
                isMe: isMe,
                isLocated: point != nil,
                askLabel: isAskDisabled ? nil : askLabel,
                onOpenInMaps: onOpenInMaps,
                onAskLocation: onAskLocation,
                onMessage: onMessage,
                onCheckIn: onCheckIn
            ))

            if isExpanded {
                actions
                    .padding(.leading, 72)
                    .padding(.trailing, FMSpacing.lg)
                    .padding(.bottom, FMSpacing.sm)
                    .transition(.opacity)
            }
        }
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: FMSpacing.lg) {
            AvatarView(name: member.name, photoURL: member.photoURL, size: 40)
                .padding(2)
                .background(Circle().fill(ringColor))
                .opacity(point?.isStale == true ? 0.5 : 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: FMSpacing.sm)
                    if let point, let battery = point.battery {
                        BatteryIndicator(level: battery, charging: point.charging == true)
                    }
                }
                Text(place.display)
                    .font(.footnote)
                    .foregroundColor(Color.fm.textSecondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                if let point {
                    Text(point.statusText)
                        .font(.caption)
                        .foregroundColor(Color.fm.textSecondary)
                }
            }
        }
        .padding(.horizontal, FMSpacing.lg)
        .padding(.vertical, FMSpacing.md)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .opacity(isGreyed ? 0.5 : 1)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var actions: some View {
        if isMe {
            Button("Check in", action: onCheckIn)
                .buttonStyle(.bordered)
                .frame(minHeight: FMSize.minTapTarget)
                .disabled(isSharing)
        } else {
            // Titles when the row is wide enough for them; icon-only otherwise (small phones, large text).
            ViewThatFits(in: .horizontal) {
                otherMemberActions(iconOnly: false)
                otherMemberActions(iconOnly: true)
            }
        }
    }

    /// Open in Maps (located members only) · Ask location · Message.
    private func otherMemberActions(iconOnly: Bool) -> some View {
        HStack(spacing: FMSpacing.sm) {
            if point != nil {
                actionButton("Open in Maps", systemImage: "map", iconOnly: iconOnly, action: onOpenInMaps)
            }
            actionButton(
                "Ask location",
                systemImage: "location.magnifyingglass",
                iconOnly: iconOnly,
                titleWithIcon: true,
                action: onAskLocation
            )
                .disabled(isAskDisabled)
                .accessibilityLabel(askLabel)
            actionButton("Message", systemImage: "message", iconOnly: iconOnly, action: onMessage)
        }
    }

    /// Icon-only buttons keep their title as the VoiceOver label (`Label` does that by itself).
    /// With titles, only Ask location carries its symbol; the two older buttons look as before.
    private func actionButton(
        _ title: String,
        systemImage: String,
        iconOnly: Bool,
        titleWithIcon: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if iconOnly {
                Label(title, systemImage: systemImage)
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 28)
            } else if titleWithIcon {
                Label(title, systemImage: systemImage)
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Text(title)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .buttonStyle(.bordered)
        .frame(minHeight: FMSize.minTapTarget)
    }
}

/// The expanded actions, also offered as VoiceOver custom actions on the row.
private struct RowAccessibilityActions: ViewModifier {
    let isMe: Bool
    let isLocated: Bool
    /// "Ask {firstName} for their location"; nil while Ask location is disabled (no action offered).
    let askLabel: String?
    let onOpenInMaps: () -> Void
    let onAskLocation: () -> Void
    let onMessage: () -> Void
    let onCheckIn: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isMe {
            content.accessibilityAction(named: "Check in", onCheckIn)
        } else {
            content
                .modifier(OptionalAccessibilityAction(name: isLocated ? "Open in Maps" : nil, action: onOpenInMaps))
                .modifier(OptionalAccessibilityAction(name: askLabel, action: onAskLocation))
                .accessibilityAction(named: "Message", onMessage)
        }
    }
}

/// Adds a named VoiceOver action only when `name` is set.
private struct OptionalAccessibilityAction: ViewModifier {
    let name: String?
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if let name {
            content.accessibilityAction(named: name, action)
        } else {
            content
        }
    }
}

/// Battery captured at share time: SF battery symbol + "40%", red at 15 % or below, bolt when charging.
struct BatteryIndicator: View {
    let level: Int
    let charging: Bool

    private var symbol: String {
        if charging { return "battery.100.bolt" }
        switch level {
        case 88...: return "battery.100"
        case 63..<88: return "battery.75"
        case 38..<63: return "battery.50"
        case 13..<38: return "battery.25"
        default: return "battery.0"
        }
    }

    private var tint: Color {
        level <= 15 ? Color.fm.sosRedText : Color.fm.textSecondary
    }

    var body: some View {
        HStack(spacing: FMSpacing.xs) {
            Image(systemName: symbol)
            Text("\(level)%")
                .font(.caption.monospacedDigit())
        }
        .font(.caption)
        .foregroundColor(tint)
        .accessibilityHidden(true)
    }
}

/// Only-me family (DESIGN-SPEC 11.5): shown under my row.
struct InviteRow: View {
    let inviteCode: String

    var body: some View {
        HStack(spacing: FMSpacing.lg) {
            Image(systemName: "person.badge.plus")
                .foregroundColor(Color.fm.accent)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color(uiColor: .secondarySystemFill)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Invite your family")
                    .font(.body.weight(.semibold))
                Text("It's just you for now.")
                    .font(.footnote)
                    .foregroundColor(Color.fm.textSecondary)
            }
            Spacer(minLength: FMSpacing.sm)
            ShareLink(item: InviteCodeCard.shareText(for: inviteCode)) {
                Text("Share")
                    .frame(minHeight: FMSize.minTapTarget)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Share invite code")
        }
        .padding(.horizontal, FMSpacing.lg)
        .padding(.vertical, FMSpacing.md)
        .frame(minHeight: 64)
    }
}
