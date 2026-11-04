import AppKit
import Foundation

/// Runs builder P's actions: scheduled commands, triggers, macros, and listing or removing them.
/// Returns nil for every other action so the next handler gets its turn.
///
/// Privacy: everything is kept in one 0600 file on this Mac (`RioAutomationStore`). A recorded
/// macro stores the text typed while recording (never in secure fields), so it is disclosed in
/// Settings. Nothing is sent anywhere.
@MainActor
final class RioAutomationActionHandler: RioActionHandling {
    static let shared = RioAutomationActionHandler()

    /// Pause between replayed steps, so each app has time to react before the next one.
    private static let stepPauseNanoseconds: UInt64 = 700_000_000
    private let store: RioAutomationStore
    private let center: RioAutomationCenter
    private var isReplaying = false

    init(store: RioAutomationStore = .shared, center: RioAutomationCenter? = nil) {
        self.store = store
        self.center = center ?? RioAutomationCenter.shared
    }

    func handle(_ action: RioAction, executor: RioActionExecuting) async -> RioActionResult? {
        switch action {
        case .scheduleCommand(let command, let when): return schedule(command, when: when)
        case .addTrigger(let command, let trigger): return await addTrigger(command, spec: trigger)
        case .listAutomations: return list()
        case .removeAutomation(let name): return remove(name)
        case .recordMacro(let name): return startRecording(name)
        case .stopRecordingMacro: return stopRecording()
        case .runMacro(let name): return await runMacro(name, executor: executor)
        default: return nil
        }
    }

    // MARK: Scheduling

    private func schedule(_ command: String, when: String) -> RioActionResult {
        let clean = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return .failed(message: "I didn't catch what to run.") }
        guard RioAutomationPhrases.parse(raw: clean, simplified: RioText.simplify(clean)) == nil else {
            return .failed(message: "I can't schedule a schedule. Pick a plain command.")
        }
        let calendar = Calendar.current
        guard let parsed = RioScheduleParser.parse(when, now: Date(), calendar: calendar) else {
            return .failed(message: "I couldn't tell when. Try \"every weekday at 8 am\" or \"in 20 minutes\".")
        }
        let item = RioScheduledCommand(id: UUID(), command: clean, recurrence: parsed.recurrence, hour: parsed.hour,
                                       minute: parsed.minute, nextFire: parsed.firstFire, createdAt: Date())
        guard store.add(item) else { return .failed(message: "That's too many scheduled commands. Remove one first.") }
        if store.lastSaveFailed { return .failed(message: "I couldn't save that to this Mac's disk.") }
        return .done(summary: "Okay, I'll \(clean) \(RioAutomationText.describe(item, calendar: calendar))")
    }

    private func addTrigger(_ command: String, spec: String) async -> RioActionResult {
        let clean = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return .failed(message: "I didn't catch what to run.") }
        guard let kind = RioTriggerKind(spec: spec) else { return .failed(message: "I don't know that kind of trigger.") }
        guard RioAutomationPhrases.parse(raw: clean, simplified: RioText.simplify(clean)) == nil else {
            return .failed(message: "I can't chain automations. Pick a plain command.")
        }
        if kind.needsLocation, !(await RioWiFiLocationAccess.shared.ensure()) {
            return .failed(message: "Wi-Fi triggers need Location access to read the network name. You can allow it in System Settings, Privacy and Security.")
        }
        let rule = RioTriggerRule(id: UUID(), command: clean, kind: kind, createdAt: Date(), lastFired: nil)
        guard store.add(rule) else { return .failed(message: "That's too many triggers. Remove one first.") }
        if store.lastSaveFailed { return .failed(message: "I couldn't save that to this Mac's disk.") }
        center.refreshWatcher()
        return .done(summary: "Okay, I'll \(clean) when \(kind.spoken)")
    }

    // MARK: List and remove

    private func list() -> RioActionResult {
        .done(summary: RioAutomationText.summary(store.data))
    }

    private func remove(_ name: String) -> RioActionResult {
        switch store.remove(matching: name) {
        case .removed(let label):
            center.refreshWatcher()
            return .done(summary: "Removed \(label)")
        case .notFound:
            return .failed(message: "I couldn't find an automation called \(name).")
        case .ambiguous(let labels):
            return .failed(message: "That matches \(labels.count): \(labels.prefix(3).joined(separator: "; ")). Say a bit more of the name.")
        }
    }

    // MARK: Macros

    private func startRecording(_ name: String) -> RioActionResult {
        guard RioAX.isTrusted else {
            return .failed(message: "I need Accessibility permission to watch clicks. Turn it on in System Settings, Privacy and Security.")
        }
        guard !isReplaying else { return .failed(message: "I'm replaying a macro right now.") }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = clean.isEmpty ? "Macro \(store.data.macros.count + 1)" : clean
        guard RioMacroRecorder.shared.start(name: chosen) else { return .failed(message: "I'm already watching you.") }
        return .done(summary: "I'm watching. Do your steps, then say \"stop recording the macro\".")
    }

    private func stopRecording() -> RioActionResult {
        let recorder = RioMacroRecorder.shared
        guard recorder.isRecording else { return .failed(message: "I wasn't recording a macro.") }
        let result = recorder.stop()
        guard !result.steps.isEmpty else { return .failed(message: "I didn't see anything to save.") }
        store.save(RioMacro(id: UUID(), name: result.name, steps: result.steps, createdAt: Date()))
        if store.lastSaveFailed { return .failed(message: "I couldn't save that to this Mac's disk.") }
        return .done(summary: "Saved \(result.name) with \(result.steps.count) steps")
    }

    private func runMacro(_ name: String, executor: RioActionExecuting) async -> RioActionResult {
        guard !RioMacroRecorder.shared.isRecording else { return .failed(message: "Finish recording first.") }
        guard !isReplaying else { return .failed(message: "I'm already running a macro.") }
        guard let macro = store.macro(named: name) else { return .failed(message: "I couldn't find a macro called \(name).") }
        isReplaying = true
        defer { isReplaying = false }
        for (index, step) in macro.steps.enumerated() {
            guard RioMacroMapper.isReplayable(step) else {
                return .failed(message: "Step \(index + 1) of \(macro.name) isn't something I can replay.")
            }
            if Task.isCancelled { return .cancelled }
            let result = await executor.execute(step)
            switch result {
            case .done: break
            case .failed(let message): return .failed(message: "\(macro.name) stopped at step \(index + 1): \(message)")
            case .cancelled: return .cancelled
            }
            try? await Task.sleep(nanoseconds: Self.stepPauseNanoseconds)
        }
        return .done(summary: "Ran \(macro.name), \(macro.steps.count) steps")
    }
}
