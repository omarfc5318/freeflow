import Foundation

// Canvas: upcoming assignments from the planner API. Foundation only.
// Privacy: the token goes only to the owner's own Canvas address (https), nowhere else.

enum RioCanvasConfig {
    static let defaultBase = "https://canvas.ucdavis.edu"

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

enum RioCanvasRange {
    static func interval(for spoken: String?, now: Date, calendar: Calendar) -> DateInterval {
        let day = calendar.startOfDay(for: now)
        func days(_ count: Int, from start: Date) -> Date { calendar.date(byAdding: .day, value: count, to: start) ?? start }
        switch (spoken ?? "").lowercased() {
        case "today": return DateInterval(start: day, end: days(1, from: day))
        case "tomorrow": return DateInterval(start: days(1, from: day), end: days(2, from: day))
        case "this week":
            return calendar.dateInterval(of: .weekOfYear, for: now) ?? DateInterval(start: day, duration: 7 * 86_400)
        case "next week":
            let week = calendar.dateInterval(of: .weekOfYear, for: now) ?? DateInterval(start: day, duration: 7 * 86_400)
            return DateInterval(start: week.end, end: days(7, from: week.end))
        default: return DateInterval(start: now, end: days(7, from: now))
        }
    }

    static func label(for spoken: String?) -> String {
        switch (spoken ?? "").lowercased() {
        case "today", "tomorrow", "this week", "next week": return spoken!.lowercased()
        default: return "in the next 7 days"
        }
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
        guard !items.isEmpty else { return "Nothing due \(label) on Canvas." }
        let shown = items.prefix(spokenLimit).map { item -> String in
            let course = item.course.map { " for \($0)" } ?? ""
            return "\(item.title)\(course) \(when(item.due, now: now, calendar: calendar))"
        }
        var text = "You have \(items.count) \(items.count == 1 ? "thing" : "things") due \(label): " + shown.joined(separator: ", ")
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
        switch days {
        case ..<1: return "today at \(time)"
        case 1: return "tomorrow at \(time)"
        default:
            formatter.dateFormat = "EEEE"
            return "\(formatter.string(from: due)) at \(time)"
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
        let items = RioCanvasParser.items(from: data, interval: interval)
        return RioCanvasSpeech.sentence(items: items, range: range, now: now, calendar: calendar)
    }
}
