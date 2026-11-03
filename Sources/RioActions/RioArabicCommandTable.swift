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
        let wake = stripWake(&tokens)
        tokens = withoutFiller(tokens)
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

    /// Drops "يا ريو", "هلا ريو" or a bare "ريو" at the start. True when the name was there.
    private static func stripWake(_ tokens: inout [String]) -> Bool {
        var index = 0
        while index < tokens.count, RioArabicVocabulary.greetings.contains(tokens[index]) { index += 1 }
        guard index < tokens.count, RioArabicVocabulary.wakeWords.contains(tokens[index].lowercased()) else { return false }
        tokens.removeFirst(index + 1)
        return true
    }

    private static func withoutFiller(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var index = 0
        while index < tokens.count {
            if let phrase = RioArabicVocabulary.fillerPhrases.first(where: { phrase in
                index + phrase.count <= tokens.count && Array(tokens[index..<(index + phrase.count)]) == phrase
            }) {
                index += phrase.count
                continue
            }
            if !RioArabicVocabulary.fillers.contains(tokens[index]) { out.append(tokens[index]) }
            index += 1
        }
        return out
    }

    /// Splits on a standalone "و" (and), "بعدين"/"ثم" (then), and on "وسبوتيفاي" (and Spotify).
    private static func splitClauses(_ tokens: [String]) -> [[String]] {
        var clauses: [[String]] = []
        var current: [String] = []
        let separators: Set<String> = ["و", "بعدين", "وبعدين", "ثم", "وبعد"]
        for (index, token) in tokens.enumerated() {
            if separators.contains(token) {
                if !current.isEmpty { clauses.append(current) }
                current = []
            } else if index > 0, token.hasPrefix("و"), token.count > 3,
                      RioArabicVocabulary.apps[RioArabicVocabulary.key(for: String(token.dropFirst()))] != nil {
                if !current.isEmpty { clauses.append(current) }
                current = [String(token.dropFirst())]
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
        guard RioArabicText.needsTranslation(transcript) else { return .unchanged }
        if let known = RioArabicCommandTable.english(for: transcript) { return .offline(known) }
        return .llm
    }

    /// An LLM reply worth using: one non-empty line of reasonable length, labels and quotes removed.
    static func acceptedReply(_ reply: String) -> String? {
        let cleaned = RioTranslatorPrompt.clean(reply)
        guard !cleaned.isEmpty, cleaned.count <= maxReplyLength else { return nil }
        return cleaned
    }
}
