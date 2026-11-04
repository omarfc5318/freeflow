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

    /// A chain that also turns the mic off ("stop the music and go to sleep", "stop listening and
    /// lock the screen"): conversation mode goes off once the other steps ran. Only an exact
    /// "stop listening" (`isStopListening`) is handled before the pipeline.
    static func includesStopListening(_ actions: [RioAction]) -> Bool {
        actions.contains(.stopListening)
    }
}

extension RioConversationCommands {
    /// What a bare stop asks for. Both end whatever is running or ringing. When nothing is,
    /// `.stop` ("stop", "shut up", "بس") goes on to the parser's own stop (which pauses media),
    /// while `.abort` ("cancel", "wait", "forget it") does nothing more.
    enum BareStop: Equatable { case stop, abort }

    private static let stopPhrases: Set<String> = [
        "stop", "stop it", "stop that", "stop this", "shut up", "stop talking", "be quiet", "quiet", "enough", "thats enough", "that is enough",
        "hush", "silence", "stop now",
        // Arabic: enough / that's it / stop / be quiet.
        "بس", "خلاص", "وقف", "اوقف", "توقف", "قف", "اسكت", "كفاية", "كفايه", "كفى"
    ]
    private static let abortPhrases: Set<String> = [
        "cancel", "cancel that", "cancel it", "cancel this", "abort", "abort it", "abort that", "wait", "hold on", "hang on", "forget it", "forget about it", "scratch that", "never mind", "nevermind"
    ]
    /// Words that may surround a stop without changing it: "okay okay stop", "no stop please".
    private static let stopFillers: Set<String> = [
        "okay", "ok", "no", "please", "now", "just", "oh", "hey", "right", "um", "uh", "rio", "لا", "يا", "ريو"
    ]
    private static let declineWords: Set<String> = ["no", "لا", "لأ"]

    /// "Rio, stop": ends whatever Rio is doing (a ringing timer, a running task, the translator,
    /// his own voice). Only stop words count, so "stop the timer" and "stop music" still reach the
    /// parser. Repeated and panicked forms ("stop stop stop", "no no no", "okay okay stop") count.
    static func bareStop(_ transcript: String) -> BareStop? {
        let words = commandWords(transcript)
        guard !words.isEmpty else { return nil }
        if words.count >= 2, words.allSatisfy(declineWords.contains) { return .abort }
        var foundStop = false
        guard segments(words, into: [stopPhrases, abortPhrases], fillers: stopFillers, found: { phrase in
            if stopPhrases.contains(phrase) { foundStop = true }
        }) else { return nil }
        return foundStop ? .stop : .abort
    }

    static func isBareStop(_ transcript: String) -> Bool { bareStop(transcript) != nil }

    /// True only for a spoken decline. A spoken "yes" never approves anything.
    static func declinesBySpeech(_ transcript: String) -> Bool { spokenAnswer(transcript) == .no }

    /// A spoken answer to a conversation confirmation: "Rio, yes" / "Rio, no".
    enum SpokenAnswer: Equatable { case yes, no }

    private static let yesAnswers: Set<String> = [
        "yes", "yes please", "yeah", "yep", "yup", "sure", "confirm", "do it", "go ahead", "yes do it",
        "yeah do it", "yep do it", "yes go ahead", "نعم", "اي", "ايوه", "ايوا", "اكيد",
        // Gulf: yes / yeah / okay.
        "ايه", "إيه", "إي", "أيوه", "أيوا", "تمام", "يب"
    ]
    private static let noAnswers: Set<String> = [
        "no", "nope", "nah", "cancel", "dont", "do not", "no thanks", "no thank you", "never mind", "nevermind",
        "لا", "لأ", "لا شكرا"
    ]

    static func spokenAnswer(_ transcript: String) -> SpokenAnswer? {
        let text = collapsingRepeats(commandWords(transcript)).joined(separator: " ")
        if yesAnswers.contains(text) { return .yes }
        if noAnswers.contains(text) { return .no }
        return nil
    }

    private static let thanksPhrases: Set<String> = [
        "thank you", "thanks", "thank u", "thx", "cheers", "شكرا", "شكراً", "مشكور", "مشكورة", "يعطيك العافيه", "يعطيك العافية",
        // Gulf: bless you / you didn't fall short / God give you strength / a thousand strengths.
        "تسلم", "تسلم يدك", "ما قصرت", "ماقصرت", "يعطيك الف عافيه", "يعطيك الف عافية", "يعطيك ألف عافية", "يعطيك ألف عافيه",
    ]
    private static let thanksFillers: Set<String> = [
        "okay", "ok", "so", "much", "very", "a", "lot", "rio", "man", "bro", "buddy", "again", "جزيلا", "ريو", "يا", "الله", "والله",
    ]

