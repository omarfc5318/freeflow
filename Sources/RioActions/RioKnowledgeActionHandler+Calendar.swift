import AppKit
import Foundation

/// The calendar half of the Knowledge handler (EventKit through `RioCalendarService`).
extension RioKnowledgeActionHandler {
    static let calendarAccessMessage =
        "I need access to your calendar. You can allow it in System Settings, Privacy and Security, Calendars."

    func agenda(_ range: CalendarRange) async -> RioActionResult {
        guard await calendarService.ensureAccess() else { return .failed(message: Self.calendarAccessMessage) }
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let window: (Date, Date)
        switch range {
        case .today:
            window = (today, calendar.date(byAdding: .day, value: 1, to: today) ?? now)
        case .tomorrow:
            let start = calendar.date(byAdding: .day, value: 1, to: today) ?? now
            window = (start, calendar.date(byAdding: .day, value: 1, to: start) ?? start)
        case .next:
            window = (now, calendar.date(byAdding: .day, value: 7, to: now) ?? now)
        }
        let events = calendarService.events(from: window.0, to: window.1)
        return .done(summary: RioCalendarSummary.agenda(range: range, events: events, now: now, calendar: calendar))
    }

    func joinNextMeeting() async -> RioActionResult {
        guard await calendarService.ensureAccess() else { return .failed(message: Self.calendarAccessMessage) }
        let now = Date()
        let events = calendarService.events(from: now, to: now.addingTimeInterval(24 * 3600))
        switch RioMeetingPicker.pick(events: events, now: now) {
        case .join(let event, let url):
            guard NSWorkspace.shared.open(url) else { return .failed(message: "I couldn't open the meeting link") }
            let title = RioText.collapseWhitespace(event.title)
            return .done(summary: title.isEmpty ? "Joining your meeting" : "Joining \(title)")
        case .noLink(let event):
            let title = RioText.collapseWhitespace(event.title)
            return .failed(message: title.isEmpty ? "Your next event doesn't have a meeting link" : "\(title) doesn't have a meeting link")
        case .none:
            return .failed(message: "I don't see a meeting coming up in the next day")
        }
    }

    func createEvent(title: String, start: Date, durationMinutes: Int?) async -> RioActionResult {
        guard await calendarService.ensureAccess() else { return .failed(message: Self.calendarAccessMessage) }
        do {
            _ = try calendarService.create(title: title, start: start, durationMinutes: durationMinutes)
        } catch RioCalendarService.ServiceError.noCalendar {
            return .failed(message: "I couldn't find a calendar to add that to")
        } catch RioCalendarService.ServiceError.accessDenied {
            return .failed(message: Self.calendarAccessMessage)
        } catch {
            return .failed(message: "I couldn't save that event")
        }
        return .done(summary: RioCalendarSummary.created(
            title: title, start: start, durationMinutes: durationMinutes, now: Date(), calendar: Calendar.current
        ))
    }
}
