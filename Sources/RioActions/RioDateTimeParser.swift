import Foundation

/// Deterministic spoken date and time parsing for "add lunch with Sarah Friday at 1". Pure:
/// Foundation only, with `now` and the calendar (time zone) injected. It only answers when it
/// is sure: no clear time, or a bare hour that could be am or pm, returns nil and the request
/// is left to the smart resolver.
enum RioDateTimeParser {
    struct Result: Equatable {
        let start: Date
        let durationMinutes: Int?
        /// The text left over once the date, time and duration words are removed (the title).
        let remainder: String
    }

    static func parse(_ text: String, now: Date, calendar: Calendar) -> Result? {
        var work = normalize(text)
        let duration = extractDuration(&work)
        let dayPart = extractDayPart(&work)
        var day = extractDay(&work, now: now, calendar: calendar)
        if day == nil, let relative = extractRelativeOffset(&work, now: now) {
            return Result(start: relative, durationMinutes: duration, remainder: cleanRemainder(work))
        }
        let timeRange = extractTimeRange(&work, dayPart: dayPart)
        var time: ClockTime?
        var rangeDuration: Int?
        if let range = timeRange {
            time = range.start
            rangeDuration = range.durationMinutes
        } else {
            guard let single = extractTime(&work, dayPart: dayPart) else { return nil }
            time = single
        }
        guard let clock = time else { return nil }
        if day == nil, dayPart.isToday { day = calendar.startOfDay(for: now) }

        guard let start = resolve(day: day, clock: clock, now: now, calendar: calendar) else { return nil }
        return Result(start: start, durationMinutes: duration ?? rangeDuration, remainder: cleanRemainder(work))
    }

    // MARK: Normalising and regex helpers

    private static func normalize(_ text: String) -> String {
        var work = text
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        work = RioText.replacing(#"\b([ap])\.\s?m\.?"#, with: "$1m", in: work)
        work = RioText.replacing(#"\bo'?clock\b"#, with: "", in: work)
        return RioText.collapseWhitespace(work.trimmingCharacters(in: CharacterSet(charactersIn: " .!?,;:")))
    }

    /// Removes the first case-insensitive match and returns its capture groups.
    private static func take(_ pattern: String, from text: inout String) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let full = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: full),
              let whole = Range(match.range, in: text) else { return nil }
        let groups: [String?] = (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
            return String(text[swiftRange])
        }
        text.replaceSubrange(whole, with: " ")
        text = RioText.collapseWhitespace(text)
        return groups
    }