    /// "Rio, thank you": a short reply, never an action and never a model call.
    static func isThanks(_ transcript: String) -> Bool {
        let words = commandWords(transcript)
        guard !words.isEmpty else { return false }
        return segments(words, into: [thanksPhrases], fillers: thanksFillers, found: { _ in })
    }

    static let welcomeLine = "You're welcome"
    /// The Arabic answers to thanks: "may God keep you well" to "يعطيك العافية", "you're welcome"
    /// to the rest.
    static let arabicWelcomeLine = "العفو"
    static let arabicWellnessLine = "الله يعافيك"

    /// Rio's answer to a thanks, in the language it was said in.
    static func thanksReply(_ transcript: String) -> String {
        let words = commandWords(transcript)
        guard words.contains(where: { $0.unicodeScalars.contains(where: RioArabicText.isArabicScript) }) else { return welcomeLine }
        return words.contains(where: { $0.contains("عافي") }) ? arabicWellnessLine : arabicWelcomeLine
    }
    static let nothingToConfirmLine = "Nothing to confirm"

    static let hereLine = "I'm here"

    /// Greetings and presence checks, each with Rio's answer. Only a whole utterance made of these
    /// counts: "hi, open Chrome" still runs the command.
    private static let greetingReplies: [String: String] = [
        "hi": "Hey", "hey": "Hey", "hello": "Hey", "hiya": "Hey", "howdy": "Hey", "hi there": "Hey", "hey there": "Hey",
        "hello there": "Hey", "good morning": "Good morning", "morning": "Good morning",
        "good afternoon": "Good afternoon", "good evening": "Good evening",
        "how are you": "Doing great", "how are you doing": "Doing great", "how is it going": "Doing great",
        "hows it going": "Doing great", "whats your name": "I'm Rio", "what is your name": "I'm Rio",
        "are you there": hereLine, "you there": hereLine, "can you hear me": hereLine, "do you hear me": hereLine,
        "hear me": hereLine, "are you listening": hereLine, "you listening": hereLine,
        // Arabic: peace be upon you / hi / good morning / good evening / how are you / your name.
        "السلام عليكم": "وعليكم السلام", "سلام عليكم": "وعليكم السلام", "السلام": "وعليكم السلام",
        "هلا": "هلا والله", "هلا والله": "هلا والله", "هلا هلا": "هلا والله", "اهلا": "هلا والله", "أهلا": "هلا والله",
        "مرحبا": "هلا والله", "صباح الخير": "صباح النور", "مساء الخير": "مساء النور",
        "كيفك": "بخير، الحمد لله", "كيف حالك": "بخير، الحمد لله", "شلونك": "بخير، الحمد لله", "كيف الحال": "بخير، الحمد لله",
        "وش اسمك": "أنا ريو", "شو اسمك": "أنا ريو", "ايش اسمك": "أنا ريو", "ما اسمك": "أنا ريو",
        "وش إسمك": "أنا ريو", "شو إسمك": "أنا ريو", "ايش إسمك": "أنا ريو", "ما إسمك": "أنا ريو",
        "تسمعني": hereLine, "انت هنا": hereLine,
    ]
    private static let greetingPhrases = Set(greetingReplies.keys)
    private static let greetingFillers: Set<String> = [
        "rio", "ريو", "يا", "buddy", "man", "bro", "my", "friend", "oh", "so", "and", "ورحمة", "الله", "وبركاته",
    ]

    /// Rio's answer when the whole utterance is a greeting or "are you there", else nil.
    static func greetingReply(_ transcript: String) -> String? {
        let words = collapsingRepeats(commandWords(transcript))
        guard !words.isEmpty else { return nil }
        var first: String?
        guard segments(words, into: [greetingPhrases], fillers: greetingFillers, maxPhraseWords: 4, found: { phrase in
            if first == nil { first = phrase }
        }), let first else { return nil }
        return greetingReplies[first]
    }

    /// A line Rio answers by himself, with no action and no model call: "thanks", a greeting or
    /// "are you there", or a yes or no when no confirmation is open. Stop words ("cancel",
    /// "no no no") are not answered here.
    static func quickReply(_ transcript: String, isConfirmationShowing: Bool) -> String? {
        if isThanks(transcript) { return thanksReply(transcript) }
        if let greeting = greetingReply(transcript) { return greeting }
        if !isConfirmationShowing, spokenAnswer(transcript) != nil, !isBareStop(transcript) { return nothingToConfirmLine }
        return nil
    }

