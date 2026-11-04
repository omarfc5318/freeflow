import Foundation

// Round 3 phrasing rules for the core parser: take-backs ("quit Safari, wait no"), searches
// scoped to the Mac or the code ("search my files for X"), Claude Code without "tell", and
// "do the same for Warp" over a whole chained command. Pure, Foundation only.
extension RioActionParser {
    // MARK: Take-backs

    /// Words that take back what was just said. "oops", "sorry" and "actually" only count next to
    /// one of these ("quit Chrome. Oops, no.").
    private static let takeBackWords =
        #"(?:no+|nope|nah|don['\x{2019}]?t|do\s+not|wait(?:\s+a\s+(?:sec(?:ond)?|minute|moment))?|hold\s+on|hang\s+on|stop|never\s?mind|scratch\s+that|forget\s+(?:it|that)|cancel(?:\s+(?:that|it))?)"#
    private static let takeBackSoftWords = #"(?:oops|sorry|actually|oh|uh|um)"#
    private static let takeBackSeparators = "[\\s,.;:!?\u{2026}\\-]"

    /// Words a command never ends on, so a take-back word after them is the command's own object
    /// ("remind me to stop", "add a note saying no", "search for hold on").
    private static let danglingEnds: Set<String> = [
        "to", "the", "a", "an", "my", "your", "for", "of", "with", "called", "named", "titled", "song", "say",
        "saying", "says", "tell", "reply", "answer", "that", "word", "about", "like", "by", "from", "and", "or",
        "is", "was", "are", "were",
    ]

