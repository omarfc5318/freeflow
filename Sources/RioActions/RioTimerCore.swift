import Foundation

// Pure timer logic for Rio: spoken durations, timer phrases and countdown math with an injected
// clock. Foundation only, so it is covered by the executable tests. The live timer that rings
// lives in RioTimerCenter.swift.

enum RioTimerDuration {
    /// Longest timer Rio will start. Anything longer is left to the smart resolver.
    static let maxSeconds = 24 * 60 * 60

    struct Scan: Equatable {
        let seconds: Int
        /// Token indices the duration covers, so callers can drop it when looking for a label.
        let range: Range<Int>
    }

    /// Seconds for the first spoken duration in `text` ("2 and a half minutes" is 150), or nil
    /// when there is none, it is zero, or it is longer than a day.
    static func parse(_ text: String) -> Int? {
        guard let found = scan(tokens: RioWords.tokens(text)) else { return nil }
        return (1...maxSeconds).contains(found.seconds) ? found.seconds : nil
    }

    /// "8 minutes and 20 seconds", "1 hour", "1 hour, 1 minute and 1 second".
    static func spoken(_ totalSeconds: Int) -> String {
        let total = max(0, totalSeconds)
        let parts = [(total / 3600, "hour"), ((total % 3600) / 60, "minute"), (total % 60, "second")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        switch parts.count {
        case 0: return "0 seconds"
        case 1: return parts[0]
        case 2: return "\(parts[0]) and \(parts[1])"
        default: return "\(parts[0]), \(parts[1]) and \(parts[2])"
        }
    }

    // MARK: Scanning

    static func scan(tokens: [String]) -> Scan? {
        var index = 0
        while index < tokens.count {
            guard let first = segment(tokens, at: index) else {
                index += 1
                continue
            }
            var total = first.seconds
            var end = first.next
            while true {
                var probe = end
                if probe < tokens.count, tokens[probe] == "and" { probe += 1 }
                guard let more = segment(tokens, at: probe) else { break }
                total += more.seconds
                end = more.next
            }
            return Scan(seconds: Int(total.rounded()), range: index..<end)
        }
        return nil
    }

    private static let unitSeconds: [String: Double] = [
        "second": 1, "seconds": 1, "sec": 1, "secs": 1,
        "minute": 60, "minutes": 60, "min": 60, "mins": 60,
        "hour": 3600, "hours": 3600, "hr": 3600, "hrs": 3600,
    ]

    /// One "quantity unit" pair ("2 and a half minutes", "an hour and a half").
    private static func segment(_ tokens: [String], at index: Int) -> (seconds: Double, next: Int)? {
        guard index < tokens.count, let quantity = quantity(tokens, at: index),
              quantity.next < tokens.count, let multiplier = unitSeconds[tokens[quantity.next]] else { return nil }
        var value = quantity.value
        var next = quantity.next + 1
        if startsAndAHalf(tokens, at: next) {
            value += 0.5
            next += 3
        }
        return (value * multiplier, next)
    }

    private static func quantity(_ tokens: [String], at index: Int) -> (value: Double, next: Int)? {
        let token = tokens[index]
        func fraction(_ value: Double, from next: Int) -> (Double, Int) {
            var next = next
            if next < tokens.count, tokens[next] == "of" { next += 1 }
            if next < tokens.count, tokens[next] == "a" || tokens[next] == "an" { next += 1 }
            return (value, next)
        }
        switch token {
        case "a", "an":
            if index + 1 < tokens.count, tokens[index + 1] == "half" { return fraction(0.5, from: index + 2) }
            if index + 1 < tokens.count, tokens[index + 1] == "quarter" { return fraction(0.25, from: index + 2) }
            return (1, index + 1)
        case "half": return fraction(0.5, from: index + 1)
        case "quarter": return fraction(0.25, from: index + 1)
        default: break
        }
        var value: Double
        var next: Int
        if token.first?.isNumber == true, let number = Double(token) {
            value = number
            next = index + 1
        } else if let words = numberWords(tokens, at: index) {
            value = Double(words.value)
            next = words.next
        } else {
            return nil
        }
        if startsAndAHalf(tokens, at: next), next + 3 < tokens.count, unitSeconds[tokens[next + 3]] != nil {
            value += 0.5
            next += 3
        }
        return (value, next)
    }

    private static func startsAndAHalf(_ tokens: [String], at index: Int) -> Bool {
        index + 2 < tokens.count && tokens[index] == "and" && tokens[index + 1] == "a" && tokens[index + 2] == "half"
    }

    private static let smallNumbers: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30,
        "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// "forty five" -> 45, "one hundred twenty" -> 120.
    private static func numberWords(_ tokens: [String], at index: Int) -> (value: Int, next: Int)? {
        var total = 0
        var next = index
        while next < tokens.count {
            if let value = smallNumbers[tokens[next]] {
                total += value
            } else if tokens[next] == "hundred" {
                total = max(total, 1) * 100
            } else {
                break
            }
            next += 1
        }
        return next > index ? (total, next) : nil
    }
}

/// Word splitting shared by the timer phrases: lowercase letters, and numbers (with decimals)
/// as their own tokens, so "10min" is "10", "min".
enum RioWords {
    static func tokens(_ text: String) -> [String] {
        ranges(in: text).map { $0.token }
    }

