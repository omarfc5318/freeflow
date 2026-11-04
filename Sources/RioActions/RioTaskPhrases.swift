import Foundation

/// Explicit multi-step task phrasing (builder K): "find me a flight to Doha under $800", "book a
/// table at Nobu", "fill in this form with my details", "do … for me", "go on Kayak and …".
/// The last and broadest parser in the chain, so it claims only unmistakable task wording and
/// leaves everything else to the smart resolver (which may still route to `.runTask`). Pure.
enum RioTaskPhrases {
    static let maxGoalCharacters = 300

    private static let politePrefix =
        #"^(?:(?:hey\s+)?rio\s+)?(?:(?:please|can\s+you|could\s+you|would\s+you|will\s+you|i\s+need\s+you\s+to|i\s+want\s+you\s+to|go\s+ahead\s+and)\s+)*"#
    private static let emptyObjects: Set<String> = [
        "this", "that", "it", "something", "anything", "everything", "me a favor", "a favor", "the thing",
    ]

    static func parse(raw: String, simplified: String) -> RioAction? {
        let text = RioText.collapseWhitespace(simplified)
        guard let body = RioText.firstMatch(politePrefix + "(.+)$", in: text)?[1] else { return nil }
        guard let goal = goal(from: body), goal.count <= maxGoalCharacters else { return nil }
        return .runTask(goal: goal)
    }

    /// The two task phrasings the clause splitter would otherwise destroy: a trailing "for me"
    /// ("do the laundry booking for me") is stripped as polite filler, and "go on Kayak and look
    /// for flights" is cut at "and". Checked on the whole sentence, before it is split.
    static func wholeUtterance(_ body: String) -> RioAction? {
        let text = RioText.collapseWhitespace(RioText.simplify(body))
        guard let rest = RioText.firstMatch(politePrefix + "(.+)$", in: text)?[1] else { return nil }
        let lower = rest.lowercased()
        guard RioText.matches(#"^do\s+.+\s+for\s+me$"#, lower)
                || RioText.matches(#"^go\s+on\s+\S+(?:\s+\S+)?\s+and\s+(?:look|search|find|check|compare|book|buy|order)\b.+"#, lower),
              let goal = goal(from: rest), goal.count <= maxGoalCharacters else { return nil }
        return .runTask(goal: goal)
    }

    private static func goal(from body: String) -> String? {
        let lower = body.lowercased()
        // "do this for me find …" / "do this for me order paper towels".
        if let groups = RioText.firstMatch(#"^do\s+(?:this|that|it)\s+for\s+me\s+(?:and\s+)?(.{3,})$"#, in: body),
           let rest = groups[1], rest.split(separator: " ").count >= 2 {
            return rest
        }
        // "do the laundry booking for me".
        if let groups = RioText.firstMatch(#"^do\s+(.+?)\s+for\s+me$"#, in: body), let what = groups[1] {
            return emptyObjects.contains(what.lowercased()) ? nil : "do \(what)"
        }
        // "find me a flight …" (not "find my resume": the files parser owns that).
        if RioText.matches(#"^find\s+me\s+\S+\s+\S+"#, lower) { return body }
        // "book a table at Nobu": at least two words after "book".
        if RioText.matches(#"^book\s+\S+\s+\S+"#, lower) { return body }
        // "fill in this form with my details".
        if RioText.matches(#"^fill\s+(?:in|out)\s+(?:this|the|that|my|a)\s+(?:\w+\s+)?form\b"#, lower) { return body }
        // "go on Kayak and look for flights": "go to X" alone is an ordinary command.
        if RioText.matches(#"^go\s+(?:on|to)\s+\S+(?:\s+\S+)?\s+and\s+\S+\s+\S+"#, lower) { return body }
        return nil
    }
}
