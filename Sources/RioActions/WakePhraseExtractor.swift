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
    /// A pause this long right after the name sets it off like a comma ("Rio [pause] Spotify"),
    /// which the recognizer never writes (it runs without punctuation).
    static let gapAfterName: TimeInterval = 0.25

    /// The transcript rebuilt from timed words with a line break at each pause of
    /// `gapBeforeName` or more, so the name after a pause counts as a fresh start, and a comma
    /// after a name followed by a pause of `gapAfterName` or more. Words without timing (all
    /// zero) give the plain transcript, so nothing new is accepted.
    static func transcript(from words: [TimedWord]) -> String {
        var out = ""
        for (index, word) in words.enumerated() {
            if index > 0 {
                let previous = words[index - 1]
                let gap = word.start - (previous.start + previous.duration)
                let timed = word.start > 0
                if timed, gap >= gapBeforeName {
                    out += "\n"
                } else if timed, gap >= gapAfterName, isName(previous.text) {
                    out += ", "
                } else {
                    out += " "
                }
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
        "hey", "hi", "hello", "yo", "yoo", "ok", "okay", "uh", "um", "so", "oh", "alright", "right", "well", "please",
        // Casual and Gulf lead-ins: "yeah Rio", "ya Rio" (the en-US recognizer's "يا ريو"), "yalla Rio".
        "yeah", "ya", "yah", "yalla", "yallah", "dude", "man", "bro", "يا",
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
        "what\u{2019}s", "how", "how's", "hows", "how\u{2019}s", "who", "who's", "whos", "who\u{2019}s", "where",
        "where's", "wheres", "where\u{2019}s", "when", "when's", "whens", "when\u{2019}s", "can", "could", "would",
        "please", "do", "say",
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
        return !isTalkingAbout(after: last, in: words, text: text)
    }

    /// Words right after the name that make it the subject of a sentence about Rio (the film,
    /// the footballer, the parrot) rather than someone speaking to him: "Rio is a 2011 animated
    /// film", "Rio was released", "Rio 2 came out", "Rio the movie is great", "Rio Ferdinand".
    private static let statementVerbs: Set<String> = ["is", "was", "are", "were", "has", "had", "isnt", "wasnt", "isn't", "wasn't"]
    private static let determiners: Set<String> = ["the", "a", "an"]
    /// After "is"/"was"/"has", these make it a question to Rio: "Rio, is it raining", "Rio has my
    /// package arrived".
    private static let questionSubjects: Set<String> = [
        "it", "there", "this", "that", "my", "your", "he", "she", "they", "we", "you", "i", "anyone", "anything", "everything",
        "claude", "cloud", "our", "his", "her", "their",
    ]
    /// After "is"/"was"/"has", these keep it a statement about Rio: "Rio is a film", "Rio has been
    /// praised", "Rio is so cute".
    private static let statementStarters: Set<String> = [
        "a", "an", "been", "being", "become", "always", "never", "also", "one", "so", "very", "really", "such", "not", "about",
    ]
    /// Ranking words that make "Rio was the best film" a statement, not a question to Rio.
    private static let superlatives: Set<String> = [
        "best", "worst", "most", "least", "first", "biggest", "greatest", "highest", "largest", "top", "only", "sequel",
    ]
    /// Words that end a yes/no question about a thing: "is the build done", "are the lights on".
    private static let predicates: Set<String> = [
        "done", "ready", "on", "off", "open", "closed", "over", "up", "down", "back", "home", "here", "sent", "gone", "out",
        "right", "correct", "true", "wrong", "available", "free", "busy", "empty", "full", "loud", "quiet", "set", "due",
        "late", "early", "awake", "asleep", "okay", "ok", "fine", "good", "safe", "live", "online", "offline", "still", "broken",
        "finished", "running", "working", "playing", "charged", "connected", "plugged", "muted", "locked",
    ]
    /// Verbs that make "Rio 2 …" or "Rio the parrot …" a sentence about him.
    private static let sentenceVerbs: Set<String> = statementVerbs.union([
        "came", "comes", "released", "scored", "scores", "stars", "starred", "opened", "premiered", "won", "made", "grossed",
        "features", "featured", "took", "takes", "flew", "flies", "lives", "lived",
    ])
    /// Words after the name that make it a person or an event: "Rio Ferdinand", "Rio Olympics".
    private static let nameContinuations: Set<String> = ["ferdinand", "olympics", "olympic", "carnival", "carnaval"]

    /// True when the name at `index` (the last of any repeats) opens a statement about Rio.
    /// Never when a command word follows. A comma or a pause after the name ("Rio, Spotify",
    /// "Rio [pause] 5 minute timer") marks him as addressed, so only a plain statement ("Rio, is a
    /// film") still counts. Unpunctuated, a number, "a" or "the" after the name counts only when a
    /// statement verb follows ("Rio 2 came out", "Rio the movie is great"); an app or a word like
    /// "Claude", "Spotify" or "Louder" is a command.
    private static func isTalkingAbout(after index: Int, in words: [Word], text: String) -> Bool {
        guard index + 1 < words.count else { return false }
        let next = words[index + 1].text
        let lowered = next.lowercased()
        if commandStarters.contains(lowered) { return false }
        let between = text[words[index].range.upperBound..<words[index + 1].range.lowerBound]
        let isSetOff = !between.allSatisfy { $0 == " " || $0 == "\t" }
        let following = words[(index + 2)...].map { $0.text.lowercased() }
        if statementVerbs.contains(lowered) {
            // A capitalised word is a name ("Ahmed", "Mohammed"), never a participle.
            let subjectIsName = index + 2 < words.count && isCapitalised(words[index + 2].text)
            return !isQuestionAfterVerb(following, isSetOff: isSetOff, firstIsName: subjectIsName)
        }
        if isSetOff { return false }
        if nameContinuations.contains(lowered) { return true }
        if determiners.contains(lowered) || next.first?.isNumber == true {
            return following.prefix(4).contains(where: sentenceVerbs.contains)
        }
        return false
    }

    /// The words after "Rio is/was/has" read as a yes/no question to him: "is it raining", "is
    /// Claude done", "has the package arrived", "is the answer B".
    private static func isQuestionAfterVerb(_ words: [String], isSetOff: Bool, firstIsName: Bool) -> Bool {
        guard let first = words.first else { return false }
        if questionSubjects.contains(first) { return true }
        if !firstIsName, statementStarters.contains(first) || isPredicate(first) || superlatives.contains(first) { return false }
        let tail = words.dropFirst().prefix(4)
        if tail.contains(where: superlatives.contains) { return false }
        if tail.contains(where: isPredicate) { return true }
        // A quiz answer: "is the answer B".
        if words.count >= 2, let last = words.last, last.count == 1, last.first?.isLetter == true { return true }
        return isSetOff
    }

    private static func isCapitalised(_ word: String) -> Bool {
        guard let first = word.first, first.isUppercase else { return false }
        return word != word.uppercased()
    }

    private static func isPredicate(_ word: String) -> Bool {
        if predicates.contains(word) { return true }
        if word.count >= 5, word.hasSuffix("ing") { return true }
        return word.count >= 4 && word.hasSuffix("ed")
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
    /// Wait before listening again after the first few finals with no words.
    static let fastEmptyFinalDelay: TimeInterval = 0.5
    /// Empty finals in a row that still get the fast restart.
    static let fastEmptyFinals = 3
    /// Longest wait before listening again after a final result with no words. Sustained sound
    /// (`WakeSoundGate`) ends the wait at once, and the listener replays the last second of audio
    /// into the new recognition (`preRollSeconds`), so a soft "Rio" is not lost. Kept short: a
    /// normal voice a metre away can stay under the gate in a quiet room.
    static let maxEmptyFinalDelay: TimeInterval = 1.5
    /// Audio from just before listening starts again that is fed to the new recognition first,
    /// so the start of "Rio, help" said during the wait is still heard.
    static let preRollSeconds: TimeInterval = 1

    private static let unfinishedEndings: Set<String> = [
        "that", "to", "and", "saying", "say", "the", "a", "an", "my", "for", "of", "with", "about", "is",
        "open", "text", "message", "tell", "send", "type", "write", "search", "set", "put", "move", "play",
        "if", "but", "or", "then", "so", "in", "on", "at", "from",
    ]

    /// Whether a bare "Rio" heard now may open the `bareNameWindow` (the next utterance runs as
    /// a command without the name). Never while Rio is talking or just after: his own read-out,
    /// or room audio, ending on "Rio" must not turn the next room speech into a trusted command.
    static func bareNameOpensWindow(isRioSpeaking: Bool, secondsSinceRioSpoke: TimeInterval?) -> Bool {
        if isRioSpeaking { return false }
        if let since = secondsSinceRioSpoke, since < RioConversationBargeIn.echoTailSeconds { return false }
        return true
    }

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
    /// 0.25 s, then 0.5 s for the first few, then 1 s and 1.5 s at most, so a quiet room doesn't
    /// tear the recognizer down and rebuild it in a tight loop, yet is never deaf for long.
    /// Sustained sound cuts any wait short and starts the fast schedule again.
    static func emptyFinalDelay(consecutive: Int) -> TimeInterval {
        let count = max(consecutive, 1)
        guard count > fastEmptyFinals else { return min(0.25 * pow(2, Double(count - 1)), fastEmptyFinalDelay) }
        return min(Double(count - fastEmptyFinals) * 0.5 + 0.5, maxEmptyFinalDelay)
    }
}

/// Decides when the microphone has heard real sound (someone talking), not one loud sample:
/// a key click, a cough or a fan's tick stays below it; a spoken word crosses it.
struct WakeSoundGate {
    /// Root mean square level of a buffer that counts as loud: a normal voice about a metre away
    /// (speech RMS is often 0.01-0.03), above a quiet fan.
    static let loudLevel: Float = 0.015
    /// How long loud buffers must follow one another (a word's first syllable, not a key click).
    static let sustainedSeconds: Double = 0.06

    private var loudRun: Double = 0

    /// Feeds one buffer's RMS level and length; true once loud buffers have lasted
    /// `sustainedSeconds` in a row (and for every loud buffer after that).
    mutating func feed(rms: Float, seconds: Double) -> Bool {
        guard rms > Self.loudLevel else {
            loudRun = 0
            return false
        }
        loudRun += seconds
        return loudRun >= Self.sustainedSeconds
    }

    mutating func reset() { loudRun = 0 }
}
