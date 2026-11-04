import Foundation

/// Offline Arabic (Gulf and MSA) command table: turns a spoken Arabic command into the English
/// command Rio's parser already understands, with no network and no LLM ("ريو افتح كروم" becomes
/// "Rio open Chrome"). It only answers when every part of the sentence is understood; anything
/// else returns nil so the online translator (or the user's retry) takes over. It never guesses.
enum RioArabicCommandTable {
    static func english(for transcript: String) -> String? {
        let normalized = RioArabicText.normalize(transcript)
        guard normalized.unicodeScalars.contains(where: RioArabicText.isArabicScript) else { return nil }
        var tokens = normalized.split(separator: " ").map(String.init)
        // The words as said, at the same positions, for search queries and timer labels.
        let display = RioArabicText.displayWords(transcript)
        var originals = display.count == tokens.count ? display : tokens
        let wake = stripWake(&tokens, &originals)
        (tokens, originals) = withoutFiller(tokens, originals)
        // Timers, search, help and "time left" read the whole sentence: the clause splitter would
        // cut "خمس دقائق وثلاثين ثانية" or a search query at every "و".
        if let whole = RioArabicClauses.whole(tokens, originals: originals) { return wake ? "Rio \(whole)" : whole }
        let clauses = splitClauses(tokens)
        if clauses.isEmpty { return wake ? "Rio" : nil }

        var parts: [String] = []
        var previousWasApp = false
        for (index, clause) in clauses.enumerated() {
            if index > 0, previousWasApp, let app = appName(clause) {
                parts.append(app)
                continue
            }
            guard let result = RioArabicClauses.convert(clause) else { return nil }
            parts.append(result.english)
            previousWasApp = result.isAppCommand
        }
        let body = parts.joined(separator: " and ")
        return wake ? "Rio \(body)" : body
    }

    // MARK: Tokens

    /// Drops "يا ريو", "هلا ريو", "Hey Rio" or a bare "ريو" at the start. True when the name was there.
    private static func stripWake(_ tokens: inout [String], _ originals: inout [String]) -> Bool {
        var index = 0
        while index < tokens.count, RioArabicVocabulary.isGreeting(tokens[index]) { index += 1 }
        guard index < tokens.count, RioArabicVocabulary.isWakeWord(tokens[index]) else { return false }
        tokens.removeFirst(index + 1)
        originals.removeFirst(index + 1)
        return true
    }

    private static func withoutFiller(_ tokens: [String], _ originals: [String]) -> ([String], [String]) {
        var out: [String] = []
        var outOriginals: [String] = []
        var index = 0
        while index < tokens.count {
            if let phrase = RioArabicVocabulary.fillerPhrases.first(where: { phrase in
                index + phrase.count <= tokens.count && Array(tokens[index..<(index + phrase.count)]) == phrase
            }) {
                index += phrase.count
                continue
            }
            if !RioArabicVocabulary.fillers.contains(tokens[index]) {
                out.append(tokens[index])
                outOriginals.append(originals[index])
            }
            index += 1
        }
        return (out, outOriginals)
    }

    /// Splits on a standalone "و" (and), "بعدين"/"ثم" (then), on "و" written on an app
    /// ("وسبوتيفاي": and Spotify) and on "و" written on a command verb ("وعلي الصوت",
    /// "وشغل", "وافتح"), which is how Gulf and MSA speakers say "and".
    private static func splitClauses(_ tokens: [String]) -> [[String]] {
        var clauses: [[String]] = []
        var current: [String] = []
        let separators: Set<String> = ["و", "بعدين", "وبعدين", "ثم", "وبعد"]
        for (index, token) in tokens.enumerated() {
            let attached = token.hasPrefix("و") ? String(token.dropFirst()) : nil
            // "خمس و ستين" is one number (65), not two clauses.
            let joinsNumber = token == "و" && index > 0 && index + 1 < tokens.count
                && RioArabicVocabulary.number(in: [tokens[index - 1], token, tokens[index + 1]], at: 0)?.next == 3
            if separators.contains(token), !joinsNumber {
                if !current.isEmpty { clauses.append(current) }
                current = []
            } else if index > 0, let attached, token.count > 3,
                      RioArabicVocabulary.apps[RioArabicVocabulary.key(for: attached)] != nil {
                if !current.isEmpty { clauses.append(current) }
                current = [attached]
            } else if index > 0, let attached, attached.count >= 2, RioArabicClauses.isClauseVerb(attached) {
                if !current.isEmpty { clauses.append(current) }
                current = [attached]
            } else {
                current.append(token)
            }
        }
        if !current.isEmpty { clauses.append(current) }
        return clauses
    }

    /// The English app name when the whole clause is just an app ("سبوتيفاي"), else nil.
    static func appName(_ tokens: [String]) -> String? {
        guard !tokens.isEmpty else { return nil }
        if tokens.allSatisfy({ $0.unicodeScalars.allSatisfy(RioArabicText.isLatin) }) { return tokens.joined(separator: " ") }
        return RioArabicVocabulary.apps[RioArabicVocabulary.key(for: tokens.joined(separator: " "))]
    }
}

/// What to do with a transcript before parsing. English is always `.unchanged`: nothing is
/// translated, nothing is sent anywhere, and the check is a single pass over the letters.
enum RioCommandTranslationPlan: Equatable {
    case unchanged
    /// The built-in table understood it; no network.
    case offline(String)
    /// Not English and not in the table: ask the LLM (when online and allowed).
    case llm

    static let maxReplyLength = 300

    static func plan(for transcript: String) -> RioCommandTranslationPlan {
        // The script share is measured without the name, so "ريو stop" is the English "stop"
        // (the parser strips the Arabic name itself), while an Arabic verb at the start ("Rio,
        // شغل music") makes it a command to translate whatever the share.
        let body = RioArabicText.withoutLeadingName(transcript)
        guard RioArabicText.needsTranslation(body) || startsWithArabicVerb(body) else { return .unchanged }
        // "Rio type مرحبا", "text Ahmed وين انت": the command is already English and the Arabic is
        // what to type, send or search. Translating it would type or send the wrong language.
        if RioArabicText.hasEnglishContentFrame(transcript) { return .unchanged }
        if let known = RioArabicCommandTable.english(for: transcript) { return .offline(known) }
        return .llm
    }

    private static func startsWithArabicVerb(_ text: String) -> Bool {
        guard let first = text.split(whereSeparator: \.isWhitespace).first else { return false }
        return RioArabicClauses.isClauseVerb(RioArabicText.matchingForm(String(first)))
    }

    /// An LLM reply worth using: one non-empty line of reasonable length, labels and quotes removed.
    static func acceptedReply(_ reply: String) -> String? {
        let cleaned = RioTranslatorPrompt.clean(reply)
        guard !cleaned.isEmpty, cleaned.count <= maxReplyLength else { return nil }
        return cleaned
    }
}
