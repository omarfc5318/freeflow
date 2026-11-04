import Foundation

// Canvas: upcoming assignments from the planner API. Foundation only.
// Privacy: the token goes only to the owner's own Canvas address (https), nowhere else.

enum RioCanvasConfig {
    static let defaultBase = "https://canvas.ucdavis.edu"
    /// UserDefaults key of the owner's Canvas address (Settings, Integrations).
    static let baseKey = "rio_canvas_base_url"

    /// The address text from settings. Swappable so tests never read the real defaults.
    nonisolated(unsafe) static var configuredText: () -> String = { UserDefaults.standard.string(forKey: baseKey) ?? "" }

    /// The owner's Canvas site, for "open Canvas": the configured address, or the default one.
    static var configuredBase: URL? { baseURL(from: configuredText()) ?? baseURL(from: "") }

    /// The scheme and host of the owner's Canvas, always https. Empty means the default.
    static func baseURL(from text: String) -> URL? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { raw = defaultBase }
        if !raw.contains("://") { raw = "https://" + raw }
        guard let components = URLComponents(string: raw), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty else { return nil }
        var base = URLComponents()
        base.scheme = "https"
        base.host = host.lowercased()
        base.port = components.port
        return base.url
    }
}

/// The spoken range Rio passes in `canvasDue(range:)`: a time ("today", "this week"), a course
/// code ("MAT108"), or both ("next week MAT108"). Anything else means the next 7 days, all courses.
enum RioCanvasRange {
    private static let knownRanges = ["today", "tomorrow", "this week", "next week"]

