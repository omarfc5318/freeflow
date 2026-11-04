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
            return await stop(executor: executor)
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

    /// Stops the one thing the words were about (RioStopPlan): a bare "stop" or "be quiet"
    /// never cancels a running countdown, only words that name the timer do.
    private func stop(executor: RioActionExecuting) async -> RioActionResult {
        let kind = RioStopRequest.current
        var state = Self.stopState(timers: timers, voice: voice)
        if kind == .bare, RioStopPlan.step(kind: kind, state: state) == .nothing {
            // Only now ask the players: it costs an Apple Event.
            state.isMediaPlaying = MacControls.playbackState() == .playing
        }
        switch RioStopPlan.step(kind: kind, state: state) {
        case .stopRinging:
            timers.stopRinging()
            return .done(summary: "Okay, stopped")
        case .cancelCountdown:
            timers.cancel()
            return .done(summary: "Timer cancelled")
        case .stopTask:
            RioTaskActionHandler.shared.stop()
            return .done(summary: "Okay, I stopped")
        case .stopSpeaking:
            voice.stopSpeaking()
            return .done(summary: kind == .silence ? "" : "Okay, quiet")
        case .stopTranslator:
            RioTranslatorMode.shared.stop(.voice)
            return .done(summary: "Stopped translating")
        case .pauseMedia:
            return await executor.execute(.media(.pause))
        case .nothing:
            guard let message = RioStopPlan.nothingMessage(kind: kind) else { return .done(summary: "") }
            return .failed(message: message)
        }
    }

    /// What a stop would find right now (the players are not asked here).
    static func stopState(timers: RioTimerCenter, voice: RioVoice) -> RioStopState {
        RioStopState(
            isRinging: timers.isRinging,
            hasCountdown: timers.countdown != nil,
            isTaskRunning: RioTaskProgress.shared.isRunning,
            isSpeaking: voice.isSpeaking,
            isTranslating: RioTranslatorMode.shared.isOn
        )
    }

    /// The step a stop of `kind` would take now, for the undo snapshot.
    static func stopStep(kind: RioStopKind?, timers: RioTimerCenter) -> RioStopStep {
        RioStopPlan.step(kind: kind, state: stopState(timers: timers, voice: RioVoice.shared))
    }

    private func timerStatus() -> RioActionResult {
        if let timer = timers.countdown {
            return .done(summary: timer.spokenRemaining(at: timers.now))
        }
        if timers.isRinging { return .done(summary: "Your timer is ringing") }
        return .failed(message: "There's no timer running")
    }
}
