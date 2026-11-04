import Foundation

/// The language the owner spoke a command in. Commands reach the parser and the brain in English
/// (`RioCommandTranslator`); this remembers, for that one command, that it was said in Arabic, so
/// the spoken answer comes back in Arabic. Pure, Foundation only.
enum RioSpokenLanguage: String, Equatable, Sendable {
    case english
    case arabic

    /// What the owner spoke, judged from the transcript as heard and the translator's plan:
    /// Arabic only when the command words were Arabic (an English frame with Arabic content,
    /// "Rio type مرحبا", is an English command).
    static func detect(transcript: String, plan: RioCommandTranslationPlan) -> RioSpokenLanguage {
        guard plan != .unchanged else { return .english }
        return RioArabicText.isArabic(RioArabicText.withoutLeadingName(transcript)) ? .arabic : .english
    }
}

/// The translator's note about the command it just handled: what language it was spoken in and
/// the English it became. A request reads it back only for that command (its English words) and
/// only for a short while, so a later English command is never answered in Arabic. In memory
/// only, never logged or stored.
final class RioSpokenLanguageMemory: @unchecked Sendable {
    static let shared = RioSpokenLanguageMemory()
    static let lifetime: TimeInterval = 90
    /// How much of the command (letters and digits) must appear in the recorded English.
    static let matchCharacters = 40

    private let lock = NSLock()
    private var entry: (language: RioSpokenLanguage, english: String, at: Date)?

    /// Called by the translator for every command it sees, English included.
    func record(_ language: RioSpokenLanguage, english: String, at: Date) {
        lock.lock()
        defer { lock.unlock() }
        entry = language == .english ? nil : (language, Self.compact(english), at)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entry = nil
    }

    /// The language `command` was spoken in: Arabic when the translator recorded it recently and
    /// `command` is (part of) the English it produced; English otherwise.
    func language(forCommand command: String, now: Date) -> RioSpokenLanguage {
        lock.lock()
        defer { lock.unlock() }
        guard let entry, now.timeIntervalSince(entry.at) <= Self.lifetime, now >= entry.at else { return .english }
        let key = String(Self.compact(command).prefix(Self.matchCharacters))
        return !key.isEmpty && entry.english.contains(key) ? entry.language : .english
    }

    private static func compact(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}

/// Which installed voice reads an Arabic answer: the best Arabic voice, Gulf and Saudi first.
/// The English chooser only ever picks English voices, which cannot read Arabic script.
enum RioArabicVoiceChooser {
    private static let regions = ["ar-sa", "ar-ae", "ar-qa", "ar-001", "ar"]

    /// True when Rio should read `text` with an Arabic voice (mostly Arabic script).
    static func needsArabicVoice(_ text: String) -> Bool {
        RioArabicText.isArabic(text)
    }

    static func pick(from candidates: [RioVoiceCandidate]) -> RioVoiceCandidate? {
        candidates
            .filter { $0.language.lowercased().hasPrefix("ar") }
            .min { rank($0) < rank($1) }
    }

    private static func rank(_ voice: RioVoiceCandidate) -> (Int, Int, String) {
        let region = voice.language.replacingOccurrences(of: "_", with: "-").lowercased()
        return (-voice.quality.rawValue, regions.firstIndex(of: region) ?? regions.count, voice.identifier)
    }
}

/// Gulf Arabic for the few lines Rio answers by himself (no model call), for a command said in
/// Arabic: the time, the battery, the timer and the stop acknowledgements. The brain's answers
/// already come back in Arabic (`RioSmartPrompt`); anything not listed here stays English. Pure.
enum RioArabicReplies {
    /// The Arabic line for `outcome`, or nil to keep the English one.
    static func line(for outcome: RioActionOutcome) -> String? {
        switch outcome {
        case .succeeded(let text): return success(text.trimmingCharacters(in: .whitespacesAndNewlines))
        case .failed(let message): return failure(message.trimmingCharacters(in: .whitespacesAndNewlines))
        case .cancelled: return "تمام، لغيتها"
        case .nothing, .unknown: return nil
        }
    }

    private static let fixed: [String: String] = [
        "Stopped": "وقفت", "Okay": "تمام", "Stopped translating": "وقفت الترجمة", "Stopped listening": "وقفت الاستماع",
        "Your timer is ringing": "التايمر يرن", "No time left": "خلص الوقت", "Cancelled the timer": "لغيت التايمر",
    ]

    private static func success(_ text: String) -> String? {
        if let line = fixed[text] { return line }
        if let groups = RioText.firstMatch(#"^It's (\d{1,2}(?::\d{2})?) (AM|PM)(?: in (.+))?$"#, in: text), let time = groups[1] {
            let part = groups[2] == "AM" ? "الصبح" : "المسا"
            let place = groups[3].map { " في \($0)" } ?? ""
            return "الساعة \(time) \(part)\(place)"
        }
        if let groups = RioText.firstMatch(#"^(.+) left$"#, in: text), let span = groups[1], let arabic = duration(span) {
            return "باقي \(arabic)"
        }
        if let groups = RioText.firstMatch(#"^Timer set for (.+)$"#, in: text), let span = groups[1], let arabic = duration(span) {
            return "ضبطت التايمر على \(arabic)"
        }
        return battery(text)
    }

    private static func failure(_ message: String) -> String? {
        switch message {
        case "There's no timer running": return "ما في تايمر شغال"
        default: return nil
        }
    }

    /// "You're at 64%, charging, about 1 hour to full" (`RioSystemFormat.summary`).
    private static func battery(_ text: String) -> String? {
        guard let groups = RioText.firstMatch(#"^You're at (\d{1,3})%(.*)$"#, in: text), let percent = groups[1] else { return nil }
        let rest = groups[2] ?? ""
        var line = "البطارية \(percent)٪"
        if rest.hasPrefix(" and fully charged") { return line + "، ومشحونة بالكامل" }
        if rest.hasPrefix(", plugged in and not charging") { return line + "، موصولة بالشاحن بس ما تشحن" }
        if rest.hasPrefix(", charging") { line += "، وتشحن" } else if rest.hasPrefix(" on battery") { line += "، على البطارية" }
        if let span = RioText.firstMatch(#"about (.+?) (?:to full|left)$"#, in: rest)?[1], let arabic = duration(span) {
            line += rest.hasSuffix("to full") ? "، تتعبى بعد \(arabic) تقريباً" : "، باقي \(arabic) تقريباً"
        }
        return line
    }

    /// "1 hour and 5 minutes" -> "1 ساعة و 5 دقايق"; nil for anything else.
    static func duration(_ english: String) -> String? {
        let parts = english.replacingOccurrences(of: " and ", with: ", ").components(separatedBy: ", ")
        var out: [String] = []
        for part in parts {
            guard let groups = RioText.firstMatch(#"^(\d+) (hour|minute|second)s?$"#, in: part.trimmingCharacters(in: .whitespaces)),
                  let number = groups[1].flatMap(Int.init), let unit = groups[2] else { return nil }
            out.append("\(number) \(unitName(unit, count: number))")
        }
        return out.isEmpty ? nil : out.joined(separator: " و ")
    }

    private static func unitName(_ unit: String, count: Int) -> String {
        let plural = (3...10).contains(count)
        switch unit {
        case "hour": return plural ? "ساعات" : "ساعة"
        case "minute": return plural ? "دقايق" : "دقيقة"
        default: return plural ? "ثواني" : "ثانية"
        }
    }
}
