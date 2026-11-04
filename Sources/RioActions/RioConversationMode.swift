import AppKit
import Combine
import Foundation

/// Conversation mode: Rio keeps the microphone open and acts on anything said after "Rio".
/// Toggled by the Fn + Control + Option key chord, the menu bar item, or Settings. It turns itself off
/// on "Rio, stop listening" and after 5 minutes with no command, and it steps aside while
/// another app is using the microphone (a call) or while you dictate.
///
/// The rules live in the pure `RioConversationCore`; this class owns the listener, the tap
/// monitor, the 2-second poll and the sounds. Audio is recognised on-device only (see
/// `WakeWordListener`); speech without the name is dropped.
@MainActor final class RioConversationMode: ObservableObject {
    static let shared = RioConversationMode()

    @Published private(set) var isOn = false
    /// True while conversation mode is on but paused (another app is using the mic, or dictation).
    @Published private(set) var isPaused = false
    /// Paused for a call (another app has the microphone); the bear and the menu bar show it.
    @Published private(set) var isPausedForCall = false
    /// Why it couldn't start; shown in Settings.
    @Published private(set) var statusMessage: String?

    /// Receives the text after "Rio" for every command heard. AppState runs it through the
    /// same action pipeline as the action key.
    var onCommand: (@MainActor (String) -> Void)?
    /// Plays a short system sound by name (AppState routes it through the sound settings).
    var playSound: (@MainActor (String) -> Void)?
    /// Plays conversation mode's own on/off chime (AppState routes it through the sound settings).
    var playChime: (@MainActor (RioChime) -> Void)?

    private static let pollInterval: UInt64 = 2_000_000_000

    private var core = RioConversationCore()
    private var debounce = MicUsageDebounce()
    private var listener: WakeWordListener?
    private var listenerRunning = false
    private var listenerStarting = false
    private var pollTask: Task<Void, Never>?
    private var announceTask: Task<Void, Never>?
    /// Rio is talking: only a bare stop is taken (`RioConversationBargeIn`).
    private var rioSpeaking = false
    private var rioStoppedSpeakingAt: Date?

    private init() {}

    // MARK: Controls

    func toggleFromMenu() { apply(core.toggle(now: Date(), offReason: .menu)) }

    func start() { apply(core.turnOn(now: Date())) }

    func stop(_ reason: RioConversationCore.OffReason) { apply(core.turnOff(reason)) }

    /// Left Fn + Control + Option. While the live translator is on, the chord belongs to it:
    /// it stops translating and leaves conversation mode as it is.
    func toggleFromChord() {
        let translator = RioTranslatorMode.shared
        if translator.isOn {
            translator.stop(.chord)
            return
        }
        apply(core.toggle(now: Date(), offReason: .chord))
    }

    /// Dictation (Fn, Fn + Control) has the microphone; step aside until it is done.
    func setDictationActive(_ active: Bool) {
        core.setDictationActive(active, now: Date())
        reconcile()
    }

    /// Rio's own voice (or the translator's) is playing. Listening goes on so "Rio, stop" can
    /// interrupt him; everything else heard meanwhile, and just after, is dropped.
    func setRioSpeaking(_ speaking: Bool) {
        guard speaking != rioSpeaking else { return }
        rioSpeaking = speaking
        if !speaking { rioStoppedSpeakingAt = Date() }
    }

    /// Whether Rio (or the translator's voice) is talking, and how long ago he stopped.
    func rioSpeechState(now: Date) -> (isSpeaking: Bool, secondsSinceSpoke: TimeInterval?) {
        (rioSpeaking, rioStoppedSpeakingAt.map { now.timeIntervalSince($0) })
    }

    private func handle(command: String) {
        guard core.isOn, !core.isPaused else { return }
        let sinceSpoke = rioStoppedSpeakingAt.map { Date().timeIntervalSince($0) }
        guard RioConversationBargeIn.accepts(command, isRioSpeaking: rioSpeaking, secondsSinceRioSpoke: sinceSpoke) else { return }
        core.commandHeard(now: Date())
        onCommand?(command)
    }

