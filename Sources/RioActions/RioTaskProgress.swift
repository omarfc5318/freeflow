import Foundation
import Combine

/// What the multi-step agent is doing right now, for the corner bear's progress card ("Step 4:
/// searching flights"). The agent publishes here; the lead wires the bear to observe it, and
/// wires every stop trigger ("Rio, stop", Esc, Fn+Control) to `requestStop()`.
@MainActor
final class RioTaskProgress: ObservableObject, RioTaskReporting {
    static let shared = RioTaskProgress()

    @Published private(set) var isRunning = false
    @Published private(set) var stepNumber = 0
    /// The current step in the bear's words, e.g. "Searching flights"; nil when idle.
    @Published private(set) var stepText: String?
    /// "Step 4: Searching flights", or nil when idle.
    var cardText: String? {
        guard isRunning else { return nil }
        guard let stepText, stepNumber > 0 else { return stepText ?? "Starting" }
        return "Step \(stepNumber): \(stepText)"
    }

    private(set) var isStopRequested = false

    /// Ends the running task at the next safe point (before its next step). Harmless when
    /// nothing is running.
    func requestStop() {
        guard isRunning else { return }
        isStopRequested = true
    }

    func begin(goal: String) {
        isStopRequested = false
        isRunning = true
        stepNumber = 0
        stepText = "Starting"
    }

    func update(step: Int, text: String) {
        stepNumber = step
        stepText = text
    }

    func finish() {
        isRunning = false
        isStopRequested = false
        stepNumber = 0
        stepText = nil
    }
}
