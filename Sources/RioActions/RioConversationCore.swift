import Foundation

/// Pure state machine for conversation mode (the always-listening "Rio ..." mode).
/// No AppKit, no timers, no audio: `RioConversationMode` feeds it events and acts on the
/// result, and tests drive it with fixed dates.
///
/// Rules:
/// - On and off come from the Fn + Control + Option chord, the menu item, "Rio, stop listening", the
///   5-minute idle shut-off, or the listener failing to start.
/// - While on, it is paused (microphone released) whenever another app is using the
///   microphone (a call) or Rio itself is dictating (Fn, Fn + Control). It resumes by itself.
/// - The idle clock counts only while actively listening: a long call never trips it, and it
///   restarts from the moment listening resumes.
struct RioConversationCore: Equatable {
    /// Five minutes without a command turns conversation mode off.
    static let idleTimeout: TimeInterval = 300

    enum OffReason: Equatable {
        case chord, menu, stopListening, idleTimeout, unavailable, settings
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
    /// Paused because another app has the microphone (a call), not just while Rio dictates or
    /// talks for a moment. The bear and the menu bar show this one.
    var isPausedForCall: Bool { isOn && otherAppUsingMic }

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

/// What turning conversation mode on or off sounds like: its own chime at once, then Rio's line a
/// moment later. The chord first cancels the Fn / Fn + Control session it started, silently; the
/// delay lets that finish so the line isn't dropped as "Rio is recording".
struct RioConversationCue: Equatable {
    static let speechDelay: TimeInterval = 0.3

    let chime: RioChime
    let line: String
    /// The state the line announces; it is skipped if the mode has flipped again meanwhile.
    let announcesOn: Bool

    static func cue(for effect: RioConversationCore.Effect) -> RioConversationCue? {
        switch effect {
        case .announceOn:
            return RioConversationCue(chime: .conversationOn, line: "I'm listening", announcesOn: true)
        case .announceOff(.unavailable):
            // It never started: the error sound has played and Settings says why.
            return nil
        case .announceOff:
            return RioConversationCue(chime: .conversationOff, line: "Going to sleep", announcesOn: false)
        }
    }

    static func stillApplies(_ cue: RioConversationCue, isOn: Bool) -> Bool { cue.announcesOn == isOn }
}

/// Conversation mode's own two-note chime, made on the fly as a small WAV (no sound files):
/// rising for on, falling for off, so it never sounds like dictation's Tink and Pop.
enum RioChime: Equatable {
    case conversationOn
    case conversationOff

    static let sampleRate = 44_100
    /// Each note's slot; the last note rings on for `tail`.
    static let noteDuration: TimeInterval = 0.11
    static let tail: TimeInterval = 0.14
    private static let peak = 0.42

    /// Hz: E5 then B5 (a bright fifth up), and back down for off.
    var notes: [Double] {
        switch self {
        case .conversationOn: return [659.25, 987.77]
        case .conversationOff: return [987.77, 659.25]
        }
    }

    /// 16-bit mono PCM WAV: each note a soft bell (fundamental plus a quiet octave) with a quick
    /// attack and an exponential decay.
    func wavData() -> Data {
        let rate = Double(Self.sampleRate)
        let slot = Int(Self.noteDuration * rate)
        let total = slot * notes.count + Int(Self.tail * rate)
        var samples = [Double](repeating: 0, count: total)
        for (index, frequency) in notes.enumerated() {
            let start = index * slot
            let length = index == notes.count - 1 ? total - start : slot + Int(0.03 * rate)
            for n in 0..<length where start + n < total {
                let t = Double(n) / rate
                let attack = min(1, t / 0.006)
                let decay = exp(-t / (index == notes.count - 1 ? 0.09 : 0.06))
                let tone = sin(2 * .pi * frequency * t) + 0.18 * sin(4 * .pi * frequency * t)
                samples[start + n] += tone * attack * decay
            }
        }
        let loudest = samples.map(abs).max() ?? 1
        let scale = loudest > 0 ? Self.peak * Double(Int16.max) / loudest : 0
        var pcm = Data(capacity: total * 2)
        for sample in samples {
            let value = Int16(max(-32_767, min(32_767, (sample * scale).rounded())))
            withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
        }
        return Self.wavHeader(dataBytes: pcm.count) + pcm
    }

    private static func wavHeader(dataBytes: Int) -> Data {
        var header = Data()
        func append(_ text: String) { header.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        append("RIFF"); append32(UInt32(36 + dataBytes)); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(UInt32(sampleRate)); append32(UInt32(sampleRate * 2)); append16(2); append16(16)
        append("data"); append32(UInt32(dataBytes))
        return header
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

extension RioConversationCommands {
    private static let bareStopPhrases: Set<String> = [
        "stop", "stop it", "stop that", "stop please", "please stop", "cancel", "cancel that"
    ]

    /// "Rio, stop": ends whatever Rio is doing (a running task, the translator, his own voice).
    /// Only the bare word counts, so "stop the timer" and "stop music" still reach the parser.
    static func isBareStop(_ transcript: String) -> Bool {
        let text = RioActionTranscript.stripName(from: transcript).lowercased()
        let letters = text.unicodeScalars.map { CharacterSet.letters.contains($0) ? Character($0) : " " }
        let normalized = String(letters).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return bareStopPhrases.contains(normalized)
    }

    /// True only for a spoken decline. A spoken "yes" never approves anything.
    static func declinesBySpeech(_ transcript: String) -> Bool { spokenAnswer(transcript) == .no }

    /// A spoken answer to a conversation confirmation: "Rio, yes" / "Rio, no".
    enum SpokenAnswer: Equatable { case yes, no }

    static func spokenAnswer(_ transcript: String) -> SpokenAnswer? {
        let text = RioActionTranscript.stripName(from: transcript).lowercased()
        let letters = text.unicodeScalars.map { CharacterSet.letters.contains($0) ? Character($0) : " " }
        let normalized = String(letters).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        switch normalized {
        case "yes", "yes please", "yeah", "yep", "confirm", "do it", "go ahead", "yes do it": return .yes
        case "no", "nope", "cancel", "don't", "dont", "no thanks", "never mind", "nevermind": return .no
        default: return nil
        }
    }
}

/// Which key events may answer one of Rio's own confirmation panels. A press Rio posted itself
/// (the "Rio, press enter" command, a task's keystrokes) must never confirm a prompt that Rio
/// raised, and a Return that lands the instant a panel appears is a stray one.
enum RioConfirmationKeyPolicy {
    static let returnIgnoreSeconds: TimeInterval = 0.3
    /// How long after Rio posts a synthetic key the panel distrusts the next real-looking press.
    static let syntheticPostWindowSeconds: TimeInterval = 0.5

    static let confirmKeyCodes: Set<UInt16> = [36, 76]
    static let cancelKeyCode: UInt16 = 53

    static func accepts(
        keyCode: UInt16,
        eventSourcePID: Int64,
        ownPID: Int64,
        secondsSincePanelShown: TimeInterval,
        secondsSinceOwnSyntheticPost: TimeInterval
    ) -> Bool {
        guard confirmKeyCodes.contains(keyCode) || keyCode == cancelKeyCode else { return false }
        if eventSourcePID == ownPID { return false }
        if secondsSinceOwnSyntheticPost < syntheticPostWindowSeconds { return false }
        if confirmKeyCodes.contains(keyCode), secondsSincePanelShown < returnIgnoreSeconds { return false }
        return true
    }
}