    /// "next week MAT108" -> ("next week", "MAT108"); "MAT108" -> (nil, "MAT108"); "today" -> ("today", nil).
    static func parts(_ spoken: String?) -> (range: String?, course: String?) {
        let text = RioText.collapseWhitespace(spoken ?? "")
        guard !text.isEmpty else { return (nil, nil) }
        let lower = text.lowercased()
        for range in knownRanges where lower == range || lower.hasPrefix(range + " ") {
            let rest = String(text.dropFirst(range.count)).trimmingCharacters(in: .whitespaces)
            return (range, rest.isEmpty ? nil : rest)
        }
        // A course code only: letters then digits ("MAT108", "ECS 119"). Anything else is unknown.
        return RioText.matches(#"^[A-Za-z]{2,5}\s?\d{2,4}[A-Za-z]?$"#, text) ? (nil, text) : (nil, nil)
    }

    static func interval(for spoken: String?, now: Date, calendar: Calendar) -> DateInterval {
        let day = calendar.startOfDay(for: now)
        func days(_ count: Int, from start: Date) -> Date { calendar.date(byAdding: .day, value: count, to: start) ?? start }
        switch parts(spoken).range {
        case "today": return DateInterval(start: day, end: days(1, from: day))
        case "tomorrow": return DateInterval(start: days(1, from: day), end: days(2, from: day))
        case "this week":
            // From now, not from Sunday: last Monday's work is not "due this week".
            let week = calendar.dateInterval(of: .weekOfYear, for: now) ?? DateInterval(start: day, duration: 7 * 86_400)
            return DateInterval(start: max(now, week.start), end: max(now, week.end))
        case "next week":
            let week = calendar.dateInterval(of: .weekOfYear, for: now) ?? DateInterval(start: day, duration: 7 * 86_400)
            return DateInterval(start: week.end, end: days(7, from: week.end))
        default: return DateInterval(start: now, end: days(7, from: now))
        }
    }

    static func label(for spoken: String?) -> String {
        parts(spoken).range ?? "in the next 7 days"
    }

    /// True when the item's course is the one named, ignoring case, spaces and section suffixes
    /// ("MAT108" matches "MAT 108 A01 Fall 2026").
    static func item(_ item: RioCanvasItem, isFor course: String) -> Bool {
        func folded(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let wanted = folded(course)
        guard !wanted.isEmpty, let name = item.course else { return false }
        let have = folded(name)
        guard let found = have.range(of: wanted) else { return false }
        // "MAT10" must not match "MAT108": the code can't run on into more digits.
        guard found.upperBound < have.endIndex else { return true }
        return !(wanted.last?.isNumber == true && have[found.upperBound].isNumber)
    }
}

struct RioCanvasItem: Equatable {
    let title: String
    let course: String?
    let due: Date
}

enum RioCanvasRequests {
    static func planner(base: URL, interval: DateInterval, token: String) -> URLRequest {
        let formatter = ISO8601DateFormatter()
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.path = "/api/v1/planner/items"
        components.percentEncodedQuery = [
            ("start_date", formatter.string(from: interval.start)), ("end_date", formatter.string(from: interval.end)), ("per_page", "50"),
        ].map { "\($0.0)=\(RioOutsideHTTP.encode($0.1))" }.joined(separator: "&")
        return RioOutsideHTTP.get(components.url, headers: ["Authorization": "Bearer \(token)", "Accept": "application/json"])
            ?? URLRequest(url: base)
    }
}

enum RioCanvasParser {
    private static let kinds: Set<String> = ["assignment", "quiz", "discussion_topic", "planner_note"]

    /// Things to do inside `interval`, soonest first. Anything already submitted, graded or excused is dropped.
    static func items(from data: Data, interval: DateInterval) -> [RioCanvasItem] {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ text: String?) -> Date? { text.flatMap { plain.date(from: $0) ?? fractional.date(from: $0) } }

        let found: [RioCanvasItem] = list.compactMap { item in
            guard let kind = item["plannable_type"] as? String, kinds.contains(kind),
                  let plannable = item["plannable"] as? [String: Any],
                  let title = plannable["title"] as? String, !title.isEmpty else { return nil }
            if let submission = item["submissions"] as? [String: Any],
               ["submitted", "graded", "excused"].contains(where: { submission[$0] as? Bool == true }) { return nil }
            guard let due = date(plannable["due_at"] as? String) ?? date(item["plannable_date"] as? String),
                  interval.contains(due) else { return nil }
            let course = (item["context_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return RioCanvasItem(title: title, course: course, due: due)
        }
        return found.sorted { $0.due < $1.due }
    }
}

enum RioCanvasSpeech {
    static let spokenLimit = 4

    static func sentence(items: [RioCanvasItem], range: String?, now: Date, calendar: Calendar) -> String {
        let label = RioCanvasRange.label(for: range)
        let course = RioCanvasRange.parts(range).course
        guard !items.isEmpty else {
            return course.map { "Nothing due \(label) for \($0) on Canvas." } ?? "Nothing due \(label) on Canvas."
        }
        let shown = items.prefix(spokenLimit).map { item -> String in
            let itemCourse = course == nil ? item.course.map { " for \($0)" } ?? "" : ""
            return "\(item.title)\(itemCourse) \(when(item.due, now: now, calendar: calendar))"
        }
        let lead = course.map { "For \($0) you have" } ?? "You have"
        var text = "\(lead) \(items.count) \(items.count == 1 ? "thing" : "things") due \(label): " + shown.joined(separator: ", ")
        if items.count > spokenLimit { text += ", and \(items.count - spokenLimit) more" }
        return text + "."
    }

    private static func when(_ due: Date, now: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "h:mm a"
        let time = formatter.string(from: due)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 0
        formatter.dateFormat = "EEEE"
        let weekday = formatter.string(from: due)
        // Already past: say so, never "today at" for something two days late.
        if due < now {
            switch days {
            case 0: return "overdue since \(time) today"
            case -1: return "overdue since yesterday at \(time)"
            default: return "overdue since \(weekday) at \(time)"
            }
        }
        switch days {
        case ..<1: return "today at \(time)"
        case 1: return "tomorrow at \(time)"
        default: return "\(weekday) at \(time)"
        }
    }
}

struct RioCanvasService {
    let fetch: RioFetch
    let base: URL
    let token: String

    func due(range: String?, now: Date, calendar: Calendar) async throws -> String {
        let interval = RioCanvasRange.interval(for: range, now: now, calendar: calendar)
        let data = try await RioOutsideHTTP.send(RioCanvasRequests.planner(base: base, interval: interval, token: token), using: fetch)
        let all = RioCanvasParser.items(from: data, interval: interval)
        let course = RioCanvasRange.parts(range).course
        let items = course.map { wanted in all.filter { RioCanvasRange.item($0, isFor: wanted) } } ?? all
        return RioCanvasSpeech.sentence(items: items, range: range, now: now, calendar: calendar)
    }
}
