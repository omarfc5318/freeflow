import Foundation

// A local writing-style profile (#65), learned from the owner's recent dictations. Pure,
// Foundation only. Privacy by construction: everything the profile keeps is a count, a ratio, an
// emoji, or a phrase from the FIXED lists below, so no sentence the owner ever said can end up
// in a prompt. It is built in memory and never written to disk or to a log.

struct RioStyleProfile: Equatable, Codable {
    enum Casing: String, Codable { case sentence, lowercase, mixed, unknown }
    enum Formality: String, Codable { case formal, neutral, casual }

    /// How many dictations to learn from before the profile is used at all.
    static let minimumSamples = 8
    static let cleanupBudget = 600
    static let writingBudget = 700

    var sampleCount = 0
    var casing: Casing = .unknown
    /// True when most dictations end with a full stop, false when most don't, nil when mixed.
    var endsWithPeriod: Bool?
    var formality: Formality = .neutral
    /// Share of dictations that contain an emoji.
    var emojiRate = 0.0
    var topEmoji: [String] = []
    var signOffs: [String] = []
    var phrasings: [String] = []
    var arabicShare = 0.0
    var mixesLanguages = false

    var isUsable: Bool { sampleCount >= Self.minimumSamples }

    // MARK: Fixed vocabularies

    private static let formalMarkers = [
        "please", "kindly", "regards", "sincerely", "dear", "would like", "could you", "would you", "thank you", "appreciate",
        "i am writing", "attached", "advise", "furthermore",
    ]
    private static let casualMarkers = [
        "gonna", "wanna", "gotta", "yeah", "yep", "nah", "hey", "lol", "haha", "bro", "btw", "cool", "yo", "ok", "okay",
        "dude", "man", "nope", "sup", "omg", "tbh",
    ]
    private static let signOffLexicon = [
        "best regards", "kind regards", "warm regards", "regards", "best", "cheers", "thanks", "thank you", "thanks again",
        "talk soon", "see you", "take care", "sincerely", "love", "ttyl", "شكرا", "تحياتي", "مع السلامة", "الله يسلمك",
    ]
    private static let phraseLexicon = [
        "let me know", "sounds good", "no worries", "for sure", "by the way", "just wanted to", "hope you're well",
        "looking forward", "talk soon", "thanks so much", "i think", "honestly", "basically", "anyway", "to be honest",
        "as soon as possible", "heads up", "makes sense", "yalla", "inshallah", "insha'allah", "habibi", "mashallah", "wallah",
        "يلا", "ان شاء الله", "إن شاء الله", "حبيبي", "ماشي", "تمام",
    ]

    // MARK: Eligibility

    /// The newest dictation texts made after a reset, blanks dropped.
    static func eligibleSamples(from entries: [RioHistoryEntry], after resetAt: Date?, limit: Int = 300) -> [String] {
        entries
            .filter { entry in resetAt.map { entry.date > $0 } ?? true }
            .sorted { $0.date > $1.date }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(max(0, limit))
            .map { $0 }
    }

    // MARK: Extraction

    static func extract(from allSamples: [String]) -> RioStyleProfile {
        let samples = allSamples
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.split(whereSeparator: \.isWhitespace).count >= 2 }
        var profile = RioStyleProfile()
        profile.sampleCount = samples.count
        guard !samples.isEmpty else { return profile }
        let total = Double(samples.count)
        let lowered = samples.map { $0.lowercased() }

        profile.casing = casing(of: samples)
        profile.endsWithPeriod = periodHabit(of: samples)
        profile.formality = formality(of: lowered)

        var emojiCounts: [String: Int] = [:]
        var withEmoji = 0
        for sample in samples {
            let found = sample.filter(isEmoji).map(String.init)
            if !found.isEmpty { withEmoji += 1 }
            for emoji in found { emojiCounts[emoji, default: 0] += 1 }
        }
        profile.emojiRate = Double(withEmoji) / total
        profile.topEmoji = top(emojiCounts, minimum: 2, limit: 3)

        profile.signOffs = top(signOffCounts(lowered), minimum: 2, limit: 2)
        profile.phrasings = top(phraseCounts(lowered), minimum: 2, limit: 5)