    static func ranges(in text: String) -> [(token: String, range: Range<String.Index>)] {
        guard let regex = try? NSRegularExpression(pattern: #"[0-9]+(?:\.[0-9]+)?|[A-Za-z']+"#) else { return [] }
        let full = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: full).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return (String(text[range]).lowercased().replacingOccurrences(of: "'", with: ""), range)
        }
    }
}

enum RioTimerPhrases {
    private static let startWords: Set<String> = [
        "set", "start", "begin", "create", "make", "give", "put", "run", "timer", "countdown", "count",
    ]
    private static let notTimerVerbs: Set<String> = [
        "open", "launch", "quit", "close", "hide", "switch", "show", "find", "cancel", "stop", "delete",
        "clear", "remove", "kill", "dismiss", "type", "search", "google", "remind", "write",
    ]
    private static let labelFiller: Set<String> = [
        "the", "a", "an", "my", "please", "timer", "countdown", "for", "me", "set", "start", "begin",
        "create", "make", "give", "put", "run", "of", "on", "new", "up", "can", "you", "could", "would",
        "to", "and", "then", "just", "it", "that", "this", "now", "count", "down", "from", "rio",
    ]

    // MARK: Start

    /// "10 minute timer", "set a timer for 2 and a half minutes", "timer 30 seconds called pasta".
    /// Needs both the word timer (or countdown) and a duration, so "Start a timer" still goes to
    /// the smart resolver, and "open timer" stays an app launch.
    static func parseStart(_ text: String) -> RioAction? {
        let tokens = RioWords.tokens(text)
        guard let first = tokens.first, !notTimerVerbs.contains(first),
              tokens.contains("timer") || tokens.contains("countdown"),
              startsLikeATimer(tokens),
              let found = RioTimerDuration.scan(tokens: tokens),
              (1...RioTimerDuration.maxSeconds).contains(found.seconds) else { return nil }
        return .startTimer(seconds: found.seconds, label: label(from: tokens, removing: found.range))
    }

    private static func startsLikeATimer(_ tokens: [String]) -> Bool {
        guard let first = tokens.first else { return false }
        if startWords.contains(first) { return true }
        // "10 minute timer", "a timer for 5 minutes", "half an hour timer"
        if first.first?.isNumber == true || ["a", "an", "half", "quarter"].contains(first) { return true }
        if RioText.number(from: first) != nil { return true }
        // "pasta timer 10 minutes"
        return tokens.count <= 6 && tokens.count > 1 && (tokens[1] == "timer" || tokens[1] == "countdown")
    }

    private static func label(from tokens: [String], removing range: Range<Int>) -> String? {
        let rest = Array(tokens[..<range.lowerBound]) + Array(tokens[range.upperBound...])
        let markers: Set<String> = ["called", "named", "labeled", "labelled", "titled"]
        if let marker = rest.firstIndex(where: { markers.contains($0) }) {
            return cleanLabel(Array(rest[(marker + 1)...]))
        }
        if let last = rest.lastIndex(of: "for"), let found = cleanLabel(Array(rest[(last + 1)...])) {
            return found
        }
        if let timer = rest.firstIndex(where: { $0 == "timer" || $0 == "countdown" }) {
            return cleanLabel(Array(rest[..<timer]))
        }
        return nil
    }

