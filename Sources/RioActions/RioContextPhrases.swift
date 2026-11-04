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

    /// "this theorem", "that slide", "the selected code": a pointer plus one or two noun words,
    /// with no verb or clause after it (finding 8a). Not the screen, page or window (the screen
    /// parser describes those), a meeting or call (the copilot), or a time ("this week").
    private static let pointedThing: String = {
        let notNouns = "to|for|and|or|with|in|on|at|of|from|about|by|into|me|us|him|her|them|you|it|please|again|now|so|"
            + "because|like|is|was|are|were|be|but|then|than|as|if|when|which|who|whats|what|how|why|im|youre|"
            + "screen|page|webpage|web|window|tab|website|site|desktop|display|meeting|call|"
            + "week|weekend|month|year|morning|afternoon|evening|night|day|semester|quarter|time"
        let noun = "(?!(?:\(notNouns))\\b)[a-z][a-z0-9]*"
        return "(?:(?:this|that|the selected|the highlighted)\\s+\(noun)(?:\\s+\(noun))?)"
    }()

    /// The selection named outright: never a bare this/that/it (those mean the last dictation for edits).
    private static let namedSelection =
        #"(?:the selection|my selection|selection|the selected text|selected text|this text|that text|the text|what i selected|the highlighted text|the paragraph|this (?:paragraph|email|message|article|code|error|passage|sentence|section|snippet))"#

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
            // "reply with a thumbs up" sends the emoji, not the words.
            let saidWith = RioText.matches(#"^reply\s+(?:to\s+\S+(?:\s+\S+)?\s+)?(?:back\s+)?with\b"#, text)
            return .replyInConversation(body: saidWith ? emoji(for: body) ?? body : body)
        }
        if let groups = RioText.firstMatch(#"^tell\s+(?:them|him|her)\s+(?:that\s+)?(.+)$"#, in: text),
           let body = cleanBody(groups[1]) {
            return .replyInConversation(body: body)
        }
        return nil
    }

    private static let emojiNames: [(pattern: String, emoji: String)] = [
        (#"^(?:a\s+)?thumbs?\s+up(?:\s+emoji)?$"#, "\u{1F44D}"), (#"^(?:a\s+)?thumbs?\s+down(?:\s+emoji)?$"#, "\u{1F44E}"),
        (#"^(?:a\s+)?(?:red\s+)?heart(?:\s+emoji)?$"#, "\u{2764}\u{FE0F}"),
        (#"^(?:a\s+)?(?:smiley(?:\s+face)?|smile|smiling\s+face)(?:\s+emoji)?$"#, "\u{1F642}"),
        (#"^(?:a\s+)?(?:laughing|crying\s+laughing|lol)(?:\s+(?:face|emoji))+$"#, "\u{1F602}"),
        (#"^(?:a\s+)?(?:thank\s+you|praying|pray)\s+(?:hands|emoji)$"#, "\u{1F64F}"),
        (#"^(?:an?\s+)?(?:ok|okay)\s+(?:hand|sign|emoji)$"#, "\u{1F44C}"),
    ]

    /// "a thumbs up" -> the emoji, when that is the whole body.
    private static func emoji(for body: String) -> String? {
        emojiNames.first { RioText.matches($0.pattern, body) }?.emoji
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
        let thing = "(?:" + subject + "|" + pointedThing + ")"
        if RioText.matches(#"^(?:summarize|summarise|sum up|tldr)\s+"# + thing + "$", s) { return .selectionTask(.summarize) }
        if RioText.matches(#"^explain\s+"# + thing + #"(?:\s+to me)?$"#, s) { return .selectionTask(.explain) }
        // "what does this mean", "explain what this means", "solve this problem": explain the
        // selection (or the window when nothing is selected). "What does this error mean" stays
        // with the screen parser, which reads the error off the screen.
        if RioText.matches(#"^(?:what\s+does\s+|explain\s+what\s+)(?:this|that|it)\s+means?$"#, s)
            || RioText.matches(#"^(?:solve|help\s+me\s+(?:with|solve|understand))\s+"# + thing + "$", s) {
            return .selectionTask(.explain)
        }
        let translate = #"^translate\s+(?:"# + subject + #"\s+)?(?:to|into|in)\s+([a-z]+(?:\s+[a-z]+)?)$"#
        if let groups = RioText.firstMatch(translate, in: s), let language = groups[1] {
            let lower = language.lowercased()
            if lower == "please" || lower.hasSuffix(" please") { return nil }
            return .selectionTask(.translate(language: language.capitalized))
        }
        // Same rule as RioWritingPhrases: "improve that" / "fix the grammar" edit the last
        // dictation (#44, the writing parser claims them first); only a named selection is ours.
        if RioText.matches(#"^(?:improve|proofread|polish|rewrite|clean up)\s+(?:"# + namedSelection + #"|the writing|my writing)(?:\s+(?:better|please))?$"#, s)
            || RioText.matches(#"^fix\s+(?:the\s+|my\s+)?(?:grammar|spelling|grammar and spelling|spelling and grammar)\s+(?:in|of|on)\s+"# + namedSelection + "$", s) {
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

    /// Other messaging apps: `.sendMessage` is iMessage/SMS only, so "text Mom on WhatsApp ..." is
    /// left to the resolver (switch to the app) instead of going out over iMessage.
    private static let otherApps =
        #"(?:whats\s?app|slack|telegram|signal|discord|(?:microsoft\s+|ms\s+)?teams|(?:facebook\s+)?messenger|instagram|insta|snapchat|wechat|viber|linkedin)"#
    /// "on iMessage", "by text": the default channel, said out loud.
    private static let defaultChannel = #"\s+(?:on|via|in|over|through|using|by)\s+(?:i\s?message|imessages?|messages|text|sms)$"#

    private static func parseMessage(_ text: String) -> RioAction? {
        let withConnector = sendPrefix + #"(.+?)\s*"# + connector + #"(.+)$"#
        if let groups = RioText.firstMatch(withConnector, in: text), let head = groups[1] {
            if RioText.matches(#"\s(?:on|via|in|over|through|using)\s+(?:my\s+|the\s+)?"# + otherApps + #"(?:\s+app)?$"#, head) { return nil }
            let named = RioText.replacing(defaultChannel, with: "", in: head)
            if let to = recipient(named, maxWords: 2), let body = cleanBody(groups[2]) {
                return .sendMessage(to: to, body: body)
            }
        }
        // "text Ali I'll be late": one-word name, no connector.
        let bare = sendPrefix + #"(\S+)\s+(.+)$"#
        if let groups = RioText.firstMatch(bare, in: text), let first = groups[1],
           looksLikeBareName(first), let to = recipient(first, maxWords: 1), let body = cleanBody(groups[2]),
           !RioText.matches(#"^(?:saying|that says|says|that|with)$"#, body),
           // "text mom on WhatsApp saying I'm home": the app is not the message.
           !RioText.matches(#"^(?:on|via|in|over|through|using)\s+(?:my\s+|the\s+)?"# + otherApps + #"\b"#, body) {
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
