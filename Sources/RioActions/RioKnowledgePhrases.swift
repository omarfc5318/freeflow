import Foundation

/// Phrases for files, calendar and clipboard history (builder H). Pure, no AppKit. Each
/// recognizer only claims phrasings that are clearly its own.
enum RioKnowledgePhrases {
    static func parse(
        raw: String,
        simplified: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> RioAction? {
        RioClipboardPhrases.parse(simplified: simplified)
            ?? RioCalendarPhrases.parse(raw: raw, simplified: simplified, now: now, calendar: calendar)
            ?? RioFilesPhrases.parse(simplified: simplified)
    }
}

/// "what's on my clipboard", "show my clipboard history", "paste the link I copied earlier".
enum RioClipboardPhrases {
    private static let article = #"(?:(?:the|my|that|this|a|an)\s+)?"#

    static func parse(simplified: String) -> RioAction? {
        let s = simplified.lowercased()
        let history = [
            #"^(?:show|read|list|tell)(?:\s+me)?\s+(?:my|the)\s+clipboard\s+history$"#,
            #"^clipboard\s+history$"#,
            #"^what\s+did\s+i\s+copy\s+(?:earlier|before|recently|today|previously)$"#,
            #"^what\s+have\s+i\s+(?:copied|been\s+copying)(?:\s+(?:earlier|before|recently|today))?$"#,
        ]
        if history.contains(where: { RioText.matches($0, s) }) { return .clipboard(.showHistory) }
        let current = [
            #"^what(?:s|\s+is|\s+do\s+i\s+have|\s+have\s+i\s+got)(?:\s+currently)?\s+(?:on|in)\s+(?:my|the)\s+clipboard$"#,
            #"^(?:read|read\s+me|tell\s+me|show\s+me|show)\s+(?:my|the)\s+clipboard$"#,
            #"^what\s+did\s+i\s+(?:just\s+)?copy$"#,
            #"^what(?:s|\s+is)\s+(?:just\s+)?copied$"#,
        ]
        if current.contains(where: { RioText.matches($0, s) }) { return .clipboard(.readCurrent) }
        return parsePaste(s)
    }

    private static func parsePaste(_ s: String) -> RioAction? {
        guard s.hasPrefix("paste ") else { return nil }
        if RioText.matches(#"^paste\s+(?:my\s+|the\s+)?(?:last|previous|latest|prior|recent)\s+(?:copy|copied(?:\s+(?:thing|item|text))?|clip(?:board)?(?:\s+item)?)$"#, s) {
            return .clipboard(.pasteRecent(matching: nil))
        }
        // "paste the link", "paste the address": the newest copied item of that kind.
        if let groups = RioText.firstMatch(#"^paste\s+(?:in\s+)?(?:the\s+|my\s+|that\s+)?(link|url|web\s?address|address|e\s?-?\s?mail(?:\s+address)?|phone(?:\s+number)?|website)$"#, in: s),
           let word = groups[1] {
            return .clipboard(.pasteRecent(matching: normalizedHint(word)))
        }
        let patterns = [
            "^paste\\s+\(article)(.+?)\\s+(?:(?:that|which)\\s+)?(?:i|ive|i\\s+have)\\s+(?:just\\s+)?copied(?:\\s+.*)?$",
            "^paste\\s+\(article)(.+?)\\s+from\\s+(?:my\\s+|the\\s+)?(?:clipboard(?:\\s+history)?|earlier|before|history|copy\\s+history)$",
        ]
        for pattern in patterns {
            if let groups = RioText.firstMatch(pattern, in: s), let hint = groups[1] {
                return .clipboard(.pasteRecent(matching: normalizedHint(hint)))
            }
        }
        return nil
    }

    private static let fillerWords: Set<String> = [
        "what", "whatever", "it", "that", "this", "the", "a", "an", "my", "last", "previous", "latest", "prior",
        "recent", "thing", "things", "one", "item", "stuff", "text", "copy", "earlier", "before", "again", "recently",
    ]

    /// "email address" -> "email", "the link" -> "link", "tax form" stays; nothing specific -> nil.
    static func normalizedHint(_ hint: String) -> String? {
        let lowered = hint.lowercased()
        if RioText.matches(#"\be\s?-?\s?mail\b"#, lowered) { return "email" }
        if RioText.matches(#"\b(?:links?|urls?|websites?|web\s?pages?|web\s+address|sites?)\b"#, lowered) { return "link" }
        if RioText.matches(#"\b(?:phone|telephone|cell)\b"#, lowered) { return "phone" }
        if RioText.matches(#"\baddress\b"#, lowered) { return "address" }
        let words = lowered.split(separator: " ").map(String.init).filter { !fillerWords.contains($0) }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}
