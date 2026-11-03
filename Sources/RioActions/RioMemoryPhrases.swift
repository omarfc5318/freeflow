import Foundation

/// Phrases for memory ("remember my locker code is 4321", "what's my locker code", "forget my
/// locker code"), notes ("note: ask Ali about the deck") and instant maths. Pure, no AppKit. Each
/// pattern is anchored: "remember to call mom" and "remind me ..." are reminders, not memories,
/// and "what's my battery" or "what's my next meeting" stay with the system and calendar parsers.
enum RioMemoryPhrases {
    static func parse(raw: String, simplified: String) -> RioAction? {
        let text = tidy(raw)
        guard !text.isEmpty else { return nil }
        return remember(text) ?? forget(text) ?? recall(text) ?? note(text)
            ?? RioMathPhrases.parse(raw: raw, simplified: simplified)
    }

    private static func tidy(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t\"\u{201C}\u{201D}"))
        text = RioText.replacing(#"[,\s]+(?:please|thanks|thank you)[\s.!]*$"#, with: "", in: text)
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " .!\n\t"))
    }

    // MARK: Remember

    private static func remember(_ text: String) -> RioAction? {
        let pattern = #"^(?:please\s+)?(?:remember|memorize|keep\s+in\s+mind|make\s+a\s+mental\s+note)(?:\s+that)?\s*[:,]?\s+(.+)$"#
        guard let groups = RioText.firstMatch(pattern, in: text), let fact = groups[1]?.trimmingCharacters(in: .whitespaces),
              fact.count >= 3, fact.count <= RioMemoryStore.maxFactLength,
              !RioText.matches(#"^(?:to|when|how|why|what|where|who|if|me|you|us|it|this|the\s+time|the\s+day)\b"#, fact) else { return nil }
        return .remember(fact: fact)
    }

    // MARK: Forget

    private static func forget(_ text: String) -> RioAction? {
        let s = RioText.simplify(text).lowercased()
        guard let groups = RioText.firstMatch(#"^forget(?:\s+about)?\s+(?:that\s+)?my\s+(.+)$"#, in: s),
              let query = groups[1]?.trimmingCharacters(in: .whitespaces), !query.isEmpty,
              !RioText.matches(#"^(?:memories|memory|notes|facts|stuff|everything|things)$"#, query) else { return nil }
        return .forget(query: query)
    }

    // MARK: Recall

    private static let systemTopics = #"^(?:battery|volume|brightness|clipboard|calendar|schedule|agenda|meetings?|next\s+meeting|next\s+event|events?|timers?|screen|wifi\s+status|bluetooth|ip|ip\s+address|location|day|week|to\s?do|reminders?|inbox|emails?|messages?|files?|downloads|desktop|resume|storage|disk|cpu|display|mic|microphone|status|last\s+message|selection|page|tabs?)(?:\s.*)?$"#

    private static func recall(_ text: String) -> RioAction? {
        let s = RioText.simplify(text).lowercased()
        if RioText.matches(#"^what\s+(?:do\s+you\s+(?:remember|know)(?:\s+about\s+me)?|have\s+i\s+told\s+you|did\s+i\s+tell\s+you)$"#, s) {
            return .recall(query: "")
        }
        let patterns = [
            #"^(?:what\s+(?:is|was|are|were)|whats)\s+my\s+(.+)$"#,
            #"^do\s+you\s+(?:remember|know)\s+(?:what\s+)?my\s+(.+)$"#,
            #"^what\s+do\s+you\s+(?:remember|know)\s+about\s+my\s+(.+)$"#,
            #"^what\s+did\s+i\s+(?:tell\s+you|say)\s+about\s+(?:my\s+)?(.+)$"#,
            #"^tell\s+me\s+my\s+(.+)$"#,
        ]
        for pattern in patterns {
            guard let groups = RioText.firstMatch(pattern, in: s), var query = groups[1] else { continue }
            query = RioText.replacing(#"\s+(?:is|are|was|were)$"#, with: "", in: query).trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty, !RioText.matches(systemTopics, query) else { return nil }
            return .recall(query: query)
        }
        return nil
    }

    // MARK: Notes

    private static func note(_ text: String) -> RioAction? {
        let patterns = [
            #"^(?:take|make|add|jot)\s+(?:a\s+)?note\b(?:\s+to\s+self)?(?:\s+(?:that|down))?\s*[:,\-]?\s*(.+)$"#,
            #"^note\s+to\s+self\s*[:,\-]?\s*(.+)$"#,
            #"^note\s*[:,]\s*(.+)$"#,
            #"^note\s+(?:down|that)\s+(.+)$"#,
            #"^jot\s+down\s+(?:that\s+)?(.+)$"#,
            #"^add\s+to\s+(?:my\s+)?notes\s*[:,]?\s*(?:that\s+)?(.+)$"#,
            #"^(?:add|put)\s+(.+?)\s+(?:to|in|into)\s+(?:my\s+)?notes$"#,
        ]
        for pattern in patterns {
            guard let groups = RioText.firstMatch(pattern, in: text), var body = groups[1] else { continue }
            body = body.trimmingCharacters(in: CharacterSet(charactersIn: " .!\n\t"))
            guard !body.isEmpty, body.count <= RioNotesScripts.maxLength else { continue }
            return .addNote(text: body.prefix(1).uppercased() + body.dropFirst())
        }
        return nil
    }
}
