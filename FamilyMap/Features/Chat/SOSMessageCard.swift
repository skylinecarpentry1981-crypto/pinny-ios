import SwiftUI

/// System card for a `type == "sos"` message (DESIGN-SPEC §13.3). Never grouped into a bubble run.
struct SOSMessageCard: View {
    /// `senderName`, or "You" for my own SOS.
    let name: String
    let isMine: Bool
    /// "3:41 pm"; the day comes from the separator.
    let time: String
    /// False when the sender has no location or has left the family: the button hides, the card stays.
    let canShowOnMap: Bool
    let onShowOnMap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: FMSpacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: FMSpacing.md) {
                Image(systemName: "sos")
                    .font(.system(size: 24, weight: .semibold))
                Text("\(name) sent an SOS · \(time)")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("SOS. \(name) sent an SOS at \(time)")

            if canShowOnMap {
                Button(action: onShowOnMap) {
                    Text("Show on map")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: FMSize.minTapTarget)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white, lineWidth: 1.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isMine ? "Show me on map" : "Show \(name) on map")
            }
        }
        .foregroundColor(.white)
        .padding(FMSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.fm.sosRed)
        )
        .padding(.top, FMSpacing.md)
    }
}
