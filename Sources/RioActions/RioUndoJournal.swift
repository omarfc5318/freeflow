import Foundation

/// Remembers how to take back what Rio just did, and runs the inverse for "Rio, undo".
///
/// The coordinator calls `willExecute` and `didExecute` for every action. The inverse table is
/// `RioUndoPlan` (pure, tested); this class captures the "before" state and runs the inverse
/// through the executor, so it gets the same app and volume handling as a normal command.
///
/// Handlers that create something undo can delete (a calendar event or reminder) report it with
/// `noteCreated(_:)` while they run, before returning their result:
///
///     RioUndoJournal.shared.noteCreated(.calendarEvent(identifier: event.eventIdentifier))
///     RioUndoJournal.shared.noteCreated(.reminder(identifier: reminder.calendarItemIdentifier))
@MainActor final class RioUndoJournal: RioActionObserving {
    static let shared = RioUndoJournal()

    private static let countKey = "rio_action_success_count"

    private struct Pending {
        let action: RioAction
        var snapshot: RioUndoSnapshot
        let window: RioWindowSnapshot?
    }

    private let timers: RioTimerCenter
    private let companion: RioCompanionCenter
    private let clock: () -> Date
    private var stack = RioUndoStack()
    private var pending: Pending?
    private var windowSnapshots: [UUID: RioWindowSnapshot] = [:]

    init(
        timers: RioTimerCenter? = nil,
        companion: RioCompanionCenter? = nil,
        clock: @escaping () -> Date = Date.init
    ) {
        self.timers = timers ?? RioTimerCenter.shared
        self.companion = companion ?? RioCompanionCenter.shared
        self.clock = clock
    }

    // MARK: RioActionObserving

    func willExecute(_ action: RioAction) async {
        // Starting something new means whoever set the timer has heard it.
        timers.stopRinging()
        let (snapshot, window) = RioUndoSnapshotter.capture(for: action, timers: timers)
        pending = Pending(action: action, snapshot: snapshot, window: window)
    }

    /// Call while an action runs, as soon as it has created something undo can delete.
    func noteCreated(_ item: RioCreatedItem) {
        pending?.snapshot.created = item
    }

    func didExecute(_ action: RioAction, result: RioActionResult) {
        let current = pending?.action == action ? pending : nil
        pending = nil
        guard case .done(let summary) = result else { return }
        registerSpokenText(action, summary: summary)
        if action == .stopListening { timers.stopRinging() }
        countSuccess(action)
        guard let current else { return }
        let disposition = RioUndoPlan.disposition(for: action, snapshot: current.snapshot)
        stack.record(action, disposition: disposition, now: clock())
        if case .reversible(.restoreWindow) = disposition, let window = current.window, let id = stack.records.last?.id {
            windowSnapshots[id] = window
            pruneWindowSnapshots()
        }
    }

    // MARK: Undo

    /// Takes back the most recent undoable action, or says why not.
    func undoLast(executor: RioActionExecuting) async -> RioActionResult {
        guard let record = stack.pop(now: clock()) else {
            return .failed(message: RioUndoPlan.nothingToUndoMessage)
        }
        let window = windowSnapshots.removeValue(forKey: record.id)
        switch record.disposition {
        case .ignore:
            return .failed(message: RioUndoPlan.nothingToUndoMessage)
        case .irreversible:
            return .failed(message: RioUndoPlan.cantUndoMessage)
        case .reversible(let inverse):
            let result = await run(inverse, window: window, executor: executor)
            if case .done = result { return .done(summary: RioUndoPlan.undoneSummary(for: inverse)) }
            // The inverse didn't work; keep it so the user can try again.
            stack.push(record)
            if let window { windowSnapshots[record.id] = window }
            return result
        }
    }

    private func run(_ inverse: RioUndoInverse, window: RioWindowSnapshot?, executor: RioActionExecuting) async -> RioActionResult {
        switch inverse {
        case .actions(let actions):
            var last = RioActionResult.done(summary: "")
            for action in actions {
                last = await executor.execute(action)
                if case .done = last { continue }
                return last
            }
            return last
        case .restoreWindow:
            guard let window else { return .failed(message: RioUndoPlan.cantUndoMessage) }
            return WindowController().restore(window)
        case .deleteCreated(let item):
            return RioUndoEventKit.delete(item)
        }
    }

    // MARK: Bookkeeping

    /// Answer-like actions are spoken as themselves, even when short ("64 percent").
    private func registerSpokenText(_ action: RioAction, summary: String) {
        switch action {
        case .answer, .readAloud, .calendarAgenda, .batteryStatus, .timerStatus, .showHelp, .undoLast,
             .clipboard(.readCurrent), .clipboard(.showHistory):
            RioPersonality.registerVerbatim(summary)
        case .selectionTask(let task):
            if case .improve = task { return }
            RioPersonality.registerVerbatim(summary)
        default:
            break
        }
    }

    /// Counts finished actions for the "100th action" celebration. Only real work counts.
    private func countSuccess(_ action: RioAction) {
        switch action {
        case .undoLast, .stopListening, .showHelp, .timerStatus: return
        default: break
        }
        let defaults = UserDefaults.standard
        let count = defaults.integer(forKey: Self.countKey) + 1
        defaults.set(count, forKey: Self.countKey)
        if RioPersonality.isMilestone(count) {
            RioPersonality.noteMilestone(count)
            companion.celebrate()
        }
    }

    private func pruneWindowSnapshots() {
        let alive = Set(stack.records.map(\.id))
        windowSnapshots = windowSnapshots.filter { alive.contains($0.key) }
    }
}
