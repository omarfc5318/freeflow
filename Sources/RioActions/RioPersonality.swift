import Foundation

// Rio's spoken personality. Pure and deterministic: the seed, hour and day are injected, so the
// tests never depend on chance. Foundation only (no AppKit, no audio).

/// What Rio remembers between lines so he doesn't repeat himself, greets once a day and
/// announces milestones once.
struct RioPersonalityState: Equatable {
    var lastLine: String?
    /// `yyyyMMdd` of the last time he said good morning (or the night-owl line).
    var lastGreetingDay: Int?
    /// A milestone count (the 100th action) waiting to be announced.
    var pendingMilestone: Int?
    /// Texts of answer-like actions that ran in this command; spoken as themselves.
    var verbatim: [String] = []
}

enum RioPersonality {
    // MARK: Pinned entry point (AppState calls this after every action)

    /// What Rio says out loud after an action, or nil to stay quiet.
    static func spokenLine(for outcome: RioActionOutcome, hour: Int) -> String? {
        shared.withState { state in
            line(for: outcome, hour: hour, day: dayStamp(Date()), seed: .random(in: .min ... .max), state: &state)
        }
    }

    /// Answer-like actions (an answer, a reading, the agenda) register their text here so the
    /// matching outcome is spoken as itself, even when it is a single word.
    static func registerVerbatim(_ text: String) {
        shared.withState { state in
            state.verbatim = Array((state.verbatim + [text]).suffix(4))
        }
    }

    /// The undo journal calls this when the action count reaches a milestone.
    static func noteMilestone(_ count: Int) {
        shared.withState { $0.pendingMilestone = count }
    }

    // MARK: Deterministic core

    static func line(
        for outcome: RioActionOutcome, hour: Int, day: Int, seed: UInt64, state: inout RioPersonalityState
    ) -> String? {
        defer { state.verbatim.removeAll() }
        let spoken: String?
        switch outcome {
        case .nothing:
            return nil
        case .succeeded(let text):
            spoken = success(text, hour: hour, day: day, seed: seed, state: &state)
        case .failed(let message):
            spoken = failure(message, seed: seed, state: state)
        case .unknown:
            spoken = pick(unknownLines, seed: seed, avoiding: state.lastLine)
        case .cancelled:
            spoken = pick(cancelledLines, seed: seed, avoiding: state.lastLine)
        }
        if let spoken { state.lastLine = spoken }
        return spoken
    }

    // MARK: Lines

    static let openers = ["On it!", "Done!", "Ta-da!", "You got it!", "All set!", "Easy peasy!", "Sure thing!"]
    static let punLines = [
        "Beary good!", "Paws-itively done!", "That was un-bear-ably easy!", "Another job, beary well done!",
    ]
    private static let failurePrefixes = ["Hmm.", "Oops.", "Uh oh.", "Whoops."]
    private static let unknownLines = [
        "Hmm, I'm not sure how to do that one yet.",
        "Hmm, I didn't catch that. Want to try again?",
        "Sorry, that one's beyond my paws. Want to try again?",
        "Oops, I don't know that one yet.",
        "I didn't quite get that. Want to try again?",
    ]
    private static let cancelledLines = ["Okay, never mind.", "No problem, cancelled.", "Okay, I'll leave it."]

    private static func success(
        _ text: String, hour: Int, day: Int, seed: UInt64, state: inout RioPersonalityState
    ) -> String? {
        let registered = state.verbatim.filter { text.contains($0) }
        if !registered.isEmpty { return RioSpeechText.prepare(registered.joined(separator: " ")) }
        if isLongAnswer(text) { return RioSpeechText.prepare(text) }

        let summary = sentence(text)
        var candidates = openers + openers.map { "\($0) \(summary)" } + [summary]
        if mix(seed &+ 77) % 10 == 0 { candidates = punLines }
        if let milestone = state.pendingMilestone {
            candidates = ["That was number \(milestone)! We make a great team."]
            state.pendingMilestone = nil
        }
        guard let base = pick(candidates, seed: seed, avoiding: state.lastLine) else { return nil }
        if state.lastGreetingDay != day, let greeting = greeting(forHour: hour) {
            state.lastGreetingDay = day
            return "\(greeting) \(base)"
        }
        return base
    }

