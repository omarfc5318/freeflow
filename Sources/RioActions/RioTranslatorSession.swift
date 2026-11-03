import Foundation

/// Why the translator's microphone is closed for a moment.
enum RioTranslatorPauseReason: Hashable {
    /// Rio (or the translator's own voice) is speaking: never listen to ourselves.
    case rioSpeaking
    /// Dictation or the action key has the microphone.
    case dictation
    /// Conversation mode is handling a command.
    case conversationCommand
    /// A command was just heard; its answer is about to be spoken.
    case commandWindow
}

/// The translator's on/off, pause and idle rules. Pure: the caller supplies `now`.
/// Ten minutes without anyone speaking (paused time doesn't count) turns it off.
struct RioTranslatorSession: Equatable {
    static let idleLimit: TimeInterval = 600

    private(set) var isActive = false
    private(set) var pauses: Set<RioTranslatorPauseReason> = []
    private var idleSince: Date?

    var isPaused: Bool { !pauses.isEmpty }

    func starting(now: Date) -> RioTranslatorSession {
        RioTranslatorSession(isActive: true, pauses: [], idleSince: now)
    }

    func stopping() -> RioTranslatorSession { RioTranslatorSession() }

    func speechHeard(now: Date) -> RioTranslatorSession {
        guard isActive else { return self }
        var next = self
        next.idleSince = now
        return next
    }

    func setting(_ reason: RioTranslatorPauseReason, active: Bool, now: Date) -> RioTranslatorSession {
        guard isActive else { return self }
        var next = self
        if active { next.pauses.insert(reason) } else { next.pauses.remove(reason) }
        // Time spent paused isn't silence: the idle clock restarts when the last pause clears.
        if isPaused && !next.isPaused { next.idleSince = now }
        return next
    }

    func shouldAutoStop(now: Date) -> Bool {
        guard isActive, !isPaused, let idleSince else { return false }
        return now.timeIntervalSince(idleSince) >= Self.idleLimit
    }

    init() {}

    private init(isActive: Bool, pauses: Set<RioTranslatorPauseReason>, idleSince: Date?) {
        self.isActive = isActive
        self.pauses = pauses
        self.idleSince = idleSince
    }
}