    /// The command's words: the name ("Rio", "hey Rio", "ريو", "يا ريو") dropped, lowercased,
    /// apostrophes and Arabic diacritics removed, everything but letters treated as a space.
    static func commandWords(_ transcript: String) -> [String] {
        let text = RioActionTranscript.stripName(from: transcript).lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            // Arabic short vowels and the tatweel are decoration: "وَقِّف" is "وقف".
            if CharacterSet.nonBaseCharacters.contains(scalar) || scalar == "\u{0640}" { continue }
            kept.append(CharacterSet.letters.contains(scalar) ? scalar : " ")
        }
        var words = String(kept).split(whereSeparator: \.isWhitespace).map(String.init)
        // The Arabic name, in case speech-to-text kept it in Arabic script.
        if words.first == "يا", words.count > 1, arabicNames.contains(words[1]) { words.removeFirst(2) }
        if let first = words.first, arabicNames.contains(first) { words.removeFirst() }
        return words
    }

    private static let arabicNames: Set<String> = ["ريو", "ريوو", "ريّو"]

    /// "no no no" -> "no"; "stop stop" -> "stop".
    static func collapsingRepeats(_ words: [String]) -> [String] {
        words.reduce(into: []) { result, word in if result.last != word { result.append(word) } }
    }

    /// True when `words` can be split, start to end, into phrases from `phraseSets` and filler
    /// words, with at least one phrase. `found` sees every phrase used.
    private static func segments(
        _ words: [String], into phraseSets: [Set<String>], fillers: Set<String>, maxPhraseWords: Int = 3,
        found: (String) -> Void
    ) -> Bool {
        // best[i]: the phrases used to cover words[i...], nil when they can't be covered.
        var best = [[String]?](repeating: nil, count: words.count + 1)
        best[words.count] = []
        for start in stride(from: words.count - 1, through: 0, by: -1) {
            if fillers.contains(words[start]), let rest = best[start + 1] {
                best[start] = rest
            }
            for length in 1...maxPhraseWords where start + length <= words.count {
                let phrase = words[start..<start + length].joined(separator: " ")
                guard phraseSets.contains(where: { $0.contains(phrase) }), let rest = best[start + length] else { continue }
                // Prefer a cover that uses a phrase over one made only of fillers.
                if best[start] == nil || best[start]?.isEmpty == true { best[start] = [phrase] + rest }
            }
        }
        guard let phrases = best[0], !phrases.isEmpty else { return false }
        phrases.forEach(found)
        return true
    }
}

/// While Rio is talking, conversation mode keeps listening so he can be interrupted, but only a
/// bare stop or an exact "stop listening" is taken: his own voice (a news read-out, a message
/// read aloud) can never run anything, and those two only ever stop him or turn the mic off.
/// The window runs on past the end of his speech, because a phrase he said is only delivered
/// once the listener has heard a moment of silence after it.
enum RioConversationBargeIn {
    static let echoTailSeconds: TimeInterval = 2.5

    static func accepts(_ command: String, isRioSpeaking: Bool, secondsSinceRioSpoke: TimeInterval?) -> Bool {
        let inEchoWindow = isRioSpeaking || (secondsSinceRioSpoke.map { $0 < echoTailSeconds } ?? false)
        return !inEchoWindow || RioConversationCommands.isBareStop(command) || RioConversationCommands.isStopListening(command)
    }
}

/// One conversation-mode command heard while Rio was still busy with the last one: it runs once
/// he is free, if that is soon. Only one waits (the newest wins), and it expires quickly, so a
/// command never runs long after it was said. In memory only. Pure.
struct RioConversationPending: Equatable {
    static let lifetime: TimeInterval = 8
    static let busyLine = "One sec, still on the last one"

    private(set) var command: String?
    private var heardAt: Date?

    var isEmpty: Bool { command == nil }

    mutating func offer(_ command: String, now: Date) {
        self.command = command
        heardAt = now
    }

    enum Next: Equatable { case wait, run(String), expired, none }

    /// What to do now: run the waiting command once Rio is free, or drop it once it is too old.
    mutating func next(now: Date, isBusy: Bool) -> Next {
        guard let command, let heardAt else { return .none }
        if now.timeIntervalSince(heardAt) > Self.lifetime || now < heardAt {
            clear()
            return .expired
        }
        guard !isBusy else { return .wait }
        clear()
        return .run(command)
    }

    mutating func clear() {
        command = nil
        heardAt = nil
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
