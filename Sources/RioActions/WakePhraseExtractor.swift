import Foundation

/// Pulls the spoken command out of what the recognizer heard: only the words after "Rio"
/// (or "hey Rio", "Ryo", "Reo" ...). Pure text logic. Speech without the name yields nil, so
/// the listener can drop it without ever keeping it.
///
/// The name must START the utterance (a greeting or filler may come first) or follow the end of
/// a sentence. "I told Rio to open Chrome" and a video that mentions Rio mid-sentence are not
/// commands. The listener ends an utterance at each pause, so "start of the transcript" means
/// "after a pause".
enum WakePhraseExtractor {
    typealias Word = (text: String, range: Range<String.Index>)

    /// The command after the first name in `transcript`, or nil when there is no name or
    /// nothing after it yet ("Rio" alone, "hey Rio"). Keeps the speaker's wording, casing and
    /// trailing punctuation; strips the name, a greeting before it and punctuation after it.
    static func command(in transcript: String) -> String? {
        let words = wordRanges(in: transcript)
        guard let first = words.indices.first(where: { wakesAt($0, in: words, text: transcript) }) else { return nil }
        var last = first
        while last + 1 < words.count, isName(words[last + 1].text) { last += 1 }
        let rest = transcript[words[last].range.upperBound...]
        let trimmed = rest
            .drop { !($0.isLetter || $0.isNumber) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains { $0.isLetter || $0.isNumber } ? trimmed : nil
    }

    /// One recognized word with its timing (seconds from the start of the recognition task).
    struct TimedWord: Equatable {
        let text: String
        let start: TimeInterval
        let duration: TimeInterval
    }

    /// A pause this long before the name makes it the start of a new utterance even when the
    /// recognizer ran the speech together ("Oh my god [pause] Rio, help").
    static let gapBeforeName: TimeInterval = 0.5

    /// The transcript rebuilt from timed words with a line break at each pause of
    /// `gapBeforeName` or more, so the name after a pause counts as a fresh start. Words without
    /// timing (all zero) give the plain transcript, so nothing new is accepted.
    static func transcript(from words: [TimedWord]) -> String {
        var out = ""
        for (index, word) in words.enumerated() {
            if index > 0 {
                let previous = words[index - 1]
                let gap = word.start - (previous.start + previous.duration)
                out += gap >= gapBeforeName && word.start > 0 ? "\n" : " "
            }
            out += word.text
        }
        return out
    }

    /// `command(in:)` for timed words: the name may also follow a pause mid-transcript. The
    /// command keeps single spaces where the pauses were.
    static func command(in words: [TimedWord]) -> String? {
        command(in: transcript(from: words)).map { $0.replacingOccurrences(of: "\n", with: " ") }
    }

    /// True when the utterance is just the name ("Rio", "hey Rio"), so the listener can wait a
    /// little longer for the command that follows a thinking pause.
    static func isBareName(_ transcript: String) -> Bool {
        let words = wordRanges(in: transcript)
        guard let first = words.indices.first(where: { isName(words[$0].text) && startsUtterance(at: $0, in: words, text: transcript) })
        else { return false }
        return words[first...].allSatisfy { isName($0.text) }
    }

    /// Words that may come before the name without it being mid-sentence.
    private static let leadIns: Set<String> = [
        "hey", "hi", "hello", "yo", "yoo", "ok", "okay", "uh", "um", "so", "oh", "alright", "right", "well"
    ]

    /// Words after "Rio" that make it a place, not the name: "Rio de Janeiro", "Rio Grande",
    /// "Rio Tinto". ("do" is left out: "Rio do this" is a command.)
    private static let placeContinuations: Set<String> = [
        "de", "da", "dos", "das", "del", "grande", "rancho", "tinto", "negro", "verde", "bravo", "hondo",
    ]

    /// Mishearings of the name that are also ordinary words or names ("Ria", "Rhea", "Rio's"):
    /// they wake Rio only at the very start of the utterance and only before a command word.
    private static let looseNames: Set<String> = ["ria", "rhea", "rios", "rio's", "rio\u{2019}s"]
    private static let commandStarters: Set<String> = [
        "open", "launch", "close", "quit", "play", "pause", "set", "turn", "start", "stop", "show", "hide",
        "put", "move", "switch", "search", "google", "go", "mute", "unmute", "volume", "take", "remind",
        "remember", "undo", "help", "text", "message", "send", "type", "write", "reply", "call", "find",
        "make", "tell", "read", "answer", "translate", "lock", "skip", "next", "what", "what's", "whats",
        "what\u{2019}s", "how", "who", "where", "when", "can", "could", "would", "please", "do", "say",
        "give", "forget", "minimize", "maximize", "empty", "check", "add", "new", "create",
    ]

    /// True when the word at `index` is the name and starts a command there.
    private static func wakesAt(_ index: Int, in words: [Word], text: String) -> Bool {
        let lowered = words[index].text.lowercased()
        let next = index + 1 < words.count ? words[index + 1].text.lowercased() : nil
        if looseNames.contains(lowered) {
            let atStart = words[..<index].allSatisfy { leadIns.contains($0.text.lowercased()) }
            guard atStart, let next else { return false }
            return commandStarters.contains(next)
        }
        guard isName(words[index].text), startsUtterance(at: index, in: words, text: text) else { return false }
        // "Rio de Janeiro is beautiful": a place (checked after any repeated name).
        var last = index
        while last + 1 < words.count, isName(words[last + 1].text) { last += 1 }
        if last + 1 < words.count, placeContinuations.contains(words[last + 1].text.lowercased()) { return false }
        return true
    }

    private static func startsUtterance(at index: Int, in words: [Word], text: String) -> Bool {
        if index == 0 { return true }
        if words[..<index].allSatisfy({ leadIns.contains($0.text.lowercased()) || isName($0.text) }) { return true }
        // After a sentence end ("Okay. Rio open Chrome") or a pause (see `transcript(from:)`).
        let before = text[words[index - 1].range.upperBound..<words[index].range.lowerBound]
        return before.contains { ".!?\n".contains($0) }
    }

    private static func isName(_ word: String) -> Bool {
        let lowered = word.lowercased()
        if TeddyCommand.names.contains(lowered) { return true }
        // "Yo Rio" run together by the recognizer, e.g. "Yorio".
        return lowered.hasPrefix("yo") && TeddyCommand.names.contains(String(lowered.dropFirst(2)))
    }

    /// Words are runs of letters, digits and inner apostrophes ("what's" is one word, so
    /// "Rio's" is not the plain name).
    private static func wordRanges(in text: String) -> [Word] {
        var result: [Word] = []
        var start: String.Index?
        var index = text.startIndex
        func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "\u{2019}" }
        while index < text.endIndex {
            if isWordCharacter(text[index]) {
                if start == nil { start = index }
            } else if let s = start {
                result.append((String(text[s..<index]), s..<index))
                start = nil
            }
            index = text.index(after: index)
        }
        if let s = start { result.append((String(text[s...]), s..<text.endIndex)) }
        return result
    }
}

