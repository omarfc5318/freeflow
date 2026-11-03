import Foundation

/// Pure phrase parser for context actions (builder E): replying in the open conversation,
/// reading things aloud, tasks on the selection, and texting a named contact. It only claims
/// phrasings that are clearly its own, so "open Chrome", "write a poem" or "tell me a joke"
/// still reach the other parsers. Foundation only.
enum RioContextPhrases {
    static func parse(raw: String, simplified: String) -> RioAction? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let action = parseReply(text) { return action }
        if let action = parseMessage(text) { return action }
        let words = simplified.trimmingCharacters(in: .whitespaces)
        return parseReading(words) ?? parseSelectionTask(words)
    }

    // MARK: Shared pieces

    /// Connector between a recipient (or "reply") and the message body.
    private static let connector = #"(?:(?:saying|that says|says|that|with)\b[\s,:]*|:\s*)"#

    /// What "this" can mean when it points at the selection.
    private static let subject =
        #"(?:this|that|it|the selection|my selection|selection|the selected text|selected text|this text|that text|the text|what i selected|the highlighted text|the paragraph|this (?:paragraph|email|message|article|code|error|passage|sentence|section|snippet))"#

    private static func cleanBody(_ raw: String?) -> String? {
        guard var body = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        body = body.trimmingCharacters(in: CharacterSet(charactersIn: " .,;\"\u{201C}\u{201D}"))
        body = RioText.collapseWhitespace(body)
        return body.isEmpty ? nil : body
    }

    // MARK: Reply

    private static func parseReply(_ text: String) -> RioAction? {
        let reply = #"^reply\s+(?:to\s+(?:this|that|them|him|her|it|the\s+message|the\s+conversation)\s+)?(?:back\s+)?"# + connector + #"(.+)$"#
        if let groups = RioText.firstMatch(reply, in: text), let body = cleanBody(groups[1]) {
            return .replyInConversation(body: body)
        }
        if let groups = RioText.firstMatch(#"^tell\s+(?:them|him|her)\s+(?:that\s+)?(.+)$"#, in: text),
           let body = cleanBody(groups[1]) {
            return .replyInConversation(body: body)
        }
        return nil
    }

    // MARK: Reading

    private static func parseReading(_ s: String) -> RioAction? {
        if RioText.matches(#"^read\s+(?:me\s+)?(?:my|the)\s+(?:last|latest|newest|most recent)\s+(?:message|text|imessage|dm)$"#, s)
            || RioText.matches(#"^what did\s+(?:he|she|they)\s+(?:just\s+)?say$"#, s) {
            return .readAloud(.lastMessage)
        }
        if RioText.matches(#"^read\s+(?:me\s+)?(?:this|the)\s+(?:page|article|website|webpage|web page|site|post)$"#, s) {
            return .readAloud(.page)
        }
        if RioText.matches(#"^read\s+(?:me\s+)?(?:the|my|this)\s+(?:selection|selected text|highlighted text)(?:\s+to me)?$"#, s)
            || RioText.matches(#"^read\s+(?:the\s+)?(?:selection|highlighted text)$"#, s)
            || RioText.matches(#"^read\s+(?:me\s+)?(?:the\s+)?highlighted(?:\s+text)?$"#, s)
            || RioText.matches(#"^read\s+(?:this|that|it)\s+(?:out\s+)?(?:loud|aloud)$"#, s) {
            return .readAloud(.selection)
        }
        return nil
    }

    // MARK: Selection tasks

    private static func parseSelectionTask(_ s: String) -> RioAction? {
        if RioText.matches(#"^(?:summarize|summarise|sum up|tldr)\s+"# + subject + "$", s) { return .selectionTask(.summarize) }
        if RioText.matches(#"^explain\s+"# + subject + #"(?:\s+to me)?$"#, s) { return .selectionTask(.explain) }
        let translate = #"^translate\s+(?:"# + subject + #"\s+)?(?:to|into|in)\s+([a-z]+(?:\s+[a-z]+)?)$"#
        if let groups = RioText.firstMatch(translate, in: s), let language = groups[1] {
            let lower = language.lowercased()
            if lower == "please" || lower.hasSuffix(" please") { return nil }
            return .selectionTask(.translate(language: language.capitalized))
        }
        if RioText.matches(#"^(?:improve|proofread|polish|rewrite|clean up)\s+(?:"# + subject + #"|the writing|my writing)(?:\s+(?:better|please))?$"#, s)
            || RioText.matches(#"^fix\s+(?:the\s+|my\s+)?(?:grammar|spelling|grammar and spelling|spelling and grammar)(?:\s+(?:in|of|on)\s+"# + subject + ")?$", s) {
            return .selectionTask(.improve)
        }
        return nil
    }

    // MARK: Text a contact

    private static let notRecipients: Set<String> = [
        "me", "it", "them", "him", "her", "back", "this", "that", "a", "an", "the", "my", "us", "you",
        "everyone", "everybody", "now", "later", "editor", "size", "message", "messages",
    ]
    private static let relations: Set<String> = [
        "mom", "mum", "dad", "bro", "sis", "wife", "husband", "grandma", "grandpa", "mama", "baba",
        "mommy", "daddy", "sister", "brother", "boss", "partner",
    ]

    private static let sendPrefix = #"^(?:send\s+(?:an?\s+)?(?:text|message|imessage|i message|sms)(?:\s+message)?\s+to|text|message|imessage)\s+"#

    private static func parseMessage(_ text: String) -> RioAction? {
        let withConnector = sendPrefix + #"(.+?)\s*"# + connector + #"(.+)$"#
        if let groups = RioText.firstMatch(withConnector, in: text),
           let to = recipient(groups[1], maxWords: 2), let body = cleanBody(groups[2]) {
            return .sendMessage(to: to, body: body)
        }
        // "text Ali I'll be late": one-word name, no connector.
        let bare = sendPrefix + #"(\S+)\s+(.+)$"#
        if let groups = RioText.firstMatch(bare, in: text), let first = groups[1],
           looksLikeBareName(first), let to = recipient(first, maxWords: 1), let body = cleanBody(groups[2]),
           !RioText.matches(#"^(?:saying|that says|says|that|with)$"#, body) {
            return .sendMessage(to: to, body: body)
        }
        return nil
    }

    private static func looksLikeBareName(_ word: String) -> Bool {
        let cleaned = word.trimmingCharacters(in: CharacterSet.letters.inverted)
        guard let first = cleaned.first else { return false }
        return first.isUppercase || relations.contains(cleaned.lowercased())
    }

    /// A plausible contact name (1-2 words of letters), phone number or email; nil otherwise.
    private static func recipient(_ raw: String?, maxWords: Int) -> String? {
        guard let raw else { return nil }
        let value = RioText.collapseWhitespace(raw.trimmingCharacters(in: CharacterSet(charactersIn: " ,:.")))
        guard !value.isEmpty, value.count <= 60 else { return nil }
        if RioText.matches(#"^[+\d][\d\s\-\(\)\.]{5,}\d$"#, value) { return value }
        if RioText.matches(#"^[^\s@;|&$`<>]+@[^\s@;|&$`<>]+\.[A-Za-z]{2,}$"#, value) { return value }
        let words = value.split(separator: " ").map(String.init)
        guard words.count <= maxWords else { return nil }
        for word in words {
            guard RioText.matches(#"^[\p{L}][\p{L}'’\-\.]*$"#, word) else { return nil }
            if notRecipients.contains(word.lowercased()) { return nil }
        }
        return value
    }
}
