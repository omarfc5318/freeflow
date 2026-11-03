import EventKit
import Foundation

/// Creates reminders with EventKit and remembers what it created so Undo can remove it.
/// Builder G's undo journal reads `lastCreatedReminderID` right after a `.createReminder`
/// succeeds and later calls `deleteReminder(id:)`. Identifiers are kept in memory only.
@MainActor
final class RioReminderStore {
    static let shared = RioReminderStore()

    private let store = EKEventStore()
    private(set) var createdReminderIDs: [String] = []

    var lastCreatedReminderID: String? { createdReminderIDs.last }

    private func requestAccess() async -> Bool {
        if #available(macOS 14.0, *) {
            return (try? await store.requestFullAccessToReminders()) ?? false
        }
        return await withCheckedContinuation { continuation in
            store.requestAccess(to: .reminder) { granted, _ in continuation.resume(returning: granted) }
        }
    }

    func create(title: String, due: Date?) async -> RioActionResult {
        guard await requestAccess() else {
            return .failed(message: "I need permission to use Reminders. You can allow it in System Settings, Privacy and Security.")
        }
        guard let list = store.defaultCalendarForNewReminders() else {
            return .failed(message: "I couldn't find a Reminders list to add it to.")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            if due > Date() { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            return .failed(message: "I couldn't save that reminder.")
        }
        createdReminderIDs.append(reminder.calendarItemIdentifier)
        guard let due else { return .done(summary: "Added a reminder: \(title)") }
        return .done(summary: "Reminder set for \(Self.format(due)): \(title)")
    }

    /// Removes a reminder this store created. False if it is already gone or can't be removed.
    @discardableResult
    func deleteReminder(id: String) -> Bool {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return false }
        do {
            try store.remove(reminder, commit: true)
            createdReminderIDs.removeAll { $0 == id }
            return true
        } catch {
            return false
        }
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }
}
