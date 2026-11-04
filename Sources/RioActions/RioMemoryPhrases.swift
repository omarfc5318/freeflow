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
            ?? RioEmailPhrases.parse(text)
            ?? RioMathPhrases.parse(raw: raw, simplified: simplified)
    }

    /// The only phrases that must see the whole sentence before it is split at "and" or a comma.
    /// Recall is not one of them: "what's my next class" belongs to the calendar parser, which runs
    /// first in the normal order.
    static func parseWhole(raw: String, simplified: String) -> RioAction? {
        let text = tidy(raw)
        guard !text.isEmpty else { return nil }
        return remember(text) ?? RioReminderPhrases.parse(text) ?? note(text) ?? RioNotionPhrases.parse(text)
            ?? RioEmailPhrases.parse(text)
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
              !RioText.matches(#"^(?:to|when|how|why|what|where|who|if|me|you|us|it|this|the\s+time|the\s+day)\b"#, fact),
              !RioText.matches(#"^that$"#, fact) else { return nil }
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

    private static let systemTopics = #"^(?:battery|volume|brightness|clipboard|calendar|schedule|agenda|meetings?|next\s+\S+|upcoming\s+\S+|next\s+meeting|next\s+event|events?|timers?|screen|wifi\s+status|bluetooth|ip|ip\s+address|location|day|week|to\s?do|reminders?|inbox|emails?|messages?|files?|downloads|desktop|resume|storage|disk|cpu|display|mic|microphone|status|last\s+message|selection|page|tabs?)(?:\s.*)?$"#

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
        return rememberedThing(s)
    }

    /// "what's the staging url" / "what is our seed round date": recall only when a remembered
    /// fact is about it, so "what's the time" or "what's the capital of France" stay elsewhere.
    private static func rememberedThing(_ s: String) -> RioAction? {
        guard let groups = RioText.firstMatch(#"^(?:what\s+(?:is|was|are|were)|whats)\s+(?:the|our)\s+(.+)$"#, in: s),
              let raw = groups[1] else { return nil }
        let query = RioText.replacing(#"\s+(?:is|are|was|were)$"#, with: "", in: raw).trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !RioText.matches(systemTopics, query), RioRememberedFacts.knows(query) else { return nil }
        return .recall(query: query)
    }

    // MARK: Notes

    /// "to my MAT108 notes saying ..." / "to my ECS119 notes: ...": the named note, then the text.
    private static let namedNote = #"^(?:to|in|into|on)\s+(?:my\s+|the\s+)?((?:[\p{L}\p{N}]+\s+){0,3}?[\p{L}\p{N}]+)\s+notes?\s*(?:[:,\-]\s*|\s+(?:saying|that\s+says|that)\s+)(.+)$"#

    private static func note(_ text: String) -> RioAction? {
        // "add to my ECS119 notes that pandas groupby returns a dataframe".
        if let groups = RioText.firstMatch(#"^(?:add|put|write|jot(?:\s+down)?)\s+(?:this\s+)?(.+)$"#, in: text),
           let rest = groups[1], let named = namedNoteText(rest) {
            return named
        }
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
            // "add a note to Notion saying ..." is Notion's, not Rio Notes'.
            if RioText.matches(#"^(?:to|in|into|on)\s+(?:my\s+|the\s+)?notion\b"#, body) { return nil }
            // "add a note to my MAT108 notes saying review chapter 3": the destination is not the text.
            if let named = namedNoteText(body) { return named }
            body = body.trimmingCharacters(in: CharacterSet(charactersIn: " .!\n\t"))
            guard !body.isEmpty, body.count <= RioNotesScripts.maxLength else { continue }
            return .addNote(text: body.prefix(1).uppercased() + body.dropFirst())
        }
        return nil
    }

    /// "to my MAT108 notes: review chapter 3" -> "MAT108: review chapter 3"; nil when no note is named.
    private static func namedNoteText(_ rest: String) -> RioAction? {
        guard let groups = RioText.firstMatch(namedNote, in: rest), let name = groups[1], let raw = groups[2] else { return nil }
        let body = raw.trimmingCharacters(in: CharacterSet(charactersIn: " .!\n\t"))
        guard !body.isEmpty else { return nil }
        let text = RioText.matches(#"^(?:my|the)$"#, name) ? body : "\(name): \(body)"
        guard text.count <= RioNotesScripts.maxLength else { return nil }
        return .addNote(text: text.prefix(1).uppercased() + text.dropFirst())
    }
}

/// What Rio remembers, as the phrase parsers see it: "where is my MAT108 midterm" and "when is the
/// ECS119 project due" are answered from memory when a remembered fact is about them, before file
/// search or Canvas claim them. Empty until the app installs the live store, so tests and the pure
/// parsers never read the owner's memory file.
enum RioRememberedFacts {
    nonisolated(unsafe) static var provider: () -> [String] = { [] }

    /// True when a remembered fact matches the spoken thing ("MAT108 midterm").
    static func knows(_ thing: String) -> Bool {
        let facts = provider()
        guard !facts.isEmpty, !RioMemoryMatcher.tokens(thing).isEmpty else { return false }
        return !RioMemoryMatcher.best(query: thing, facts: facts, limit: 1).isEmpty
    }
}

/// A memory miss on a real question ("what did I tell you about the seed round") looks through
/// the owner's dictations before saying it knows nothing. The memory's own miss message stays
/// when the dictations have nothing either. Only a miss falls back: a hit is answered as is.
enum RioRecallFallback {
    @MainActor static func resolve(memory result: RioActionResult, query: String, executor: RioActionExecuting) async -> RioActionResult {
        guard case .failed = result, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return result }
        if case .done(let summary) = await executor.execute(.searchHistory(query: query)) { return .done(summary: summary) }
        return result
    }
}
