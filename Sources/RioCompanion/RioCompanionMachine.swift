import CoreGraphics
import Foundation

/// How Rio shows up on screen: the small bear in the corner (default) or the old drop-down pill.
enum RioStyle: String, CaseIterable {
    case corner
    case pill

    static let defaultsKey = "rio_style"

    static func resolve(rawValue: String?) -> RioStyle {
        rawValue.flatMap(RioStyle.init(rawValue:)) ?? .corner
    }

    static var current: RioStyle {
        resolve(rawValue: UserDefaults.standard.string(forKey: defaultsKey))
    }
}

/// What the corner bear is doing. Pure value logic: the clock is always passed in, so every
/// transition and timeout is deterministic. The view only asks `mode(at:)` each frame.
struct RioCompanionMachine {
    enum Voice: Equatable {
        case none
        case starting
        case recording
        case transcribing
    }

    enum Mode: Equatable {
        case asleep
        /// The ~0.3 s stretch when dictation wakes him.
        case waking
        /// Awake and idle (blinking), before he dozes off again.
        case resting
        case talking
        case thinking
        /// Action key down: ears up, eyes wide.
        case alert
        case happy
        case shrug
        case moment
        case sprint
        case punch
        case returning
        /// Off doing a screen-wide trick; the corner is empty.
        case away
        /// Happy jump with sparkles.
        case celebrate
        /// Holding up the help card.
        case help
        /// The timer is ringing: the clock shakes and he bounces.
        case ringing
        /// Conversation mode is on: ears up, small sound waves, for as long as it stays on.
        case conversing
        /// Conversation mode is paused for a call (another app has the microphone).
        case conversingPaused
    }

    /// Conversation mode as the bear shows it. A pause while Rio dictates or talks isn't shown:
    /// his talking pose already covers that moment.
    enum Conversation: Equatable {
        case off
        case listening
        case pausedForCall

        init(isOn: Bool, isPausedForCall: Bool) {
            self = !isOn ? .off : (isPausedForCall ? .pausedForCall : .listening)
        }
    }

    /// Back to sleep this long after the last thing he did.
    static let idleTimeout: TimeInterval = 20
    static let wakeDuration: TimeInterval = 0.3
    static let celebrateDuration: TimeInterval = 2.2
    static let grumpyDuration: TimeInterval = 2.5

    private var voice: Voice = .none
    private var action: RioActionPhase = .idle
    private var moment: (value: TeddyMoment, expires: TimeInterval)?
    private var isAway = false
    private var run: (plan: RioDockRunPlan, start: TimeInterval)?
    private var lastEvent: TimeInterval = -.infinity
    private var wakeStart: TimeInterval?
    private var speaking = false
    private var timerRemaining: TimeInterval?
    private var timerRinging = false
    private var helpVisible = false
    private var celebrateStart: TimeInterval?
    private var grumpy = RioGrumpyDetector()
    private var grumpyUntil: TimeInterval = -.infinity
    private var conversation: Conversation = .off
    /// A macro or the meeting copilot is recording: a small red dot on the bear.
    private var isRecordingSomething = false

    init() {}

    // MARK: Events

    mutating func voiceChanged(_ newVoice: Voice, at now: TimeInterval) {
        let wasAsleep = mode(at: now) == .asleep
        if newVoice == .starting || newVoice == .recording {
            moment = nil
            if wasAsleep { wakeStart = now }
            if voice == .none { noteWake(at: now) }
        }
        voice = newVoice
        lastEvent = now
    }

    mutating func actionPhaseChanged(_ phase: RioActionPhase, at now: TimeInterval) {
        if phase == .listening {
            moment = nil
            if action != .listening { noteWake(at: now) }
        }
        action = phase
        lastEvent = now
    }

    mutating func showMoment(_ value: TeddyMoment, at now: TimeInterval) {
        moment = (value, now + value.seconds)
        lastEvent = now
    }

    mutating func trickChanged(isAway away: Bool, at now: TimeInterval) {
        isAway = away
        if away { moment = nil }
        lastEvent = now
    }

    mutating func speakingChanged(_ isSpeaking: Bool, at now: TimeInterval) {
        speaking = isSpeaking
        lastEvent = now
    }

    mutating func timerChanged(remaining: TimeInterval?, ringing: Bool, at now: TimeInterval) {
        timerRemaining = remaining
        timerRinging = ringing && remaining != nil
        lastEvent = now
    }