    private static func failure(_ message: String, seed: UInt64, state: RioPersonalityState) -> String? {
        let reason = sentence(message)
        var candidates = failurePrefixes.map { "\($0) \(reason)" }
        if reason.count <= 60 { candidates += failurePrefixes.map { "\($0) \(reason) Want to try again?" } }
        return pick(candidates, seed: seed, avoiding: state.lastLine).flatMap(RioSpeechText.prepare)
    }

    private static func greeting(forHour hour: Int) -> String? {
        switch hour {
        case 5..<12: return "Good morning!"
        case 0..<5: return "Still up? I'm here for it."
        default: return nil
        }
    }

    // MARK: Helpers

    /// Short action summaries get an opener; anything that reads like an answer is spoken itself.
    static func isLongAnswer(_ text: String) -> Bool {
        text.count > 48 || RioText.matches(#"[.!?]\s+\S"#, text) || text.contains("?")
    }

    static func isMilestone(_ count: Int) -> Bool {
        [10, 25, 50, 100, 250, 500].contains(count) || (count >= 1000 && count % 1000 == 0)
    }

    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        return trimmed.isEmpty ? "Done." : trimmed + "."
    }

    private static func pick(_ candidates: [String], seed: UInt64, avoiding last: String?) -> String? {
        let fresh = candidates.filter { $0 != last }
        let pool = fresh.isEmpty ? candidates : fresh
        guard !pool.isEmpty else { return nil }
        return pool[Int(mix(seed) % UInt64(pool.count))]
    }

    /// SplitMix64: a well-spread integer from any seed, so consecutive seeds don't pick
    /// consecutive lines.
    private static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    static func dayStamp(_ date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }

    // MARK: Shared state

    private static let greetingDayKey = "rio_last_greeting_day"
    private static let shared = SharedState()

    private final class SharedState: @unchecked Sendable {
        private let lock = NSLock()
        private var state: RioPersonalityState

        init() {
            let saved = UserDefaults.standard.object(forKey: RioPersonality.greetingDayKey) as? Int
            state = RioPersonalityState(lastGreetingDay: saved)
        }

        func withState<T>(_ body: (inout RioPersonalityState) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            let before = state.lastGreetingDay
            let result = body(&state)
            if state.lastGreetingDay != before, let day = state.lastGreetingDay {
                UserDefaults.standard.set(day, forKey: RioPersonality.greetingDayKey)
            }
            return result
        }
    }
}

/// Turns text into something that sounds right when read aloud, and caps how much he says.
enum RioSpeechText {
    static let maxLength = 500

    static func prepare(_ text: String) -> String? {
        var cleaned = text.replacingOccurrences(of: "\u{2026}", with: ".")
        cleaned = RioText.replacing(#"https?://\S+"#, with: "a link", in: cleaned)
        cleaned = cleaned.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "*", with: "")
        cleaned = joinLines(cleaned)
        cleaned = RioText.collapseWhitespace(cleaned)
        guard !cleaned.isEmpty else { return nil }
        return cap(cleaned)
    }

    /// Plain lines read on as one flow; headings and bullets become their own short sentences.
    private static func joinLines(_ text: String) -> String {
        var output = ""
        var previousStructured = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let stripped = RioText.replacing(#"^(?:#{1,6}\s+|[-•]\s+|\d+[.)]\s+)"#, with: "", in: line)
            let structured = stripped != line
            line = stripped
            if !output.isEmpty {
                if (structured || previousStructured), let last = output.last, !".!?".contains(last) { output += "." }
                output += " "
            }
            output += line
            previousStructured = structured
        }
        return output
    }

    /// Keeps whole sentences up to `maxLength`; if there is no sentence end, cuts at a word.
    private static func cap(_ text: String) -> String {
        guard text.count > maxLength else { return text }
        let head = String(text.prefix(maxLength))
        if let end = head.lastIndex(where: { ".!?".contains($0) }),
           head.distance(from: head.startIndex, to: end) > maxLength / 3 {
            return String(head[...end])
        }
        let words = head.split(separator: " ").dropLast().joined(separator: " ")
        return words + "."
    }
}