    /// "quit Safari, wait no", "close Chrome no stop", "open Chrome... hold on": the command
    /// before the take-back, or nil when there is no take-back at the end. The caller drops the
    /// last clause of what is returned, or everything after "never mind" (findings 37, 38a). A message or typed text keeps its words
    /// ("tell him no"), a bare verb keeps its object ("play hold on"), and a song or video needs a
    /// pause before the take-back ("play the song hold on" plays it).
    static func trailingTakeBack(_ body: String) -> (remainder: String, cancelsAll: Bool)? {
        let word = "(?:\(takeBackWords)|\(takeBackSoftWords))(?![\\p{L}\\p{N}'\u{2019}])"
        let tailPattern = "(?:\(takeBackSeparators)+\(word))+\(takeBackSeparators)*$"
        guard let tail = RioText.firstMatch(tailPattern, in: body)?[0],
              RioText.matches("(?<![\\p{L}])\(takeBackWords)(?![\\p{L}\\p{N}'\u{2019}])", tail) else { return nil }
        let remainder = String(body.dropLast(tail.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:!?\u{2026}-\n\t"))
        let words = remainder.split(whereSeparator: \.isWhitespace)
        guard let last = words.last else { return nil }
        let punctuated = RioText.matches("^\\s*[,.;:!?\u{2026}-]", tail)
        if words.count == 1, !punctuated { return nil }
        if danglingEnds.contains(last.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "'\u{2019}\""))) { return nil }
        // "stop, stop" and "no, wait" are a stop on their own, not a take-back of one.
        if RioText.matches("^(?:(?:\(takeBackWords)|\(takeBackSoftWords))\(takeBackSeparators)*)+$", remainder) { return nil }
        if !punctuated, RioText.matches(#"^(?:play|put\s+on|watch|listen\s+to|queue)\b"#, remainder) { return nil }
        if RioText.matches(#"^(?:search(?:\s+for)?|google|look\s+(?:up|for))$"#, remainder) { return nil }
        // "text Ali saying wait no": the words belong to the message.
        if let lastPart = splitClauseParts(normalizingKeyCombos(remainder)).last,
           startsGreedyCommand(lastPart.text), !RioText.matches(searchStartPattern, lastPart.text) {
            return nil
        }
        // "open Chrome and Warp never mind" takes the whole thing back, as with a pause before it.
        let cancelsAll = RioText.matches(#"(?:never\s?mind|forget\s+(?:it|that)|scratch\s+that|cancel\s+that)"#, tail)
        return (remainder, cancelsAll)
    }

    // MARK: Scoped searches

    /// Where a search looks when it names the Mac rather than the web.
    private static let localScope =
        #"(?:my\s+|the\s+|this\s+)?(?:files?|documents?|docs|computer|mac|laptop|downloads?(?:\s+folder)?|desktop|notes|hard\s+drive|disk)"#
    /// Where a search looks when it names code: the editor's own search, so the resolver plans it.
    private static let codeScope =
        #"(?:my\s+|the\s+|this\s+|our\s+)?(?:code\s?base|repo(?:sitory)?|project|folder|workspace|directory|code|source(?:\s+code)?)"#

    private static func scopedQuery(_ text: String, scope: String) -> String? {
        let patterns = [
            "^search\\s+(?:through\\s+|in\\s+|across\\s+)?\(scope)\\s+for\\s+(.+)$",
            "^search\\s+(?:for\\s+)?(.+?)\\s+(?:in|on|across|through)\\s+\(scope)$",
        ]
        for pattern in patterns {
            if let query = RioText.firstMatch(pattern, in: text)?[1] {
                let cleaned = query.trimmingCharacters(in: CharacterSet(charactersIn: " .!;:\"?"))
                return cleaned.isEmpty ? nil : RioText.collapseWhitespace(cleaned)
            }
        }
        return nil
    }

    /// "search my files for eigenvalue": a file search for the query, never Google (finding 5).
    static func localScopeSearch(_ text: String) -> RioAction? {
        scopedQuery(text, scope: localScope).map { .revealFile(query: $0) }
    }

    /// Where a search looks when it names one of the owner's apps or accounts: the resolver plans
    /// it there ("search my email for the invoice").
    private static let appScope =
        #"(?:my\s+|the\s+)?(?:e-?mails?|mail|inbox|messages|texts|chats?|slack|calendar|photos|pictures|music|spotify|drive|google\s+drive|dropbox|notion|contacts)"#

    /// "search the codebase for useAuth", "search my email for the invoice": not a web search.
    /// The resolver plans it in the editor or the app.
    static func isCodeScopeSearch(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: CharacterSet(charactersIn: " .!,;:"))
        return scopedQuery(text, scope: codeScope) != nil || scopedQuery(text, scope: appScope) != nil
    }

    private static let pronoun = #"(?:it|that|this|them|those|these|that\s+one|this\s+one)"#

    /// "that", "it" or "this" as the whole query is a pointer, never words to search for
    /// (finding 40): the follow-up rewriter (after a search) or the resolver decides.
    static func isPronounQuery(_ query: String) -> Bool {
        RioText.matches("^\(pronoun)$", query)
    }

    /// "search that on Amazon", "search YouTube for it", "google that", "look that up".
    static func isPronounSearch(_ text: String) -> Bool {
        let patterns = [
            "^(?:search(?:\\s+for)?|look\\s+up|look\\s+for|google|find)\\s+\(pronoun)(?:\\s+(?:on|in)\\s+.+)?$",
            "^look\\s+\(pronoun)\\s+up(?:\\s+(?:on|in)\\s+.+)?$",
            "^search\\s+(?:on\\s+|in\\s+)?.+?\\s+for\\s+\(pronoun)$",
        ]
        return patterns.contains { RioText.matches($0, text) }
    }

    // MARK: Claude Code at the start

    /// What "Claude" (or a mishearing of it) must be followed by to count: an instruction verb.
    private static let claudeInstructionVerbs =
        #"(?:run|add|fix|make|write|create|build|test|commit|push|pull|check|refactor|update|delete|remove|rename|explain|implement|review|deploy|install|continue|use|change|try|debug|generate|merge|revert|clean|format|lint|set|open|show|undo|rewrite|split|move|find|read|keep|look|start|finish|document|optimi[sz]e|convert|migrate|bump|rebase|stash|can|could|please)"#
    private static let claudeHeard = #"(?:claude|cloud|clod|claud|clawed|cloude)"#

    /// "Claude run the tests", "cloud code status", "ask Claude how do I center a div",
    /// "tell Claude thanks": Claude Code without a comma or "to" (finding 65). "open the cloud
    /// console" and "what's a cloud" are not about Claude.
    static func claudeAtStart(_ body: String) -> RioAction? {
        let line = body.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t"))
        if let rest = RioText.firstMatch("^(?:please\\s+)?\(claudeHeard)(?:\\s+code)?[\\s,:]+(.+)$", in: line)?[1] {
            if RioText.matches(#"^status[\s.?!]*$"#, rest) { return .claudeCode(.status) }
            // "Claude is great" is not an instruction: only a verb after the name counts.
            guard RioText.matches("^\(claudeInstructionVerbs)\\b", rest) else { return nil }
            let comma = "Claude, \(rest)"
            return RioMeetingPhrases.parse(raw: comma, simplified: RioText.simplify(comma))
        }
        // "ask Claude how do I center a div" goes to Claude Code, never answered by Rio himself.
        if let rest = RioText.firstMatch("^(?:please\\s+)?ask\\s+(?:the\\s+)?\(claudeHeard)(?:\\s+code)?[\\s,:]+(.+)$", in: line)?[1] {
            return RioClaudeSend.sanitise(rest.trimmingCharacters(in: CharacterSet(charactersIn: " ."))).map { .claudeCode(.send($0)) }
        }
        // "tell Claude thanks": the thanks is the message (finding 22).
        if let thanks = RioText.firstMatch("^(?:please\\s+)?tell\\s+(?:the\\s+)?\(claudeHeard)(?:\\s+code)?[\\s,:]+(thanks|thank\\s+you)[\\s.!]*$", in: line)?[1] {
            return .claudeCode(.send(thanks))
        }
        return nil
    }

    // MARK: Message verbs

    /// "say", "tell Ahmed", "respond": a message verb with nothing after it. A trailing "thanks"
    /// that would leave one of these is the message itself (finding 22).
    static func isBareMessageVerb(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,.!;:\n\t"))
        return RioText.matches(#"^(?:say|respond|reply|answer|tell\s+\S+(?:\s+code)?|text\s+\S+|message\s+\S+|reply\s+to\s+\S+)$"#, trimmed)
    }

    // MARK: Follow-ups inside one utterance

    /// "open Notes and make it full screen": "it" is Notes, never an app from an earlier command
    /// (finding 39).
    static func makeItBigger(_ raw: String, app: String?) -> ParsedClause? {
        guard let app, RioFollowUpRewriter.isMakeItBigger(RioText.simplify(raw)) else { return nil }
        return ParsedClause(action: .window(WindowCommand(appName: app, placement: .maximize)), verb: nil)
    }

    /// "Open Chrome and put it on the left", then "do the same for Warp": open Warp and put it on
    /// the left (finding 42). Nil unless the last command had several steps about one app.
    func sameForChain(_ raw: String) -> ParsedClause? {
        let simplified = RioText.simplify(raw)
        // Only a "same for" phrase reads the follow-up memory.
        guard RioFollowUpRewriter.sameForTargetText(simplified) != nil,
              let (target, chain) = RioFollowUpRewriter.sameForChain(simplified, context: RioFollowUpMemory.shared.snapshot()),
              let opened = parseAppVerb("open \(target)", inherited: false),
              case .openApp(let app) = opened.action else { return nil }
        let steps = RioFollowUpRewriter.substitutingApp(app, in: chain)
        guard let first = steps.first else { return nil }
        return ParsedClause(action: first, verb: nil, isConfident: opened.isConfident, more: Array(steps.dropFirst()))
    }
}
