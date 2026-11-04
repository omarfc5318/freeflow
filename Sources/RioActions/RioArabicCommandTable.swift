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
        (tokens, originals) = withoutLatinPoliteness(tokens, originals)
        commandFormOfFirstWord(&tokens, &originals)
        // Timers, search, help and "time left" read the whole sentence: the clause splitter would
        // cut "خمس دقائق وثلاثين ثانية" or a search query at every "و".
        if let whole = RioArabicClauses.whole(tokens, originals: originals) { return wake ? "Rio \(whole)" : whole }
        // A search verb the whole-sentence reader declined (its query ran into another command,
        // "ابحث عن مطاعم وافتح كروم"): the clause table must not read it either.
        if let first = tokens.first, RioArabicClauses.isSearchVerb(first) { return nil }
        let clauses = splitClauses(tokens)
        if clauses.isEmpty { return wake ? "Rio" : nil }

        var parts: [String] = []
        var previousWasApp = false
        for (index, clause) in clauses.enumerated() {
            if index > 0, previousWasApp, let app = appName(clause) {
                parts.append(app)
                continue
            }
            // An English clause after an Arabic one ("افتح كروم and put it on the left") is
            // already what the parser reads.
            if index > 0, clause.allSatisfy(isLatinWord) {
                parts.append(clause.joined(separator: " "))
                previousWasApp = false
                continue
            }
            guard let result = RioArabicClauses.convert(clause) else { return nil }
            parts.append(result.english)
            previousWasApp = result.isAppCommand
        }
        let body = parts.joined(separator: " and ")
        return wake ? "Rio \(body)" : body
    }

    static func isLatinWord(_ word: String) -> Bool { word.unicodeScalars.allSatisfy(RioArabicText.isLatin) }

    // MARK: Tokens

    /// Drops "يا ريو", "هلا ريو", "Hey Rio" or a bare "ريو" at the start, and the name said twice
    /// ("ريو، ريو افتح كروم"). True when the name was there.
    private static func stripWake(_ tokens: inout [String], _ originals: inout [String]) -> Bool {
        var found = false
        while true {
            var index = 0
            while index < tokens.count, RioArabicVocabulary.isGreeting(tokens[index]) { index += 1 }
            guard index < tokens.count, RioArabicVocabulary.isWakeWord(tokens[index]) else { return found }
            tokens.removeFirst(index + 1)
            originals.removeFirst(index + 1)
            found = true
        }
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

    /// "can you افتح لي الكروم please": English politeness before the first Arabic word and a
    /// final "please" go. English words between Arabic ones are left alone.
    private static func withoutLatinPoliteness(_ tokens: [String], _ originals: [String]) -> ([String], [String]) {
        func isPolite(_ word: String) -> Bool { RioArabicVocabulary.latinPoliteness.contains(RioArabicText.matchingForm(word)) }
        var start = 0
        while start < tokens.count, isPolite(tokens[start]) { start += 1 }
        guard start < tokens.count, !isLatinWord(tokens[start]) else { return (tokens, originals) }
        var end = tokens.count
        while end > start, ["please", "pls", "plz"].contains(RioArabicText.matchingForm(tokens[end - 1])) { end -= 1 }
        return (Array(tokens[start..<end]), Array(originals[start..<end]))
    }

    /// The first word as a command: a leading "و" dropped ("وافتح كروم") and the polite
    /// second-person form read as the command ("تفتح كروم", "تعلي الصوت": open, raise).
    private static func commandFormOfFirstWord(_ tokens: inout [String], _ originals: inout [String]) {
        guard let first = tokens.first else { return }
        var word = first
        if word.hasPrefix("و"), word.count >= 3 {
            let attached = String(word.dropFirst())
            if RioArabicClauses.isCommandVerb(attached) || RioArabicClauses.secondPersonCommand(attached) != nil {
                word = attached
            }
        }
        if let command = RioArabicClauses.secondPersonCommand(word) { word = command }
        guard word != first else { return }
        tokens[0] = word
        originals[0] = word
    }

    /// Splits on a standalone "و" (and), "بعدين"/"ثم" (then), English "and"/"then", on "و"
    /// written on an app ("وسبوتيفاي": and Spotify), on "و" written on a command verb ("وعلي
    /// الصوت", "وشغل", "وافتح"), and on "و" written on a second thing for the same verb ("طفي
    /// الوايفاي والبلوتوث": the verb is said again for the bluetooth), which is how Gulf and MSA
    /// speakers say "and".
    private static func splitClauses(_ tokens: [String]) -> [[String]] {
        var clauses: [[String]] = []
        var current: [String] = []
        func flush() {
            if !current.isEmpty { clauses.append(current) }
            current = []
        }
        let separators: Set<String> = ["و", "بعدين", "وبعدين", "ثم", "وبعد", "and", "then"]
        for (index, token) in tokens.enumerated() {
            let attached = token.hasPrefix("و") ? String(token.dropFirst()) : nil
            // "خمس و ستين" is one number (65), not two clauses.
            let joinsNumber = token == "و" && index > 0 && index + 1 < tokens.count
                && RioArabicVocabulary.number(in: [tokens[index - 1], token, tokens[index + 1]], at: 0)?.next == 3
            // The verb of the clause being read (or of the one just closed by a separate "و").
            let verb = (current.isEmpty ? clauses.last?.first : current.first).flatMap {
                RioArabicClauses.isCommandVerb($0) ? $0 : nil
            }
            if separators.contains(token.lowercased()), !joinsNumber {
                flush()
            } else if index > 0, let attached, token.count > 3,
                      RioArabicVocabulary.apps[RioArabicVocabulary.key(for: attached)] != nil {
                flush()
                current = [attached]
            } else if index > 0, let attached, attached.count >= 2, RioArabicClauses.isClauseVerb(attached) {
                flush()
                current = [attached]
            } else if index > 0, let attached, let verb, !current.isEmpty, RioArabicClauses.isTargetWord(attached) {
                flush()
                current = [verb, attached]
            } else if index > 0, current.isEmpty, let verb, RioArabicClauses.isTargetWord(token) {
                current = [verb, token]
            } else {
                current.append(token)
            }
        }
        flush()
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
        let word = RioArabicText.matchingForm(String(first))
        return RioArabicClauses.isCommandVerb(word) || RioArabicClauses.secondPersonCommand(word) != nil
    }

    /// An LLM reply worth using: one non-empty line of reasonable length, labels and quotes removed.
    static func acceptedReply(_ reply: String) -> String? {
        let cleaned = RioTranslatorPrompt.clean(reply)
        guard !cleaned.isEmpty, cleaned.count <= maxReplyLength else { return nil }
        return cleaned
    }
}