    private static func cleanLabel(_ words: [String]) -> String? {
        var words = words[...]
        while let head = words.first, labelFiller.contains(head) { words = words.dropFirst() }
        while let tail = words.last, labelFiller.contains(tail) { words = words.dropLast() }
        guard !words.isEmpty, words.count <= 4,
              words.allSatisfy({ $0.first?.isLetter == true }) else { return nil }
        return words.joined(separator: " ")
    }

    // MARK: Cancel and status

    /// Phrases that name the timer or the alarm: the only ones that cancel a running countdown.
    private static let timerCancelPatterns = [
        #"^(?:cancel|stop|delete|clear|remove|end|kill|dismiss|silence|turn off|shut off|switch off)\s+(?:\w+\s+){0,3}(?:timer|timers|alarm|ringing)$"#,
        #"^(?:never mind|nevermind|forget(?: about)?)\s+(?:the|my|that)\s+(?:\w+\s+)?timer$"#,
    ]
    private static let interjection = #"^(?:(?:ok|okay|alright|oh|hey|no)\s+){0,2}"#
    /// A bare stop: whatever Rio is doing (a ringing timer, a task, his voice, the translator,
    /// the music), never a countdown that is still running.
    private static let bareStopPattern = interjection + #"(?:(?:please\s+)?stop(?: it| that| please)?|cancel(?: it| that)?)$"#
    /// Words that only ask Rio to stop talking (or a ringing timer to stop).
    private static let silencePattern = interjection
        + #"(?:stop (?:talking|speaking)|enough|that is enough|thats enough|be quiet|quiet|hush|shush|silence|shut up|be silent)$"#

    /// What kind of stop `simplified` is, or nil when it isn't one.
    static func stopKind(_ simplified: String) -> RioStopKind? {
        let text = normalized(simplified)
        if timerCancelPatterns.contains(where: { RioText.matches($0, text) }) { return .timer }
        if RioText.matches(silencePattern, text) { return .silence }
        if RioText.matches(bareStopPattern, text) { return .bare }
        return nil
    }

    private static let statusPatterns = [
        #"^(?:how much time|how long)(?: is| do i have| have i got)? (?:left|remaining)(?: on| for| in)?(?: (?:the|my|that) (?:\w+ )?timer)?(?: now)?$"#,
        #"^how much longer(?: on (?:the|my) (?:\w+ )?timer)?$"#,
        #"^(?:whats|what is) (?:left|remaining)(?: on| for)?(?: (?:the|my) (?:\w+ )?timer)?$"#,
        #"^(?:time left|time remaining)(?: on (?:the|my) (?:\w+ )?timer)?$"#,
        #"^(?:timer status|check (?:the|my) timer|how is (?:the|my) timer|is (?:the|my) timer (?:still )?running|how long until (?:the|my) timer(?: goes off| rings| is done)?|when does (?:the|my) timer (?:go off|ring|end|finish))$"#,
    ]

    /// Every stop phrase parses to `.cancelTimer`; the handler tells them apart with
    /// `RioStopRequest` (no new action case needed).
    static func isCancel(_ simplified: String) -> Bool {
        stopKind(simplified) != nil
    }

    static func isStatus(_ simplified: String) -> Bool {
        let text = normalized(simplified)
        return statusPatterns.contains { RioText.matches($0, text) }
    }

