import AppKit
import Foundation

/// Runs `.runTask(goal:)`: the multi-step agent. Everything the agent does goes through the
/// executor it is handed, so the normal safety rules apply to every step. Returns nil for every
/// other action.
///
/// Stop: Esc is watched for the length of a task; "Rio, stop" and Fn+Control are wired by the
/// lead to `stop()`. Stopping ends the task before its next step and closes any open question.
@MainActor
final class RioTaskActionHandler: RioActionHandling {
    static let shared = RioTaskActionHandler()

    private static let escapeKeyCode: UInt16 = 53

    private let progress: RioTaskProgress
    private let prompter: RioTaskPrompter
    private var escapeMonitor: Any?

    init(progress: RioTaskProgress? = nil, prompter: RioTaskPrompter? = nil) {
        self.progress = progress ?? RioTaskProgress.shared
        self.prompter = prompter ?? RioTaskPrompter()
    }

    func handle(_ action: RioAction, executor: RioActionExecuting) async -> RioActionResult? {
        guard case .runTask(let goal) = action else { return nil }
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= RioTaskPhrases.maxGoalCharacters,
              !trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            return .failed(message: "I didn't catch what you want me to do.")
        }
        guard RioTaskSettings.isEnabled, RioSmartSettings.isEnabled else { return .failed(message: RioSmartMessages.disabled) }
        guard NetworkMonitor.shared.isOnline else { return .failed(message: RioSmartMessages.offline) }
        guard RioSmartSettings.llmConfig() != nil else { return .failed(message: RioSmartMessages.notConfigured) }
        guard RioAX.isTrusted else { return .failed(message: RioContextReader.needsAccessibility) }
        guard !progress.isRunning else { return .failed(message: "I'm already working on a task. Say stop first.") }
        let front = NSWorkspace.shared.frontmostApplication
        if RioTaskSafety.isTerminal(appName: front?.localizedName, bundleID: front?.bundleIdentifier) {
            return .failed(message: RioTaskSafety.terminalMessage)
        }

        startWatchingEscape()
        defer { stopWatchingEscape() }
        let runner = RioTaskRunner(
            observer: RioTaskObserver(), resolver: RioTaskTargetResolver(), model: RioTaskVisionModel(), prompter: prompter, reporter: progress
        )
        // A goal the smart resolver wrote is checked against the owner's own command.
        let safetyGoal = RioPlannedGoals.shared.ownerCommand(forGoal: trimmed, now: Date())
        return await runner.run(goal: trimmed, safetyGoal: safetyGoal, executor: executor)
    }

    /// The stop trigger: "Rio, stop", Esc, Fn+Control. Safe to call at any time.
    func stop() {
        progress.requestStop()
        prompter.dismiss()
    }

    private func startWatchingEscape() {
        stopWatchingEscape()
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == Self.escapeKeyCode else { return }
            Task { @MainActor in self?.stop() }
        }
    }

    private func stopWatchingEscape() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }
}
