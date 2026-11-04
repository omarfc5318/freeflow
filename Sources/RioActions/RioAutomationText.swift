import Foundation

/// How Rio talks about automations. Pure.
enum RioAutomationText {
    private static let dayNames = ["", "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    static func clock(hour: Int, minute: Int) -> String {
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return "\(twelve):\(String(format: "%02d", minute)) \(hour < 12 ? "AM" : "PM")"
    }

    static func describe(_ item: RioScheduledCommand, calendar: Calendar = .current) -> String {
        let time = clock(hour: item.hour, minute: item.minute)
        switch item.recurrence {
        case .daily: return "every day at \(time)"
        case .weekdays: return "every weekday at \(time)"
        case .weekly(let weekday):
            let name = dayNames.indices.contains(weekday) ? dayNames[weekday] : "week"
            return "every \(name) at \(time)"
        case .once:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "MMM d"
            return "on \(formatter.string(from: item.nextFire)) at \(time)"
        }
    }

    static func skipNote(for item: RioScheduledCommand, calendar: Calendar = .current) -> String {
        "I skipped \"\(item.command)\" (\(describe(item, calendar: calendar))) because the Mac was asleep or Rio was off at the time."
    }

    static func label(_ rule: RioTriggerRule) -> String { "\(rule.command) when \(rule.kind.spoken)" }
    static func label(_ macro: RioMacro) -> String { "\(macro.name) macro" }
    static func label(_ item: RioScheduledCommand, calendar: Calendar = .current) -> String {
        "\(item.command) \(describe(item, calendar: calendar))"
    }

    static func summary(_ data: RioAutomationData, calendar: Calendar = .current) -> String {
        guard !data.isEmpty else { return "You have no automations or macros yet." }
        var lines: [String] = []
        lines += data.schedules.map { "Scheduled: \(label($0, calendar: calendar))" }
        lines += data.triggers.map { "Trigger: \(label($0))" }
        lines += data.macros.map { "Macro: \($0.name) (\($0.steps.count) steps)" }
        lines += data.notes
        return lines.joined(separator: "\n")
    }
}