    private static func cleanRemainder(_ text: String) -> String {
        var result = text
        let dangling = #"(?:^|\s)(?:on|at|for|by|from|to|this|next|in|the|until|till|and)\s*$"#
        let leading = #"^\s*(?:on|at|for|by|from|to|this|in|until|till|and)\s+"#
        var changed = true
        while changed {
            changed = false
            for pattern in [dangling, leading] {
                let next = RioText.replacing(pattern, with: " ", in: result)
                if next != result { result = RioText.collapseWhitespace(next); changed = true }
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-"))
    }

    // MARK: Words to numbers

    private static func value(of word: String) -> Double? {
        let cleaned = word.lowercased().trimmingCharacters(in: .whitespaces)
        if let number = Double(cleaned) { return number }
        if cleaned == "a" || cleaned == "an" { return 1 }
        if cleaned == "a couple" || cleaned == "a couple of" || cleaned == "couple" { return 2 }
        if cleaned == "a few" { return 3 }
        return RioText.number(from: cleaned).map(Double.init)
    }

    private static let numberWord = #"(?:\d+(?:\.\d+)?|an?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty|thirty|forty|forty five|forty-five|fifty|sixty|ninety|a couple of)"#

    // MARK: Duration

    private static func extractDuration(_ work: inout String) -> Int? {
        if take(#"\bfor\s+(?:an?|one)\s+hour\s+and\s+a\s+half\b"#, from: &work) != nil { return 90 }
        if take(#"\bfor\s+half\s+(?:an?\s+)?hour\b"#, from: &work) != nil { return 30 }
        if let groups = take(#"\bfor\s+(\#(numberWord))\s+and\s+a\s+half\s+hours?\b"#, from: &work),
           let raw = groups[1], let count = value(of: raw) {
            return Int((count * 60 + 30).rounded())
        }
        if let groups = take(#"\bfor\s+(\#(numberWord))\s+(hours?|hrs?|minutes?|mins?)\b"#, from: &work),
           let raw = groups[1], let unit = groups[2]?.lowercased(), let count = value(of: raw) {
            let minutes = unit.hasPrefix("h") ? count * 60 : count
            let rounded = Int(minutes.rounded())
            return rounded > 0 && rounded <= 24 * 60 ? rounded : nil
        }
        return nil
    }

    // MARK: Part of day

    struct DayPart {
        enum Kind { case none, morning, afternoon, evening }
        var kind: Kind = .none
        var isToday = false
    }

    /// "tonight", "this evening", "tomorrow morning", "in the morning": remembered so a bare hour
    /// can be placed, and removed from the text.
    private static func extractDayPart(_ work: inout String) -> DayPart {
        var part = DayPart()
        if take(#"\btonight\b"#, from: &work) != nil {
            part.kind = .evening
            part.isToday = true
            return part
        }
        if let groups = take(#"\b(?:in the|this|at)\s+(morning|afternoon|evening|night)\b"#, from: &work) {
            part.kind = kind(of: groups[1])
            if RioText.matches(#"\bthis\b"#, groups[0] ?? "") { part.isToday = true }
            return part
        }
        if let groups = take(#"\b(?:tomorrow|today)\s+(morning|afternoon|evening|night)\b"#, from: &work) {
            part.kind = kind(of: groups[1])
            // Put the day word back: it still decides the date.
            work += RioText.matches(#"tomorrow"#, groups[0] ?? "") ? " tomorrow" : " today"
            return part
        }
        if let groups = take(#"\b(morning|afternoon|evening|night)\b"#, from: &work) {
            part.kind = kind(of: groups[1])
        }
        return part
    }

    private static func kind(of word: String?) -> DayPart.Kind {
        switch word?.lowercased() {
        case "morning": return .morning
        case "afternoon": return .afternoon
        case "evening", "night": return .evening
        default: return .none
        }
    }

    // MARK: Day

    private static let weekdays = ["sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7]
    private static let weekdayAliases = ["tues": 3, "thurs": 5]
    private static let months = [
        "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6, "july": 7, "august": 8,
        "september": 9, "october": 10, "november": 11, "december": 12,
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "sept": 9, "oct": 10, "nov": 11, "dec": 12,
    ]

    private static let monthPattern = "(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec)"

    private static func extractDay(_ work: inout String, now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        if take(#"\bthe day after tomorrow\b|\bday after tomorrow\b"#, from: &work) != nil { return add(days: 2, to: today, calendar) }
        if take(#"\btomorrow\b"#, from: &work) != nil { return add(days: 1, to: today, calendar) }
        if take(#"\btoday\b"#, from: &work) != nil { return today }

        // Numeric: 11/20 or 11/20/2026 (month first).
        if let groups = take(#"\b(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b"#, from: &work),
           let month = groups[1].flatMap(Int.init), let day = groups[2].flatMap(Int.init) {
            let year = groups[3].flatMap(Int.init).map { $0 < 100 ? 2000 + $0 : $0 }
            return calendarDate(month: month, day: day, year: year, today: today, calendar: calendar)
        }
        // "December 3rd", "Dec 3, 2026"
        if let groups = take(#"\b(?:on\s+)?\#(monthPattern)\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?\b"#, from: &work),
           let month = groups[1].flatMap({ months[$0.lowercased()] }), let day = groups[2].flatMap(Int.init) {
            return calendarDate(month: month, day: day, year: groups[3].flatMap(Int.init), today: today, calendar: calendar)
        }
        // "the 5th of March"
        if let groups = take(#"\b(?:on\s+)?(?:the\s+)?(\d{1,2})(?:st|nd|rd|th)\s+(?:of\s+)?\#(monthPattern)\b"#, from: &work),
           let day = groups[1].flatMap(Int.init), let month = groups[2].flatMap({ months[$0.lowercased()] }) {
            return calendarDate(month: month, day: day, year: nil, today: today, calendar: calendar)
        }
        // "on the 15th"
        if let groups = take(#"\b(?:on\s+)?the\s+(\d{1,2})(?:st|nd|rd|th)\b"#, from: &work), let day = groups[1].flatMap(Int.init) {
            return nextDayOfMonth(day, today: today, calendar: calendar)
        }
        // "in 2 days", "in a week"
        if let groups = take(#"\bin\s+(\#(numberWord))\s+(days?|weeks?)\b"#, from: &work),
           let raw = groups[1], let count = value(of: raw), let unit = groups[2]?.lowercased() {
            let days = Int(count) * (unit.hasPrefix("week") ? 7 : 1)
            return add(days: days, to: today, calendar)
        }
        // Weekdays, optionally "this" or "next".
        let names = (Array(weekdays.keys) + Array(weekdayAliases.keys)).sorted { $0.count > $1.count }.joined(separator: "|")
        if let groups = take(#"\b(?:on\s+)?(?:(this|next|coming)\s+)?(\#(names))\b"#, from: &work),
           let name = groups[2]?.lowercased(), let target = weekdays[name] ?? weekdayAliases[name] {
            return weekday(target, modifier: groups[1]?.lowercased(), today: today, calendar: calendar)
        }
        return nil
    }

    private static func add(days: Int, to date: Date, _ calendar: Calendar) -> Date? {
        calendar.date(byAdding: .day, value: days, to: date)
    }

    /// "Friday" is the next Friday after today; "this Friday" may be today; "next Friday" is the
    /// Friday of the following week (weeks start on the calendar's first weekday).
    private static func weekday(_ target: Int, modifier: String?, today: Date, calendar: Calendar) -> Date? {
        let current = calendar.component(.weekday, from: today)
        switch modifier {
        case "next":
            guard let week = calendar.dateInterval(of: .weekOfYear, for: today) else { return nil }
            var cursor = week.end
            for _ in 0..<7 {
                if calendar.component(.weekday, from: cursor) == target { return calendar.startOfDay(for: cursor) }
                guard let following = add(days: 1, to: cursor, calendar) else { return nil }
                cursor = following
            }
            return nil
        case "this":
            return add(days: (target - current + 7) % 7, to: today, calendar)
        default:
            let ahead = (target - current + 7) % 7
            return add(days: ahead == 0 ? 7 : ahead, to: today, calendar)
        }
    }

    private static func calendarDate(month: Int, day: Int, year: Int?, today: Date, calendar: Calendar) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        let thisYear = calendar.component(.year, from: today)
        func make(_ y: Int) -> Date? {
            let components = DateComponents(year: y, month: month, day: day)
            guard let date = calendar.date(from: components),
                  calendar.component(.month, from: date) == month, calendar.component(.day, from: date) == day else { return nil }
            return date
        }
        if let year { return make(year) }
        if let date = make(thisYear), date >= today { return date }
        return make(thisYear + 1)
    }

    private static func nextDayOfMonth(_ day: Int, today: Date, calendar: Calendar) -> Date? {
        guard (1...31).contains(day) else { return nil }
        var month = calendar.component(.month, from: today)
        var year = calendar.component(.year, from: today)
        for _ in 0..<14 {
            let components = DateComponents(year: year, month: month, day: day)
            if let date = calendar.date(from: components), calendar.component(.day, from: date) == day, date >= today {
                return date
            }
            month += 1
            if month > 12 { month = 1; year += 1 }
        }
        return nil
    }

    // MARK: Relative offsets ("in 2 hours")

    private static func extractRelativeOffset(_ work: inout String, now: Date) -> Date? {
        guard let groups = take(#"\bin\s+(\#(numberWord))\s+(hours?|hrs?|minutes?|mins?)\b"#, from: &work),
              let raw = groups[1], let count = value(of: raw), let unit = groups[2]?.lowercased() else { return nil }
        let minutes = Int((unit.hasPrefix("h") ? count * 60 : count).rounded())
        guard minutes > 0, minutes <= 24 * 60 else { return nil }
        return now.addingTimeInterval(Double(minutes) * 60)
    }

    // MARK: Time of day

    struct ClockTime: Equatable {
        let hour: Int      // 0...23
        let minute: Int
    }

    private struct TimeRange {
        let start: ClockTime
        let durationMinutes: Int?
    }

    /// Resolves an hour as spoken. 13-23 and 0 are 24-hour. With am/pm it is exact. Without:
    /// 12 is noon, 1-6 are afternoon or evening, and 7-11 are only clear from a part of day.
    private static func resolveHour(_ hour: Int, meridiem: String?, dayPart: DayPart) -> Int? {
        if hour > 23 || hour < 0 { return nil }
        if hour == 0 || hour >= 13 { return hour }
        if let meridiem = meridiem?.lowercased() {
            if meridiem == "am" { return hour == 12 ? 0 : hour }
            return hour == 12 ? 12 : hour + 12
        }
        switch dayPart.kind {
        case .morning: return hour == 12 ? 0 : hour
        case .afternoon, .evening: return hour == 12 ? 12 : hour + 12
        case .none:
            if hour == 12 { return 12 }
            if hour <= 6 { return hour + 12 }
            return nil
        }
    }

    private static func extractTimeRange(_ work: inout String, dayPart: DayPart) -> TimeRange? {
        let pattern = #"\b(?:from\s+|at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*(?:to|until|till|-)\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b"#
        guard let groups = take(pattern, from: &work),
              let startHour = groups[1].flatMap(Int.init), let endHour = groups[4].flatMap(Int.init),
              let endMeridiem = groups[6]?.lowercased() else { return nil }
        let startMinute = groups[2].flatMap(Int.init) ?? 0
        let endMinute = groups[5].flatMap(Int.init) ?? 0
        guard startHour <= 12, endHour <= 12, startMinute < 60, endMinute < 60,
              let end = resolveHour(endHour, meridiem: endMeridiem, dayPart: dayPart) else { return nil }
        var meridiem = groups[3]?.lowercased() ?? endMeridiem
        if groups[3] == nil, let candidate = resolveHour(startHour, meridiem: meridiem, dayPart: dayPart),
           candidate * 60 + startMinute >= end * 60 + endMinute {
            meridiem = meridiem == "pm" ? "am" : "pm"
        }
        guard let start = resolveHour(startHour, meridiem: meridiem, dayPart: dayPart) else { return nil }
        let minutes = (end * 60 + endMinute) - (start * 60 + startMinute)
        return TimeRange(start: ClockTime(hour: start, minute: startMinute), durationMinutes: minutes > 0 ? minutes : nil)
    }

    private static func extractTime(_ work: inout String, dayPart: DayPart) -> ClockTime? {
        if take(#"\b(?:at\s+)?noon\b"#, from: &work) != nil { return ClockTime(hour: 12, minute: 0) }
        // 7:30 pm, 19:00, 7:30
        if let groups = take(#"\b(?:at\s+|@\s*)?(\d{1,2}):(\d{2})\s*(am|pm)?\b"#, from: &work),
           let hour = groups[1].flatMap(Int.init), let minute = groups[2].flatMap(Int.init), minute < 60,
           let resolved = resolveHour(hour, meridiem: groups[3], dayPart: dayPart) {
            return ClockTime(hour: resolved, minute: minute)
        }
        // 7pm, 7 pm
        if let groups = take(#"\b(?:at\s+|@\s*)?(\d{1,2})\s*(am|pm)\b"#, from: &work),
           let hour = groups[1].flatMap(Int.init), hour >= 1, hour <= 12,
           let resolved = resolveHour(hour, meridiem: groups[2], dayPart: dayPart) {
            return ClockTime(hour: resolved, minute: 0)
        }
        // "at 7": only with the word "at", and only when it is clear.
        if let groups = take(#"\bat\s+(\d{1,2})\b(?!\s*(?:st|nd|rd|th)\b)"#, from: &work),
           let hour = groups[1].flatMap(Int.init), hour >= 1,
           let resolved = resolveHour(hour, meridiem: nil, dayPart: dayPart) {
            return ClockTime(hour: resolved, minute: 0)
        }
        return nil
    }

    // MARK: Combining

    private static func resolve(day: Date?, clock: ClockTime, now: Date, calendar: Calendar) -> Date? {
        func at(_ base: Date) -> Date? {
            calendar.date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: base)
        }
        if let day { return at(day) }
        let today = calendar.startOfDay(for: now)
        guard let candidate = at(today) else { return nil }
        if candidate > now { return candidate }
        guard let tomorrow = add(days: 1, to: today, calendar) else { return nil }
        return at(tomorrow)
    }
}
