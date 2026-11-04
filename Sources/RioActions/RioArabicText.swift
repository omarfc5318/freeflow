import Foundation

/// Script detection and spelling clean-up for Arabic (and other non-Latin) transcripts. Pure.
enum RioArabicText {
    /// Share of letters that must be outside the Latin script before a transcript counts as
    /// "not English", so an English sentence with one Arabic name stays English.
    static let scriptShareThreshold = 0.3

    /// True when the transcript is mostly in a non-Latin script (Arabic, Hindi, Cyrillic, CJK...).
    /// Latin-script languages such as French can't be told apart by script and are not matched:
    /// English commands must never be sent for translation, so the rule errs toward "English".
    static func needsTranslation(_ text: String) -> Bool {
        share(of: text) { !isLatin($0) } >= scriptShareThreshold
    }

    static func isArabic(_ text: String) -> Bool {
        share(of: text, where: isArabicScript) >= scriptShareThreshold
    }

    /// Spelling Whisper varies on, made uniform for matching: no diacritics or tatweel, alef and
    /// ya and ta marbuta folded (أإآ -> ا, ى -> ي, ة -> ه), Arabic digits as 0-9, the Arabic
    /// percent sign as "%", Arabic punctuation as spaces, whitespace collapsed. Latin text is left
    /// as it is.
    static func normalize(_ text: String) -> String {
        clean(text, folding: true).joined(separator: " ")
    }

    /// The transcript's words as the speaker said them, at the same positions as the words of
    /// `normalize` (same splitting, letters not folded). Search queries and labels come from these,
    /// so "مطاعم قريبة" is searched as said, not as the matching form "مطاعم قريبه".
    static func displayWords(_ text: String) -> [String] {
        clean(text, folding: false)
    }

    private static func clean(_ text: String, folding: Bool) -> [String] {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x064B...0x065F, 0x0670, 0x0640, 0x200C, 0x200D, 0x200E, 0x200F, 0x061C:
                continue
            case 0x0623, 0x0625, 0x0622, 0x0671: out.append(folding ? "\u{0627}" : scalar)
            case 0x0649, 0x0626: out.append(folding ? "\u{064A}" : scalar)
            case 0x0629: out.append(folding ? "\u{0647}" : scalar)
            case 0x0624: out.append(folding ? "\u{0648}" : scalar)
            case 0x0660...0x0669: out.append(Unicode.Scalar(0x30 + scalar.value - 0x0660)!)
            case 0x06F0...0x06F9: out.append(Unicode.Scalar(0x30 + scalar.value - 0x06F0)!)
            case 0x066A: out.append("%")
            case 0x060C, 0x061B, 0x061F, 0x00AB, 0x00BB, 0x002C, 0x002E, 0x0021, 0x003F, 0x003A, 0x003B, 0x0022:
                out.append(" ")
            default: out.append(scalar)
            }
        }
        return String(out).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    static func isArabicScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return true
        default: return false
        }
    }

    static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x250 || (0x1E00...0x1EFF).contains(scalar.value)
    }

    private static func share(of text: String, where predicate: (Unicode.Scalar) -> Bool) -> Double {
        var letters = 0
        var matching = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            if predicate(scalar) { matching += 1 }
        }
        return letters == 0 ? 0 : Double(matching) / Double(letters)
    }
}

// MARK: - The command's frame: the name, and English command words around Arabic content

extension RioArabicText {
    /// English verbs whose object is content to type, send or search. When an English command
    /// starts with one of these, any Arabic after it is that content and must stay Arabic.
    static let englishContentVerbs: Set<String> = [
        "type", "write", "text", "message", "reply", "tell", "send", "search", "google", "dictate",
    ]

    /// The transcript without a leading greeting and name, in either script ("ريو stop",
    /// "Hey Rio افتح كروم", "يا ريو ..."). Unchanged when it doesn't start with the name.
    static func withoutLeadingName(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var index = 0
        while index < words.count, RioArabicVocabulary.isGreeting(matchingForm(words[index])) { index += 1 }
        guard index < words.count, RioArabicVocabulary.isWakeWord(matchingForm(words[index])) else { return text }
        return words[(index + 1)...].joined(separator: " ")
    }

    /// True when the command is framed in English with a content verb before any Arabic:
    /// "Rio type مرحبا", "Rio text Ahmed وين انت", "open Chrome and search for مطاعم في الدوحة".
    static func hasEnglishContentFrame(_ text: String) -> Bool {
        let words = withoutLeadingName(text).split(whereSeparator: \.isWhitespace).map(String.init)
        var latin: [String] = []
        for word in words {
            if word.unicodeScalars.contains(where: { isArabicScript($0) }) { break }
            latin.append(matchingForm(word))
        }
        guard latin.count < words.count else { return false } // no Arabic content at all
        if latin.contains(where: englishContentVerbs.contains) { return true }
        return zip(latin, latin.dropFirst()).contains { $0 == "look" && $1 == "up" }
    }

    /// A word lowercased, without punctuation at either end, in the folded Arabic spelling.
    static func matchingForm(_ word: String) -> String {
        normalize(word).lowercased()
            .trimmingCharacters(in: CharacterSet.letters.inverted.subtracting(.decimalDigits))
    }
}
