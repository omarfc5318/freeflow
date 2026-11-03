import AppKit
import Combine
import Foundation

/// Conversation mode: Rio keeps the microphone open and acts on anything said after "Rio".
/// Toggled by a three-finger trackpad tap, the menu bar item, or Settings. It turns itself off
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
    /// Why it couldn't start, or why the tap gesture is unavailable; shown in Settings.
    @Published private(set) var statusMessage: String?

    /// Receives the text after "Rio" for every command heard. AppState runs it through the
    /// same action pipeline as the action key.
    var onCommand: (@MainActor (String) -> Void)?
    /// Plays a short system sound by name (AppState routes it through the sound settings).
    var playSound: (@MainActor (String) -> Void)?

    private static let pollInterval: UInt64 = 2_000_000_000

    private var core = RioConversationCore()
    private var debounce = MicUsageDebounce()
    private var listener: WakeWordListener?
    private var listenerRunning = false
    private var listenerStarting = false
    private var tapMonitor: ThreeFingerTapMonitor?
    private var pollTask: Task<Void, Never>?

    private init() {}

    // MARK: Controls

    func toggleFromMenu() { apply(core.toggle(now: Date(), offReason: .menu)) }

    func start() { apply(core.turnOn(now: Date())) }

    func stop(_ reason: RioConversationCore.OffReason) { apply(core.turnOff(reason)) }

    /// Enables or disables the three-finger tap that toggles conversation mode.
    func setTapToggleEnabled(_ enabled: Bool) {
        if enabled {
            if tapMonitor == nil {
                tapMonitor = ThreeFingerTapMonitor { [weak self] in self?.handleTap() }
            }
            if tapMonitor?.start() == true {
                if statusMessage == Self.tapUnavailableMessage { statusMessage = nil }
            } else {
                statusMessage = Self.tapUnavailableMessage
            }
        } else {
            tapMonitor?.stop()
            if statusMessage == Self.tapUnavailableMessage { statusMessage = nil }
        }
    }

    /// Dictation (Fn, Fn + Control) has the microphone; step aside until it is done.
    func setDictationActive(_ active: Bool) {
        core.setDictationActive(active, now: Date())
        reconcile()
    }

    private static let tapUnavailableMessage = "The three-finger tap isn't available on this Mac."

    private func handleTap() {
        apply(core.toggle(now: Date(), offReason: .tap))
    }

    private func handle(command: String) {
        guard core.isOn, !core.isPaused else { return }
        core.commandHeard(now: Date())
        onCommand?(command)
    }

    // MARK: State to the outside world

    private func apply(_ effects: [RioConversationCore.Effect]) {
        for effect in effects {
            switch effect {
            case .announceOn:
                statusMessage = nil
                playSound?("Tink")
                RioVoice.shared.speak("I'm listening")
            case .announceOff(let reason):
                if reason != .unavailable {
                    playSound?("Pop")
                    RioVoice.shared.speak("Going to sleep")
                }
            }
        }
        reconcile()
    }

    /// Makes the listener and the poll match the core. Safe to call at any time.
    private func reconcile() {
        isOn = core.isOn
        isPaused = core.isPaused
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

    private func failToStart(_ message: String) {
        listener?.stop()
        listener = nil
        listenerRunning = false
        statusMessage = message
        playSound?("Basso")
        apply(core.turnOff(.unavailable))
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