        let language = languageMix(of: samples)
        profile.arabicShare = language.arabicShare
        profile.mixesLanguages = language.mixes
        return profile
    }

    private static func top(_ counts: [String: Int], minimum: Int, limit: Int) -> [String] {
        counts.filter { $0.value >= minimum }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map(\.key)
    }

    private static func casing(of samples: [String]) -> Casing {
        var upper = 0, lower = 0
        for sample in samples {
            guard let first = sample.first(where: { $0.isLetter && $0.isASCII }) else { continue }
            if first.isUppercase { upper += 1 } else { lower += 1 }
        }
        let counted = Double(upper + lower)
        guard counted >= 3 else { return .unknown }
        if Double(lower) / counted >= 0.7 { return .lowercase }
        if Double(upper) / counted >= 0.7 { return .sentence }
        return .mixed
    }

    private static func periodHabit(of samples: [String]) -> Bool? {
        let ending = samples.filter { $0.hasSuffix(".") }.count
        let ratio = Double(ending) / Double(samples.count)
        if ratio >= 0.6 { return true }
        return ratio <= 0.3 ? false : nil
    }

    private static func formality(of lowered: [String]) -> Formality {
        var formal = 0, casual = 0
        for text in lowered {
            let words = Set(text.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init))
            formal += formalMarkers.filter { $0.contains(" ") ? text.contains($0) : words.contains($0) }.count
            casual += casualMarkers.filter { words.contains($0) }.count
        }
        guard formal + casual >= 3 else { return .neutral }
        let score = Double(formal) / Double(formal + casual)
        if score >= 0.65 { return .formal }
        return score <= 0.35 ? .casual : .neutral
    }

    /// A sign-off counts when a dictation ends with it (or it's a trailing line).
    private static func signOffCounts(_ lowered: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        let edge = CharacterSet.letters.inverted
        for text in lowered {
            let words = text.components(separatedBy: edge).filter { !$0.isEmpty }
            let tail = words.suffix(3).joined(separator: " ")
            // The longest sign-off that the text ends with.
            if let match = signOffLexicon.sorted(by: { $0.count > $1.count }).first(where: { tail == $0 || tail.hasSuffix(" " + $0) }) {
                counts[match, default: 0] += 1
            }
        }
        return counts
    }

    private static func phraseCounts(_ lowered: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for text in lowered {
            let normal = text.replacingOccurrences(of: "\u{2019}", with: "'")
            for phrase in phraseLexicon where normal.contains(phrase) { counts[phrase, default: 0] += 1 }
        }
        return counts
    }

    private static func languageMix(of samples: [String]) -> (arabicShare: Double, mixes: Bool) {
        var arabic = 0, latin = 0, mixed = 0
        for sample in samples {
            var a = 0, l = 0
            for scalar in sample.unicodeScalars {
                switch scalar.value {
                case 0x0600...0x06FF, 0x0750...0x077F, 0xFB50...0xFDFF, 0xFE70...0xFEFF: a += 1
                case 0x41...0x5A, 0x61...0x7A: l += 1
                default: break
                }
            }
            arabic += a
            latin += l
            if a >= 2 && l >= 2 { mixed += 1 }
        }
        let letters = arabic + latin
        guard letters > 0 else { return (0, false) }
        let share = Double(arabic) / Double(letters)
        let mixedRatio = Double(mixed) / Double(samples.count)
        return (share, mixedRatio >= 0.3 && share > 0.05 && share < 0.95)
    }

    private static func isEmoji(_ character: Character) -> Bool {
        guard let first = character.unicodeScalars.first else { return false }
        if first.properties.isEmojiPresentation || first.value >= 0x1F000 { return true }
        return first.properties.isEmoji && first.value > 0x2000 && character.unicodeScalars.contains { $0.value == 0xFE0F }
    }

    // MARK: Output

    /// Short lines for the Settings preview ("what Rio learned").
    func learnedLines() -> [String] {
        guard isUsable else { return [] }
        var lines: [String] = []
        switch casing {
        case .lowercase: lines.append("You usually start in lowercase.")
        case .sentence: lines.append("You usually start sentences with a capital letter.")
        case .mixed, .unknown: break
        }
        switch endsWithPeriod {
        case true?: lines.append("You usually end with a full stop.")
        case false?: lines.append("You usually leave off the final full stop.")
        case nil: break
        }
        switch formality {
        case .formal: lines.append("Your tone is formal.")
        case .casual: lines.append("Your tone is casual.")
        case .neutral: break
        }
        if !topEmoji.isEmpty, emojiRate >= 0.1 { lines.append("You use emoji, mostly \(topEmoji.joined(separator: " ")).") }
        if !signOffs.isEmpty { lines.append("You sign off with \(signOffs.map { "\"\($0)\"" }.joined(separator: ", ")).") }
        if !phrasings.isEmpty { lines.append("Phrases you like: \(phrasings.joined(separator: ", ")).") }
        if mixesLanguages {
            lines.append("You mix Arabic and English.")
        } else if arabicShare > 0.95 {
            lines.append("You dictate in Arabic.")
        }
        return lines
    }

    /// For the cleanup prompt: punctuation, capitalisation and language only, never wording.
    func cleanupPrompt(maxCharacters: Int = RioStyleProfile.cleanupBudget) -> String {
        guard isUsable else { return "" }
        var lines: [String] = []
        switch casing {
        case .lowercase: lines.append("- Starts sentences in lowercase; keep that, don't capitalise the first word.")
        case .sentence: lines.append("- Starts sentences with a capital letter.")
        case .mixed, .unknown: break
        }
        switch endsWithPeriod {
        case true?: lines.append("- Ends messages with a full stop.")
        case false?: lines.append("- Leaves off the final full stop of a message.")
        case nil: break
        }
        if mixesLanguages { lines.append("- Mixes Arabic and English in one message; keep each word in the language it was spoken in and never translate.") }
        guard !lines.isEmpty else { return "" }
        let header = "Writer's usual style (learned on this Mac). Match it only through punctuation and capitalisation; never add, remove or reword anything, and never add emoji or sign-offs that were not spoken:"
        return Self.fit(header: header, lines: lines, maxCharacters: maxCharacters)
    }

    /// For write-for-me: how the owner writes, including tone, emoji and sign-offs.
    func writingGuidance(maxCharacters: Int = RioStyleProfile.writingBudget) -> String {
        guard isUsable else { return "" }
        var lines: [String] = []
        switch casing {
        case .lowercase: lines.append("- Writes in lowercase.")
        case .sentence: lines.append("- Uses normal sentence capitalisation.")
        case .mixed, .unknown: break
        }
        switch endsWithPeriod {
        case true?: lines.append("- Ends with a full stop.")
        case false?: lines.append("- Skips the final full stop.")
        case nil: break
        }
        switch formality {
        case .formal: lines.append("- Tone: formal and polite.")
        case .casual: lines.append("- Tone: casual and relaxed.")
        case .neutral: break
        }
        if !topEmoji.isEmpty, emojiRate >= 0.1 { lines.append("- Sometimes uses emoji such as \(topEmoji.joined(separator: " ")).") }
        if !signOffs.isEmpty { lines.append("- Signs off with \(signOffs.map { "\"\($0)\"" }.joined(separator: " or ")).") }
        if !phrasings.isEmpty { lines.append("- Favourite phrases: \(phrasings.map { "\"\($0)\"" }.joined(separator: ", ")).") }
        if mixesLanguages { lines.append("- Mixes Arabic and English naturally.") }
        else if arabicShare > 0.95 { lines.append("- Writes in Arabic.") }
        guard !lines.isEmpty else { return "" }
        return Self.fit(header: "How the user usually writes (learned locally):", lines: lines, maxCharacters: maxCharacters)
    }

    /// Header plus as many whole lines as fit; empty if not even the first line fits.
    private static func fit(header: String, lines: [String], maxCharacters: Int) -> String {
        var text = header
        var added = 0
        for line in lines {
            let candidate = text + "\n" + line
            if candidate.count > maxCharacters { break }
            text = candidate
            added += 1
        }
        return added == 0 ? "" : text
    }
}
