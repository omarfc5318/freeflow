import Foundation

struct RioParsedSchedule: Equatable {
    let recurrence: RioRecurrence
    let hour: Int
    let minute: Int
    let firstFire: Date
}

/// "every weekday at 8:30 am", "in 20 minutes", "at 5 pm" to a schedule. Builds on
/// `RioDateTimeParser` for the clock; `now` and the calendar (time zone) are injected. Answers nil
/// when it is not sure, so the handler can ask for a clearer time instead of guessing.
enum RioScheduleParser {
    private static let weekdayNames = ["sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
                                       "thursday": 5, "friday": 6, "saturday": 7]

    static func parse(_ when: String, now: Date, calendar: Calendar) -> RioParsedSchedule? {
        var text = when.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
        text = RioText.replacing(#"\b([ap])\.\s?m\.?"#, with: "$1m", in: text)
        text = RioText.collapseWhitespace(text.trimmingCharacters(in: CharacterSet(charactersIn: " .!?,;:")))

        guard let (recurrence, rest) = extractRecurrence(text) else {
            guard let result = RioDateTimeParser.parse(text, now: now, calendar: calendar),
                  result.remainder.isEmpty, result.start > now else { return nil }
            let parts = calendar.dateComponents([.hour, .minute], from: result.start)
            return RioParsedSchedule(recurrence: .once, hour: parts.hour ?? 0, minute: parts.minute ?? 0, firstFire: result.start)
        }
        // A recurrence needs a clock time of its own: "every day" alone is not enough.
        guard let result = RioDateTimeParser.parse(rest, now: now, calendar: calendar), result.remainder.isEmpty else { return nil }
        let parts = calendar.dateComponents([.hour, .minute], from: result.start)
        guard let hour = parts.hour, let minute = parts.minute,
              let first = RioScheduleMath.nextFire(after: now, recurrence: recurrence, hour: hour, minute: minute, calendar: calendar)
        else { return nil }
        return RioParsedSchedule(recurrence: recurrence, hour: hour, minute: minute, firstFire: first)
    }

    private static func extractRecurrence(_ text: String) -> (RioRecurrence, String)? {
        let days = weekdayNames.keys.joined(separator: "|")
        if let groups = RioText.firstMatch(#"\b(?:weekly\s+on|on\s+every|every|each)\s+(\#(days))s?\b"#, in: text),
           let name = groups[1], let weekday = weekdayNames[name] {
            return (.weekly(weekday: weekday), remove(#"\b(?:weekly\s+on|on\s+every|every|each)\s+(?:\#(days))s?\b"#, from: text))
        }
        if RioText.matches(#"\b(?:every|each|on)\s+week\s?days?\b|\bweek\s?days\b"#, text) {
            return (.weekdays, remove(#"\b(?:(?:every|each|on)\s+)?week\s?days?\b"#, from: text))
        }
        if let groups = RioText.firstMatch(#"\bevery\s+(morning|afternoon|evening|night)\b"#, in: text), let part = groups[1] {
            let phrase = part == "night" ? "at night" : "in the \(part)"
            return (.daily, RioText.replacing(#"\bevery\s+(?:morning|afternoon|evening|night)\b"#, with: phrase, in: text))
        }
        if RioText.matches(#"\b(?:every\s?day|each\s+day|daily)\b"#, text) {
            return (.daily, remove(#"\b(?:every\s?day|each\s+day|daily)\b"#, from: text))
        }
        return nil
    }

    private static func remove(_ pattern: String, from text: String) -> String {
        RioText.collapseWhitespace(RioText.replacing(pattern, with: " ", in: text))
    }
}

/// When a schedule runs next, and what to do when the Mac was asleep at that moment. Pure.
enum RioScheduleMath {
    /// A run this late (the Mac slept through it) still goes ahead; later than this is skipped.
    static let catchUpWindow: TimeInterval = 30 * 60
    /// Within this of its time, a run is on time rather than "late".
    static let lateTolerance: TimeInterval = 30

    enum Verdict: Equatable {
        case notDue
        case fire(late: Bool)
        case skipped
    }

    struct Resolution: Equatable {
        let verdict: Verdict
        /// The schedule to keep, with its next run set. Nil: a one-off that has run or been missed.
        let updated: RioScheduledCommand?
    }

    static func nextFire(after date: Date, recurrence: RioRecurrence, hour: Int, minute: Int, calendar: Calendar) -> Date? {
        switch recurrence {
        case .once:
            return nil
        case .daily:
            return nextClock(after: date, hour: hour, minute: minute, weekday: nil, calendar: calendar)
        case .weekly(let weekday):
            return nextClock(after: date, hour: hour, minute: minute, weekday: weekday, calendar: calendar)
        case .weekdays:
            var cursor = date
            for _ in 0..<8 {
                guard let candidate = nextClock(after: cursor, hour: hour, minute: minute, weekday: nil, calendar: calendar) else { return nil }
                if (2...6).contains(calendar.component(.weekday, from: candidate)) { return candidate }
                cursor = candidate
            }
            return nil
        }
    }

    private static func nextClock(after date: Date, hour: Int, minute: Int, weekday: Int?, calendar: Calendar) -> Date? {
        var parts = DateComponents(hour: hour, minute: minute, second: 0)
        parts.weekday = weekday
        guard var candidate = calendar.nextDate(after: date, matching: parts, matchingPolicy: .nextTime) else { return nil }
        // The hour that repeats when the clocks go back must not fire twice: if the match is the
        // same wall-clock time on the same day as `date`, move on to the next day.
        if calendar.isDate(candidate, inSameDayAs: date) {
            let clock = calendar.dateComponents([.hour, .minute], from: date)
            if clock.hour == hour && clock.minute == minute,
               let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)),
               let later = calendar.nextDate(after: tomorrow.addingTimeInterval(-1), matching: parts, matchingPolicy: .nextTime) {
                candidate = later
            }
        }
        return candidate
    }

    static func resolve(_ item: RioScheduledCommand, now: Date, calendar: Calendar) -> Resolution {
        guard item.nextFire <= now else { return Resolution(verdict: .notDue, updated: item) }
        let lateness = now.timeIntervalSince(item.nextFire)
        let verdict: Verdict = lateness <= catchUpWindow ? .fire(late: lateness > lateTolerance) : .skipped
        guard item.recurrence != .once else { return Resolution(verdict: verdict, updated: nil) }
        var next = item
        next.nextFire = nextFire(after: now, recurrence: item.recurrence, hour: item.hour, minute: item.minute, calendar: calendar)
            ?? now.addingTimeInterval(24 * 3600)
        return Resolution(verdict: verdict, updated: next)
    }
}
