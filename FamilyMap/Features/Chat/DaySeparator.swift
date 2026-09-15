import SwiftUI

/// Centred day label between messages (DESIGN-SPEC §13.4). Header trait for VoiceOver.
struct DaySeparator: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption)
            .foregroundColor(Color.fm.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.top, FMSpacing.lg)
            .padding(.bottom, FMSpacing.xs)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Chat time strings (DESIGN-SPEC §13.3, §13.4). English (en-AU) names whatever the device language.
enum ChatTime {
    private static let locale = Locale(identifier: "en_AU")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = format
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return formatter
    }

    private static let clockFormatter = formatter("h:mm a")
    private static let weekdayFormatter = formatter("EEEE")
    private static let dayFormatter = formatter("EEE d MMM")
    private static let dayYearFormatter = formatter("EEE d MMM yyyy")

    /// "3:41 pm".
    static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    /// Under the last bubble of a group: "Just now", "12 min ago", then "3:41 pm".
    static func label(for date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        if seconds < 60 * 60 { return "\(Int(seconds / 60)) min ago" }
        return clock(date)
    }

    /// "Today", "Yesterday", "Monday" within 7 days, else "Mon 14 Sep" (year added if not this year).
    static func day(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        if days < 7 { return weekdayFormatter.string(from: date) }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return (sameYear ? dayFormatter : dayYearFormatter).string(from: date)
    }
}