    mutating func helpChanged(_ isVisible: Bool, at now: TimeInterval) {
        helpVisible = isVisible
        lastEvent = now
    }

    mutating func conversationChanged(_ value: Conversation, at now: TimeInterval) {
        guard value != conversation else { return }
        conversation = value
        lastEvent = now
    }

    mutating func recordingChanged(macro: Bool, meeting: Bool, at now: TimeInterval) {
        isRecordingSomething = macro || meeting
    }

    mutating func celebrate(at now: TimeInterval) {
        celebrateStart = now
        lastEvent = now
    }

    private mutating func noteWake(at now: TimeInterval) {
        if grumpy.recordWake(at: now) { grumpyUntil = now + Self.grumpyDuration }
    }

    /// Starts the Dock run if the bear is free. Never waits: from sleep he is sprinting this instant.
    @discardableResult
    mutating func startRun(_ plan: RioDockRunPlan, at now: TimeInterval) -> Bool {
        guard canRun(at: now) else { return false }
        run = (plan, now)
        moment = nil
        lastEvent = now
        return true
    }

    // MARK: Queries

    func isGrumpy(at now: TimeInterval) -> Bool { now < grumpyUntil }

    /// The red recording dot: on whenever something records, asleep or awake, but not while the
    /// corner is empty.
    func showsRecordingBadge(at now: TimeInterval) -> Bool { isRecordingSomething && !isAway }

    /// "m:ss" for the alarm clock he holds, nil with no timer running.
    func timerText() -> String? { timerRemaining.map(RioTimerText.format) }

    func canRun(at now: TimeInterval) -> Bool {
        guard !isAway else { return false }
        if let run, now < runEnd(run) { return false }
        return true
    }

    func activeMoment(at now: TimeInterval) -> TeddyMoment? {
        guard let moment, now < moment.expires else { return nil }
        return moment.value
    }

    /// Text for the speech card of an action ("Opening Google Chrome").
    func bubbleText(at now: TimeInterval) -> String? {
        guard !isAway else { return nil }
        switch action {
        case let .working(text), let .succeeded(text), let .failed(text):
            return text.isEmpty ? nil : text
        case .idle, .listening:
            return nil
        }
    }

    func mode(at now: TimeInterval) -> Mode {
        if isAway { return .away }
        if let run, now >= run.start {
            let elapsed = now - run.start
            if elapsed < run.plan.sprintDuration { return .sprint }
            if elapsed < run.plan.totalDuration { return .punch }
            if elapsed < run.plan.totalDuration + RioDockRunPlan.returnDuration { return .returning }
        }
        if timerRinging { return .ringing }
        if let celebrateStart, now >= celebrateStart, now - celebrateStart < Self.celebrateDuration { return .celebrate }
        if activeMoment(at: now) != nil { return .moment }
        if helpVisible { return .help }
        switch action {
        case .listening: return .alert
        case .working: return .thinking
        case .succeeded: return .happy
        case .failed: return .shrug
        case .idle: break
        }
        if let wakeStart, now - wakeStart < Self.wakeDuration, voice == .starting || voice == .recording {
            return .waking
        }
        switch voice {
        case .starting, .recording: return .talking
        case .transcribing: return .thinking
        case .none: break
        }
        if speaking { return .talking }
        switch conversation {
        case .listening: return .conversing
        case .pausedForCall: return .conversingPaused
        case .off: break
        }
        if timerRemaining != nil { return .resting }
        return now - idleSince(at: now) < Self.idleTimeout ? .resting : .asleep
    }

    /// True while the view needs smooth frames (anything but sleeping or resting).
    func isLively(at now: TimeInterval) -> Bool {
        switch mode(at: now) {
        case .asleep, .resting, .away, .conversingPaused: return false
        default: return true
        }
    }

    // MARK: Private

    private func runEnd(_ run: (plan: RioDockRunPlan, start: TimeInterval)) -> TimeInterval {
        run.start + run.plan.totalDuration + RioDockRunPlan.returnDuration
    }

    /// The moment he last did something; the 20 s of rest count from here.
    private func idleSince(at now: TimeInterval) -> TimeInterval {
        var latest = lastEvent
        if let moment { latest = max(latest, moment.expires) }
        if let run { latest = max(latest, runEnd(run)) }
        if let celebrateStart { latest = max(latest, celebrateStart + Self.celebrateDuration) }
        return latest
    }
}
