import Foundation

/// Finds the link that joins a calendar meeting (Zoom, Meet, Teams, FaceTime, Webex…). Pure.
/// Only https and http links to known meeting hosts are ever returned, so a hostile event
/// can't make Rio open an arbitrary scheme or a look-alike domain.
enum RioMeetingLinks {
    private static let hosts = [
        "zoom.us", "zoomgov.com", "meet.google.com", "teams.microsoft.com", "teams.live.com",
        "facetime.apple.com", "webex.com", "whereby.com", "gotomeeting.com", "bluejeans.com",
    ]

    /// The first join link, looking at the event's URL field, then its location, then its notes.
    static func joinURL(url: URL?, location: String?, notes: String?) -> URL? {
        if let url, let valid = validated(url) { return valid }
        for text in [location, notes] {
            guard let text else { continue }
            for candidate in urls(in: text) {
                if let valid = validated(candidate) { return valid }
            }
        }
        return nil
    }

    private static func validated(_ url: URL, depth: Int = 0) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return nil }
        if hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url }
        // Outlook wraps links: https://….safelinks.protection.outlook.com/?url=<encoded link>
        if depth == 0, host.hasSuffix(".safelinks.protection.outlook.com") || host == "safelinks.protection.outlook.com",
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let inner = components.queryItems?.first(where: { $0.name == "url" })?.value,
           let innerURL = URL(string: inner) {
            return validated(innerURL, depth: 1)
        }
        return nil
    }

    private static func urls(in text: String) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>"'\)\]]+"#, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            var raw = String(text[swiftRange])
            while let last = raw.last, ".,;:!?".contains(last) { raw.removeLast() }
            return URL(string: raw)
        }
    }
}

/// The part of an event Rio needs. Plain values, so the summary and meeting logic are testable
/// without EventKit.
struct RioCalendarEventInfo: Equatable {
    let identifier: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    let notes: String?
    let url: URL?
    let isDeclined: Bool
    /// Someone else's invite that the owner hasn't accepted (pending/unknown RSVP). Shown in the
    /// agenda, but never auto-joined: calendar spam often carries a meeting link.
    var isUnacceptedInvite: Bool = false
    /// False for subscribed and read-only (imported) calendars: anyone can publish an event
    /// with a meeting link there, so it is never one of the owner's meetings for joining.
    var isOwnerCalendar: Bool = true
}

enum RioMeetingPick: Equatable {
    case join(RioCalendarEventInfo, URL)
    /// The next real event has no meeting link.
    case noLink(RioCalendarEventInfo)
    /// The next meeting with a link starts too far ahead to open yet; Rio says when it is.
    case later(RioCalendarEventInfo)
    case none
}

enum RioMeetingPicker {
    /// How far ahead "join my meeting" will open a link: a meeting now or starting within this.
    static let joinWindow: TimeInterval = 15 * 60

    /// "Join my next meeting": a meeting in progress or starting within 15 minutes, on one of the
    /// owner's own calendars. A later one is reported (`.later`), never opened. All-day, finished,
    /// declined, unaccepted and subscribed-calendar events are skipped.
    static func pick(events: [RioCalendarEventInfo], now: Date) -> RioMeetingPick {
        let horizon = now.addingTimeInterval(24 * 3600)
        let candidates = events
            .filter {
                !$0.isAllDay && !$0.isDeclined && !$0.isUnacceptedInvite && $0.isOwnerCalendar
                    && $0.end > now && $0.start < horizon
            }
            .sorted { ($0.start, $0.identifier) < ($1.start, $1.identifier) }
        for event in candidates {
            guard let link = RioMeetingLinks.joinURL(url: event.url, location: event.location, notes: event.notes) else { continue }
            return event.start <= now.addingTimeInterval(joinWindow) ? .join(event, link) : .later(event)
        }
        if let first = candidates.first { return .noLink(first) }
        return .none
    }
}