/// Timing rules for the wake-word listener, kept pure so they can be tested.
enum WakeListenTiming {
    /// Silence that ends an utterance with no command in it.
    static let silenceWithoutCommand: TimeInterval = 1.2
    /// Silence that ends a command once one has started: long enough for a thinking pause.
    static let silenceAfterCommand: TimeInterval = 1.8
    /// Silence after a command that stops on a word that needs more ("text mom that", "open").
    static let silenceAfterUnfinishedCommand: TimeInterval = 2.6
    /// After a bare "Rio", how long the listener waits for the command.
    static let bareNameWindow: TimeInterval = 4
    /// Longest wait before listening again after a final result with no words.
    static let maxEmptyFinalDelay: TimeInterval = 0.5

    private static let unfinishedEndings: Set<String> = [
        "that", "to", "and", "saying", "say", "the", "a", "an", "my", "for", "of", "with", "about", "is",
        "open", "text", "message", "tell", "send", "type", "write", "search", "set", "put", "move", "play",
        "if", "but", "or", "then", "so", "in", "on", "at", "from",
    ]

    /// How long to wait after the last new word before the utterance (or command) ends.
    static func silenceToEnd(pendingCommand: String?) -> TimeInterval {
        guard let pendingCommand else { return silenceWithoutCommand }
        let lastWord = pendingCommand.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0 == "'") })
            .last.map(String.init)
        if let lastWord, unfinishedEndings.contains(lastWord) { return silenceAfterUnfinishedCommand }
        return silenceAfterCommand
    }

    /// The wait before listening again after `consecutive` finals with no words in a row:
    /// 0.25 s, then 0.5 s at most, so the listener is never deaf for long in a quiet room.
    static func emptyFinalDelay(consecutive: Int) -> TimeInterval {
        min(0.25 * pow(2, Double(max(consecutive, 1) - 1)), maxEmptyFinalDelay)
    }
}
