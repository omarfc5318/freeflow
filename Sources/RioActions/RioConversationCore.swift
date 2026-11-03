import Foundation

/// Pure state machine for conversation mode (the always-listening "Rio ..." mode).
/// No AppKit, no timers, no audio: `RioConversationMode` feeds it events and acts on the
/// result, and tests drive it with fixed dates.
///
/// Rules:
/// - On and off come from a three-finger tap, the menu item, "Rio, stop listening", the
///   5-minute idle shut-off, or the listener failing to start.
/// - While on, it is paused (microphone released) whenever another app is using the
///   microphone (a call) or Rio itself is dictating (Fn, Fn + Control). It resumes by itself.
/// - The idle clock counts only while actively listening: a long call never trips it, and it
///   restarts from the moment listening resumes.
struct RioConversationCore: Equatable {
    /// Five minutes without a command turns conversation mode off.
    static let idleTimeout: TimeInterval = 300

    enum OffReason: Equatable {
        case tap, menu, stopListening, idleTimeout, unavailable, settings
    }

    enum Effect: Equatable {
        case announceOn
        case announceOff(OffReason)
    }

    private(set) var isOn = false
    private var otherAppUsingMic = false
    private var dictationActive = false
    /// Start of the current idle window; nil whenever it is not running.
    private var idleSince: Date?

    var isPaused: Bool { isOn && (otherAppUsingMic || dictationActive) }

    /// When the idle shut-off fires, or nil if it is not counting (off, or paused).
    var idleDeadline: Date? {
        guard isOn, !isPaused, let idleSince else { return nil }
        return idleSince.addingTimeInterval(Self.idleTimeout)
    }

    mutating func turnOn(now: Date) -> [Effect] {
        guard !isOn else { return [] }
        isOn = true
        idleSince = isPaused ? nil : now
        return [.announceOn]
    }

    mutating func turnOff(_ reason: OffReason) -> [Effect] {
        guard isOn else { return [] }
        isOn = false
        idleSince = nil
        return [.announceOff(reason)]
    }

    mutating func toggle(now: Date, offReason: OffReason) -> [Effect] {
        isOn ? turnOff(offReason) : turnOn(now: now)
    }

    mutating func setOtherAppUsingMic(_ value: Bool, now: Date) {
        guard otherAppUsingMic != value else { return }
        let wasPaused = isPaused
        otherAppUsingMic = value
        syncIdleClock(wasPaused: wasPaused, now: now)
    }

    mutating func setDictationActive(_ value: Bool, now: Date) {
        guard dictationActive != value else { return }
        let wasPaused = isPaused
        dictationActive = value
        syncIdleClock(wasPaused: wasPaused, now: now)
    }

    /// A command was heard: the idle window starts over.
    mutating func commandHeard(now: Date) {
        guard isOn, !isPaused else { return }
        idleSince = now
    }

    /// Call periodically; turns the mode off once the idle window has run out.
    mutating func tick(now: Date) -> [Effect] {
        guard let deadline = idleDeadline, now >= deadline else { return [] }
        return turnOff(.idleTimeout)
    }

    private mutating func syncIdleClock(wasPaused: Bool, now: Date) {
        guard isOn else { return }
        if isPaused {
            idleSince = nil
        } else if wasPaused {
            idleSince = now
        }
    }
}

/// Recognises the spoken "stop listening" command without running the whole action pipeline.
enum RioConversationCommands {
    private static let parser = RioActionParser(installedApps: [])

    static func isStopListening(_ transcript: String) -> Bool {
        let text = RioActionTranscript.stripName(from: transcript)
        guard !text.isEmpty, case .actions(let actions) = parser.parse(text) else { return false }
        return actions == [.stopListening]
    }
}
