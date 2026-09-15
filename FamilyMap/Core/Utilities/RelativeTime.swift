import Foundation

/// DESIGN-SPEC §8: one relative-time function, used everywhere.
extension Date {
    private static let dayMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter
    }()

    private static let dayMonthYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()

    /// Mid-sentence form used after "Updated " / "Last seen ": "just now", "yesterday", "12 min ago".
    var relativePhrase: String {
        relative(capitalised: false)
    }

    func isStale(olderThan interval: TimeInterval = 24 * 60 * 60) -> Bool {
        Date().timeIntervalSince(self) > interval
    }

    private func relative(capitalised: Bool) -> String {
        let now = Date()
        let seconds = now.timeIntervalSince(self)
        if seconds < 60 { return capitalised ? "Just now" : "just now" }

        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min ago" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours) h ago" }

        let calendar = Calendar.current
        if calendar.isDateInYesterday(self) { return capitalised ? "Yesterday" : "yesterday" }

        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: self),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        if days < 7 { return "\(max(days, 2)) days ago" }

        let sameYear = calendar.component(.year, from: self) == calendar.component(.year, from: now)
        return (sameYear ? Self.dayMonthFormatter : Self.dayMonthYearFormatter).string(from: self)
    }
}
