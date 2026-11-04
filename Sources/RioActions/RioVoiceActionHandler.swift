import Foundation

/// Runs Rio's own actions: timers, undo and help. Everything else returns nil so the next
/// handler (files and calendar, system, smart) gets its turn.
@MainActor final class RioVoiceActionHandler: RioActionHandling {
    static let shared = RioVoiceActionHandler()

    private let timers: RioTimerCenter
    private let journal: RioUndoJournal
    private let help: RioHelpPanelController
    private let voice: RioVoice

    init(
        timers: RioTimerCenter? = nil,
        journal: RioUndoJournal? = nil,
        help: RioHelpPanelController? = nil,
        voice: RioVoice? = nil
    ) {
        self.timers = timers ?? RioTimerCenter.shared
        self.journal = journal ?? RioUndoJournal.shared
        self.help = help ?? RioHelpPanelController.shared
        self.voice = voice ?? RioVoice.shared
    }

    func handle(_ action: RioAction, executor: RioActionExecuting) async -> RioActionResult? {
        switch action {
        case .startTimer(let seconds, let label):
            guard (1...RioTimerDuration.maxSeconds).contains(seconds) else {
                return .failed(message: "I can only set timers up to 24 hours")
            }
            let previous = timers.countdown
            let started = timers.start(seconds: seconds, label: label)
            return .done(summary: started.startedSummary(replacing: previous, at: timers.now))
        case .cancelTimer:
            return cancelTimer()
        case .timerStatus:
            return timerStatus()
        case .undoLast:
            return await journal.undoLast(executor: executor)
        case .showHelp:
            help.show()
            return .done(summary: RioHelpCatalogue.spokenSummary)
        default:
            return nil
        }
    }

    private func cancelTimer() -> RioActionResult {
        // "Rio, stop" first stops a running multi-step task (builder K).
        if RioTaskProgress.shared.isRunning {
            RioTaskActionHandler.shared.stop()
            return .done(summary: "Okay, I stopped")
        }
        switch timers.cancel() {
        case .cancelled: return .done(summary: "Timer cancelled")
        case .stoppedRinging: return .done(summary: "Okay, stopped")
        case .nothing:
            // "Rio, stop" while he is talking just means be quiet.
            if voice.isSpeaking {
                voice.stopSpeaking()
                return .done(summary: "Okay, quiet")
            }
            // "Rio, stop" while the live translator is on means stop translating.
            if RioTranslatorMode.shared.isOn {
                RioTranslatorMode.shared.stop(.voice)
                return .done(summary: "Stopped translating")
            }
            return .failed(message: "There's nothing to stop")
        }
    }

    private func timerStatus() -> RioActionResult {
        if let timer = timers.countdown {
            return .done(summary: timer.spokenRemaining(at: timers.now))
        }
        if timers.isRinging { return .done(summary: "Your timer is ringing") }
        return .failed(message: "There's no timer running")
    }
}