    // MARK: State to the outside world

    private func apply(_ effects: [RioConversationCore.Effect]) {
        for effect in effects {
            if effect == .announceOn { statusMessage = nil }
            guard let cue = RioConversationCue.cue(for: effect) else { continue }
            playChime?(cue.chime)
            announce(cue)
        }
        reconcile()
    }

    /// Says the cue's line once the chord's silent cancel has finished (so the voice isn't
    /// suppressed as "Rio is recording"), and only if the mode hasn't flipped again meanwhile.
    private func announce(_ cue: RioConversationCue) {
        announceTask?.cancel()
        announceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(RioConversationCue.speechDelay * 1_000_000_000))
            guard !Task.isCancelled, let self, RioConversationCue.stillApplies(cue, isOn: self.core.isOn) else { return }
            RioVoice.shared.speak(cue.line)
        }
    }

    /// Makes the listener and the poll match the core. Safe to call at any time.
    private func reconcile() {
        isOn = core.isOn
        isPaused = core.isPaused
        isPausedForCall = core.isPausedForCall
        guard core.isOn else {
            stopListener()
            pollTask?.cancel()
            pollTask = nil
            debounce = MicUsageDebounce()
            return
        }
        startPollIfNeeded()
        if core.isPaused {
            listener?.pause()
        } else if listenerRunning {
            listener?.resume()
        } else {
            startListener()
        }
    }

    private func startListener() {
        guard !listenerStarting else { return }
        listenerStarting = true
        let listener = self.listener ?? WakeWordListener { [weak self] command in self?.handle(command: command) }
        listener.onStopped = { [weak self] message in self?.failToStart(message) }
        // A bare "Rio" and a thinking pause: a short "yes?" cue so the owner knows he's heard.
        // Not while Rio is talking, so his own voice saying the name can't trigger it.
        listener.onBareName = { [weak self] in
            guard let self, self.core.isOn, !self.core.isPaused, !self.rioSpeaking else { return }
            self.playSound?("Tink")
        }
        // His own voice (or the room) saying "Rio" while he talks, or just after, must not make
        // the next utterance a command without the name.
        listener.bareNameMayOpenWindow = { [weak self] in
            guard let self else { return false }
            let speech = self.rioSpeechState(now: Date())
            return WakeListenTiming.bareNameOpensWindow(
                isRioSpeaking: speech.isSpeaking, secondsSinceRioSpoke: speech.secondsSinceSpoke
            )
        }
        self.listener = listener
        Task { @MainActor [weak self] in
            let result = await listener.start()
            guard let self else { return }
            self.listenerStarting = false
            switch result {
            case .started:
                self.listenerRunning = true
                // Off, or paused, while it was starting up.
                self.reconcile()
            case .permissionDenied:
                self.failToStart("Rio needs Microphone and Speech Recognition permission to listen.")
            case .unavailable(let message):
                self.failToStart(message)
            }
        }
    }

    /// The listener couldn't start, or stopped on its own (the microphone went away). Settings
    /// shows why, and Rio says it, so a hands-free owner isn't left talking to nobody.
    private func failToStart(_ message: String) {
        listener?.stop()
        listener = nil
        listenerRunning = false
        statusMessage = message
        playSound?("Basso")
        apply(core.turnOff(.unavailable))
        RioVoice.shared.speak(message)
    }

    private func stopListener() {
        listener?.stop()
        listenerRunning = false
        // A start that is still in flight finishes, then `reconcile` sees it is off.
        if !listenerStarting { listener = nil }
    }

    // MARK: Poll: calls and the idle shut-off, about every 2 seconds, only while on

    private func startPollIfNeeded() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pollInterval)
                guard !Task.isCancelled, let self else { return }
                self.pollOnce()
            }
        }
    }

    private func pollOnce() {
        let busy = debounce.update(otherAppUsing: MicUsageMonitor.isOtherAppUsingMicrophone())
        let now = Date()
        core.setOtherAppUsingMic(busy, now: now)
        let effects = core.tick(now: now)
        if effects.isEmpty { reconcile() } else { apply(effects) }
    }
}
