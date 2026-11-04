import Foundation

/// The past time windows of "last week", "yesterday", "three days ago". Pure.
enum RioFindTime {
    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    /// The first time phrase in `text` (already lowercase), as a window, and the text without it.
    static func extract(from text: String, now: Date, calendar: Calendar) -> (interval: DateInterval, remainder: String)? {
        let startOfToday = calendar.startOfDay(for: now)
        func interval(_ start: Date, _ end: Date) -> DateInterval { DateInterval(start: start, end: max(end, start)) }
        func days(_ count: Int, from date: Date) -> Date { calendar.date(byAdding: .day, value: count, to: date) ?? date }

        let fixed: [(String, () -> DateInterval)] = [
            (#"\b(?:earlier\s+)?today\b|\bthis\s+morning\b|\bthis\s+afternoon\b|\btonight\b"#, { interval(startOfToday, now) }),
            (#"\byesterday\b|\blast\s+night\b"#, { interval(days(-1, from: startOfToday), startOfToday) }),
            (#"\bthis\s+week\b"#, { interval(calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday, now) }),
            (#"\b(?:last|past|previous)\s+week\b"#, {
                let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday
                return interval(days(-7, from: thisWeek), now)
            }),
            (#"\b(?:a|one)\s+week\s+ago\b"#, { interval(days(-10, from: startOfToday), days(-4, from: startOfToday)) }),
            (#"\bthis\s+month\b"#, { interval(calendar.dateInterval(of: .month, for: now)?.start ?? startOfToday, now) }),
            (#"\b(?:last|past|previous)\s+month\b"#, {
                let thisMonth = calendar.dateInterval(of: .month, for: now)?.start ?? startOfToday
                return interval(calendar.date(byAdding: .month, value: -1, to: thisMonth) ?? thisMonth, now)
            }),
            (#"\brecently\b|\blately\b"#, { interval(days(-14, from: startOfToday), now) }),
        ]
        for (pattern, make) in fixed {
            if let groups = RioText.firstMatch(pattern, in: text), let whole = groups[0] {
                return (make(), remove(whole, from: text))
            }
        }

        // "in the last three days", "past 2 weeks".
        if let groups = RioText.firstMatch(#"\b(?:in\s+the\s+)?(?:last|past)\s+(\w+)\s+(hours?|days?|weeks?|months?)\b"#, in: text),
           let whole = groups[0], let word = groups[1], let unit = groups[2], let count = RioText.number(from: word), count > 0 {
            let component: Calendar.Component = unit.hasPrefix("hour") ? .hour : unit.hasPrefix("day") ? .day : unit.hasPrefix("week") ? .weekOfYear : .month
            let start = calendar.date(byAdding: component, value: -count, to: now) ?? now
            return (interval(start, now), remove(whole, from: text))
        }

        // "three days ago": that day, with a day of slack either side for weeks and months.
        if let groups = RioText.firstMatch(#"\b(\w+)\s+(days?|weeks?|months?)\s+ago\b"#, in: text),
           let whole = groups[0], let word = groups[1], let unit = groups[2], let count = RioText.number(from: word), count > 0 {
            let component: Calendar.Component = unit.hasPrefix("day") ? .day : unit.hasPrefix("week") ? .weekOfYear : .month
            let center = calendar.date(byAdding: component, value: -count, to: startOfToday) ?? startOfToday
            let slack = unit.hasPrefix("day") ? 0 : unit.hasPrefix("week") ? 3 : 10
            return (interval(days(-slack, from: center), days(slack + 1, from: center)), remove(whole, from: text))
        }

        // "on monday", "last friday": the most recent one before today.
        let names = weekdays.joined(separator: "|")
        if let groups = RioText.firstMatch(#"\b(?:(?:on|last)\s+)?(\#(names))\b"#, in: text), let whole = groups[0], let name = groups[1],
           let index = weekdays.firstIndex(of: name.lowercased()) {
            let today = calendar.component(.weekday, from: startOfToday) - 1
            let back = (today - index + 7) % 7
            let day = days(-(back == 0 ? 7 : back), from: startOfToday)
            return (interval(day, days(1, from: day)), remove(whole, from: text))
        }
        return nil
    }

    private static func remove(_ phrase: String, from text: String) -> String {
        guard let range = text.range(of: phrase, options: .caseInsensitive) else { return text }
        return RioText.collapseWhitespace(text.replacingCharacters(in: range, with: " "))
    }
}
