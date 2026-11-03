import EventKit
import Foundation

extension Notification.Name {
    /// Posted on the main thread after Rio creates something it can later undo. `userInfo`:
    /// "kind" ("event") and "identifier" (the EventKit event identifier). No titles or other
    /// user content are included.
    static let rioItemCreated = Notification.Name("com.rio.itemCreated")
}

/// EventKit access for the calendar actions. Asks for permission on first use only.
@MainActor
final class RioCalendarService {
    static let shared = RioCalendarService()

    /// Called with the new event's identifier right after `create` saves it (the undo journal
    /// registers its inverse here). The `.rioItemCreated` notification carries the same value.
    static var onEventCreated: (@MainActor (String) -> Void)?

    enum ServiceError: Error {
        case accessDenied, noCalendar, saveFailed
    }

    private let store = EKEventStore()

    // EKAuthorizationStatus raw values: 0 notDetermined, 1 restricted, 2 denied, 3 full access, 4 write only.
    private var hasFullAccess: Bool { EKEventStore.authorizationStatus(for: .event).rawValue == 3 }

    func ensureAccess() async -> Bool {
        if hasFullAccess { return true }
        let status = EKEventStore.authorizationStatus(for: .event).rawValue
        if status == 1 || status == 2 { return false }
        do {
            if #available(macOS 14.0, *) {
                return try await store.requestFullAccessToEvents()
            } else {
                return try await store.requestAccess(to: .event)
            }
        } catch {
            return false
        }
    }

    /// Events overlapping the range, soonest first.
    func events(from start: Date, to end: Date) -> [RioCalendarEventInfo] {
        let calendars = store.calendars(for: .event).filter { $0.type != .birthday }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate).compactMap(Self.info(from:)).sorted { $0.start < $1.start }
    }

    private static func info(from event: EKEvent) -> RioCalendarEventInfo? {
        guard let identifier = event.eventIdentifier, let start = event.startDate, let end = event.endDate else { return nil }
        let declinedByMe = event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
        return RioCalendarEventInfo(
            identifier: identifier,
            title: event.title ?? "",
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            location: event.location,
            notes: event.notes,
            url: event.url,
            isDeclined: declinedByMe || event.status == .canceled
        )
    }

    /// Adds an event to the default calendar and returns its identifier.
    func create(title: String, start: Date, durationMinutes: Int?) throws -> String {
        guard hasFullAccess else { throw ServiceError.accessDenied }
        let calendar = store.defaultCalendarForNewEvents.flatMap { $0.allowsContentModifications ? $0 : nil }
            ?? store.calendars(for: .event).first(where: \.allowsContentModifications)
        guard let calendar else { throw ServiceError.noCalendar }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(Double(durationMinutes ?? 60) * 60)
        event.calendar = calendar
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw ServiceError.saveFailed
        }
        guard let identifier = event.eventIdentifier else { throw ServiceError.saveFailed }
        Self.onEventCreated?(identifier)
        NotificationCenter.default.post(
            name: .rioItemCreated, object: nil, userInfo: ["kind": "event", "identifier": identifier]
        )
        return identifier
    }

    /// Undo for `create`: removes the event Rio made. False when it is already gone or access
    /// was withdrawn.
    @discardableResult
    func deleteEvent(identifier: String) -> Bool {
        guard hasFullAccess, let event = store.event(withIdentifier: identifier) else { return false }
        return (try? store.remove(event, span: .thisEvent, commit: true)) != nil
    }
}
