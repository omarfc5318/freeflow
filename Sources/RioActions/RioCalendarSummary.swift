import Foundation

/// What Rio says about the calendar. Pure: events are plain values and `now` and the calendar
/// are injected. Titles are the user's own words: they are spoken and shown, never logged.
enum RioCalendarSummary {
    private static let monthNames = [
        "January", "February", "March", "April", "May", "June", "July", "August", "September",
        "October", "November", "December",
    ]
    private static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    // MARK: Times and days

    /// "3 PM", "3:30 PM", "12:05 AM" (no locale: Rio always speaks it this way).
    static func clock(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour24 = parts.hour ?? 0
        let minute = parts.minute ?? 0
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        let suffix = hour24 < 12 ? "AM" : "PM"
        return minute == 0 ? "\(hour12) \(suffix)" : "\(hour12):\(String(format: "%02d", minute)) \(suffix)"
    }

    /// "today at 7 PM", "tomorrow at 7 PM", "Friday at 1 PM", "November 20 at 9 AM".
    static func dayAndTime(_ date: Date, now: Date, calendar: Calendar) -> String {
        "\(dayLabel(date, now: now, calendar: calendar)) at \(clock(date, calendar: calendar))"
    }

    static func dayLabel(_ date: Date, now: Date, calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let offset = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        switch offset {
        case 0: return "today"
        case 1: return "tomorrow"
        case 2...6: return weekdayNames[calendar.component(.weekday, from: date) - 1]
        default:
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            let base = "\(monthNames[(parts.month ?? 1) - 1]) \(parts.day ?? 1)"
            let sameYear = parts.year == calendar.component(.year, from: now)
            return sameYear ? base : "\(base), \(parts.year ?? 0)"
        }
    }

    private static func isSameDay(_ a: Date, _ b: Date, _ calendar: Calendar) -> Bool {
        calendar.isDate(a, inSameDayAs: b)
    }

    /// "at 3 PM" on the same day, "tomorrow at 9 AM" otherwise.
    private static func when(_ date: Date, now: Date, calendar: Calendar) -> String {
        isSameDay(date, now, calendar) ? "at \(clock(date, calendar: calendar))" : dayAndTime(date, now: now, calendar: calendar)
    }

    private static func name(_ event: RioCalendarEventInfo) -> String {
        let title = RioText.collapseWhitespace(event.title)
        return title.isEmpty ? "an untitled event" : title
    }

    private static func things(_ count: Int) -> String { count == 1 ? "1 thing" : "\(count) things" }

    // MARK: Agenda

    static func agenda(range: CalendarRange, events: [RioCalendarEventInfo], now: Date, calendar: Calendar) -> String {
        let active = events.filter { !$0.isDeclined }
        let timed = active.filter { !$0.isAllDay }.sorted { ($0.start, $0.identifier) < ($1.start, $1.identifier) }
        let allDay = active.filter(\.isAllDay).sorted { $0.identifier < $1.identifier }
        switch range {
        case .today: return today(active: active, timed: timed, allDay: allDay, now: now, calendar: calendar)
        case .tomorrow: return tomorrow(active: active, timed: timed, allDay: allDay, calendar: calendar)
        case .next: return next(timed: timed, now: now, calendar: calendar)
        }
    }

    private static func allDayPhrase(_ events: [RioCalendarEventInfo]) -> String {
        events.prefix(2).map { "\(name($0)), all day" }.joined(separator: ", and ")
    }

    private static func today(active: [RioCalendarEventInfo], timed: [RioCalendarEventInfo], allDay: [RioCalendarEventInfo],
                              now: Date, calendar: Calendar) -> String {
        guard !active.isEmpty else { return "Your calendar is clear today." }
        let intro = "You've got \(things(active.count)) today"
        if let current = timed.first(where: { $0.start <= now && now < $0.end }) {
            return "\(intro). Right now: \(name(current)) until \(clock(current.end, calendar: calendar))."
        }
        if let upcoming = timed.first(where: { $0.start > now }) {
            return "\(intro). Next: \(name(upcoming)) at \(clock(upcoming.start, calendar: calendar))."
        }
        if timed.isEmpty { return "\(intro): \(allDayPhrase(allDay))." }
        return active.count == 1 ? "\(intro), and it's already done." : "\(intro), and they're all done."
    }

    private static func tomorrow(active: [RioCalendarEventInfo], timed: [RioCalendarEventInfo], allDay: [RioCalendarEventInfo], calendar: Calendar) -> String {
        guard !active.isEmpty else { return "Your calendar is clear tomorrow." }
        let intro = "Tomorrow you've got \(things(active.count))"
        guard let first = timed.first else { return "\(intro): \(allDayPhrase(allDay))." }
        return "\(intro). First: \(name(first)) at \(clock(first.start, calendar: calendar))."
    }

    private static func next(timed: [RioCalendarEventInfo], now: Date, calendar: Calendar) -> String {
        let ahead = timed.filter { $0.end > now }
        guard !ahead.isEmpty else { return "Nothing coming up on your calendar." }
        if let current = ahead.first(where: { $0.start <= now }) {
            var line = "Right now: \(name(current)) until \(clock(current.end, calendar: calendar))."
            if let upcoming = ahead.first(where: { $0.start > now }) {
                line += " Then \(name(upcoming)) \(when(upcoming.start, now: now, calendar: calendar))."
            }
            return line
        }
        let upcoming = ahead[0]
        return "Next up: \(name(upcoming)) \(when(upcoming.start, now: now, calendar: calendar))."
    }

    // MARK: Past times

    /// Asked instead of silently adding an event that already happened. Nil when the time is
    /// still ahead (a minute of slack covers speaking time).
    static func pastEventMessage(start: Date, now: Date, calendar: Calendar) -> String? {
        guard start < now.addingTimeInterval(-60) else { return nil }
        return "That time has already passed (\(dayAndTime(start, now: now, calendar: calendar))). Tell me a time that's still ahead."
    }

    // MARK: Meeting not yet joinable

    /// "Call with Ali starts at 3 PM, so I didn't open it yet. Ask me again closer to the time."
    static func startsLater(_ event: RioCalendarEventInfo, now: Date, calendar: Calendar) -> String {
        "\(name(event)) starts \(when(event.start, now: now, calendar: calendar)), so I didn't open it yet. Ask me again closer to the time."
    }

    // MARK: Created event

    static func created(title: String, start: Date, durationMinutes: Int?, now: Date, calendar: Calendar) -> String {
        var line = "Added \(title), \(dayAndTime(start, now: now, calendar: calendar))"
        if let durationMinutes { line += " for \(durationPhrase(minutes: durationMinutes))" }
        return line
    }

    static func durationPhrase(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest) minutes" }
        if rest == 0 { return hours == 1 ? "an hour" : "\(hours) hours" }
        if rest == 30 { return hours == 1 ? "an hour and a half" : "\(hours) and a half hours" }
        return "\(hours) \(hours == 1 ? "hour" : "hours") \(rest) minutes"
    }
}
