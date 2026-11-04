import Foundation

/// Phrases for context and memory (builder N). Pure, no AppKit.
/// - Follow-ups: "open it again", "close that", "make it bigger", "do the same for Spotify",
///   "send that to Ali too". They only fire when there is something for the pronoun to point at,
///   so with no recent command they are claimed by nobody and behave as before.
/// - Timeline search over the owner's own dictations: "what did I say about the budget",
///   "when did I mention the dentist", "what did I say on Monday", "look through my dictations
///   for the invoice". "What did I tell you about ..." stays with memory (builder L).
enum RioContextMemoryPhrases {
    static func parse(raw: String, simplified: String) -> RioAction? {
        parse(raw: raw, simplified: simplified, context: RioFollowUpMemory.shared.snapshot(), now: Date())
    }

    static func parse(raw: String, simplified: String, context: RioFollowUpContext?, now: Date) -> RioAction? {
        let text = simplified.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return history(text) ?? RioFollowUpRewriter.rewrite(text, context: context)
    }

    // MARK: History

    private static let maxQueryLength = 120

    private static func history(_ text: String) -> RioAction? {
        let patterns = [
            #"^what\s+did\s+i\s+(?:say|dictate|mention|write|talk\s+about)\s+(?:about|regarding|concerning|on)\s+(.+)$"#,
            #"^what\s+did\s+i\s+(?:say|dictate)\s+(today|yesterday)$"#,
            #"^what\s+was\s+i\s+(?:saying|talking\s+about|dictating)\s+(?:about\s+|regarding\s+)?(.+)$"#,
            #"^when\s+did\s+i\s+(?:say|mention|talk\s+about|dictate)\s+(.+)$"#,
            #"^(?:look|search|dig|go)\s+through\s+my\s+(?:dictations?|history|timeline|transcripts?|past\s+dictations?)\s+for\s+(.+)$"#,
            #"^search\s+my\s+(?:dictations?|history|timeline|transcripts?|past\s+dictations?)\s+for\s+(.+)$"#,
        ]
        for pattern in patterns {
            guard let raw = RioText.firstMatch(pattern, in: text)?[1] else { continue }
            let query = clean(raw)
            if isAddressedToSomeone(query) || query.isEmpty || query.count > maxQueryLength { continue }
            return .searchHistory(query: query)
        }
        return nil
    }

    private static func clean(_ raw: String) -> String {
        let lowered = RioText.collapseWhitespace(raw).lowercased()
        return RioText.replacing(#"\s+(?:please|thanks)$"#, with: "", in: lowered)
    }

    /// "what did I say to you" is a question about the conversation, not a search.
    private static func isAddressedToSomeone(_ query: String) -> Bool {
        RioText.matches(#"^(?:to|you|him|her|them)\b"#, query)
    }
}