    private static func normalized(_ simplified: String) -> String {
        var text = simplified.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!?,"))
        text = RioText.replacing(#"\s+(?:please|now)$"#, with: "", in: text)
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Protecting a duration from the clause splitter

    /// The parser splits a command on "and", which would cut "2 and a half minutes" in two. When
    /// a timer is meant, rewrite such a duration to plain seconds first. Nothing else changes.
    static func protectingDurations(in body: String) -> String {
        let words = RioWords.ranges(in: body)
        let tokens = words.map { $0.token }
        guard tokens.contains("timer") || tokens.contains("countdown"),
              let found = RioTimerDuration.scan(tokens: tokens),
              found.range.contains(where: { tokens[$0] == "and" }) else { return body }
        let span = words[found.range.lowerBound].range.lowerBound..<words[found.range.upperBound - 1].range.upperBound
        return body.replacingCharacters(in: span, with: "\(found.seconds) seconds")
    }
}

// MARK: Stop semantics

/// How a spoken stop was phrased.
enum RioStopKind: Equatable {
    /// "Cancel the timer", "stop the alarm".
    case timer
    /// "Stop", "stop it", "cancel".
    case bare
    /// "Be quiet", "stop talking", "shut up", "enough".
    case silence
}

/// The stop kind of the command running now. The coordinator sets it from the words for the
/// length of one command; nil means a `.cancelTimer` the resolver planned (it cancels the timer).
@MainActor enum RioStopRequest {
    static var current: RioStopKind?
}

/// What is going on when a stop arrives.
struct RioStopState: Equatable {
    var isRinging = false
    var hasCountdown = false
    var isTaskRunning = false
    var isSpeaking = false
    var isTranslating = false
    var isMediaPlaying = false
}

enum RioStopStep: Equatable {
    case stopRinging
    case cancelCountdown
    case stopTask
    case stopSpeaking
    case stopTranslator
    case pauseMedia
    case nothing
}

/// Which one thing a stop stops. Pure.
enum RioStopPlan {
    static func step(kind: RioStopKind?, state: RioStopState) -> RioStopStep {
        switch kind {
        case .timer?:
            if state.isRinging { return .stopRinging }
            return state.hasCountdown ? .cancelCountdown : .nothing
        case .silence?:
            if state.isRinging { return .stopRinging }
            return state.isSpeaking ? .stopSpeaking : .nothing
        case .bare?:
            if state.isRinging { return .stopRinging }
            if state.isTaskRunning { return .stopTask }
            if state.isSpeaking { return .stopSpeaking }
            if state.isTranslating { return .stopTranslator }
            return state.isMediaPlaying ? .pauseMedia : .nothing
        case nil:
            // A planned cancelTimer: the task first (as before), then the timer.
            if state.isTaskRunning { return .stopTask }
            if state.isRinging { return .stopRinging }
            if state.hasCountdown { return .cancelCountdown }
            if state.isSpeaking { return .stopSpeaking }
            return state.isTranslating ? .stopTranslator : .nothing
        }
    }

    /// What Rio says when there was nothing to stop; nil means say nothing at all.
    static func nothingMessage(kind: RioStopKind?) -> String? {
        switch kind {
        case .timer?: return "There's no timer running"
        case .silence?: return nil
        case .bare?, nil: return "There's nothing to stop"
        }
    }
}

/// One running timer's math. The clock is always passed in, so tests never wait.
struct RioTimerCountdown: Equatable {
    let seconds: Int
    let label: String?
    let start: Date

    var endDate: Date { start.addingTimeInterval(TimeInterval(seconds)) }

    func remaining(at now: Date) -> TimeInterval {
        min(TimeInterval(seconds), max(0, endDate.timeIntervalSince(now)))
    }

    func isFinished(at now: Date) -> Bool { remaining(at: now) <= 0 }

    /// Whole seconds for the bear's clock: 0.2 s left still reads "1".
    static func displaySeconds(_ remaining: TimeInterval) -> Int {
        remaining <= 0 ? 0 : Int(remaining.rounded(.up))
    }

    func spokenRemaining(at now: Date) -> String {
        let whole = Self.displaySeconds(remaining(at: now))
        return whole == 0 ? "No time left" : "\(RioTimerDuration.spoken(whole)) left"
    }

    var doneLine: String { label.map { "Your \($0) timer is done!" } ?? "Your timer is done!" }

    var startedSummary: String {
        let length = RioTimerDuration.spoken(seconds)
        guard let label else { return "Timer set for \(length)" }
        return "\(label.prefix(1).uppercased() + label.dropFirst()) timer set for \(length)"
    }

    /// Like `startedSummary`, and says so when it replaced a timer that was still running:
    /// "Timer set for 10 minutes. That replaces your pasta timer, which had 3 minutes left."
    func startedSummary(replacing previous: RioTimerCountdown?, at now: Date) -> String {
        guard let previous, !previous.isFinished(at: now) else { return startedSummary }
        let left = RioTimerDuration.spoken(Self.displaySeconds(previous.remaining(at: now)))
        let name = previous.label.map { "\($0) timer" } ?? "timer"
        return "\(startedSummary). That replaces your \(name), which had \(left) left."
    }
}
