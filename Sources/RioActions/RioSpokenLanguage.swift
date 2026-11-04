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
