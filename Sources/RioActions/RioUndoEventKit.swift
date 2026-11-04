import EventKit
import Foundation

/// Deletes a calendar event or reminder Rio created, for "undo". Never prompts: it only works if
/// calendar (or reminders) access was already granted, which creating the item required.
enum RioUndoEventKit {
    static func delete(_ item: RioCreatedItem) -> RioActionResult {
        let store = EKEventStore()
        switch item {
        case .downloadsMoved:
            // Undone through `RioUndoInverse.restoreDownloads`, never by deleting.
            return .failed(message: "I can't remove that")
        case .calendarEvent(let identifier):
            guard hasFullAccess(.event) else { return .failed(message: "I don't have calendar access to remove that") }
            guard let event = store.event(withIdentifier: identifier) else {
                return .failed(message: "I couldn't find that event any more")
            }
            return remove { try store.remove(event, span: .thisEvent, commit: true) }
        case .reminder(let identifier):
            guard hasFullAccess(.reminder) else { return .failed(message: "I don't have reminders access to remove that") }
            guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
                return .failed(message: "I couldn't find that reminder any more")
            }
            return remove { try store.remove(reminder, commit: true) }
        }
    }

    private static func remove(_ operation: () throws -> Void) -> RioActionResult {
        do {
            try operation()
            return .done(summary: "Removed it")
        } catch {
            return .failed(message: "I couldn't remove it")
        }
    }

    /// `.authorized` (macOS 13) and `.fullAccess` (macOS 14+) share the raw value 3.
    private static func hasFullAccess(_ type: EKEntityType) -> Bool {
        EKEventStore.authorizationStatus(for: type).rawValue == 3
    }
}
