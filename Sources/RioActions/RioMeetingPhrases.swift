import Foundation

/// Phrases for the meeting copilot and Claude Code by voice (builder T). Pure, anchored on both
/// ends, and they only claim wordings that name the meeting, the call, the copilot or Claude, so
/// "stop listening", "summarize this" and "tell Ali I'm late" still reach their own parsers.
enum RioMeetingPhrases {
    static func parse(raw: String, simplified: String) -> RioAction? {
        let text = simplified.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!?,"))
        guard !text.isEmpty else { return nil }
        if let action = parseClaude(raw: raw, text: text) { return action }
        return parseMeeting(text)
    }

    private static func any(_ patterns: [String], _ text: String) -> Bool {
        patterns.contains { RioText.matches($0, text) }
    }

    // MARK: Claude Code

    /// "cloud", "claud" and "clod" are how speech-to-text often hears "Claude".
    private static let claudeName = #"(?:claude|cloud|claud|clod)"#
    private static let claude = "\(claudeName)(?:\\s+code)?"
    private static let please = #"(?:(?:please|hey)\s+)?"#
    private static let yes = #"(?:(?:yes|yeah|yep|ok|okay|sure)\s+)?"#
    /// "tell Claude Code in Warp to run the linter".
    private static let place = #"(?:\s+(?:in|on)\s+(?:warp|the\s+terminal|terminal|iterm2?))?"#
    private static let thatIt = #"(?:that|it|this|the\s+(?:permission|request|prompt)|(?:claudes?|clouds?)\s+(?:request|permission))"#

    private static let approvePatterns = [
        "^\(please)\(yes)(?:go\\s+ahead\\s+and\\s+)?approve\\s+\(thatIt)$",
        "^\(please)\(yes)approve\\s+\(claude)$",
        "^\(please)\(claude)\\s+(?:yes\\s+)?approve(?:\\s+\(thatIt))?$",
        "^\(please)say\\s+yes\\s+to\\s+\(claude)$",
        "^\(please)tell\\s+\(claude)\\s+yes$",
    ]
    private static let denyPatterns = [
        "^\(please)(?:no\\s+)?(?:deny|reject|decline|refuse)\\s+\(thatIt)$",
        "^\(please)(?:no\\s+)?(?:dont|do\\s+not)\\s+approve\\s+\(thatIt)$",
        "^\(please)\(claude)\\s+(?:no\\s+)?(?:deny|reject)(?:\\s+\(thatIt))?$",
        "^\(please)say\\s+no\\s+to\\s+\(claude)$",
        "^\(please)tell\\s+\(claude)\\s+no$",
    ]
    private static let statusPatterns = [
        "^\(please)(?:whats|what is)\\s+\(claude)\\s+(?:doing|up to|working on)(?:\\s+right\\s+now)?$",
        "^\(please)(?:whats|what is|what does)\\s+\(claude)\\s+(?:asking|asking\\s+me|asking\\s+for|want|need|waiting\\s+for)(?:\\s+(?:me|right\\s+now|now))?$",
        "^\(please)(?:hows|how is)\\s+\(claude)\\s+doing$",
        "^\(please)check\\s+on\\s+\(claude)$",
        "^\(please)(?:is|has)\\s+\(claude)\\s+(?:done|finished|waiting|stuck)(?:\\s+(?:yet|already|for\\s+me))?$",
        "^\(please)does\\s+\(claude)\\s+need\\s+me$",
        "^\(please)ask\\s+\(claude)\\s+(?:what\\s+(?:its|it\\s+is|hes|he\\s+is)\\s+(?:doing|up\\s+to|working\\s+on)|how\\s+(?:its|it\\s+is)\\s+going)(?:\\s+(?:right\\s+)?now)?$",
    ]

    private static func parseClaude(raw: String, text: String) -> RioAction? {
        if any(denyPatterns, text) { return .claudeCode(.deny) }
        if any(approvePatterns, text) { return .claudeCode(.approve) }
        if any(statusPatterns, text) { return .claudeCode(.status) }
        return parseSend(raw)
    }

    /// "tell Claude (Code) to/that ...", "tell Claude no, use Supabase instead", "ask Claude Code
    /// ...", "ask Claude to ...". A plain question to Claude ("ask Claude what a monoid is") is not
    /// a coding task: it is left to the resolver, which can answer it or open the Claude app.
    private static func parseSend(_ raw: String) -> RioAction? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{2019}", with: "'")
        let patterns = [
            // "tell Claude no, use Supabase instead": the answer and the new instruction go together.
            "^\(please)tell\\s+\(claude)\(place)[,:]?\\s+((?:no|yes|nope)\\b[,.!]?\\s+.+)$",
            // "tell Claude to/that ...", "tell Claude Code in Warp to ...".
            "^\(please)tell\\s+\(claude)\(place)[,:]?\\s+(?:to|that)\\s+(.+)$",
            "^\(please)ask\\s+\(claudeName)\\s+code\(place)[,:]?\\s+(?:to\\s+)?(.+)$",
            "^\(please)ask\\s+\(claudeName)\(place)[,:]?\\s+to\\s+(.+)$",
        ]
        // "tell Claude: run the tests", "Claude, add a dark mode toggle" (a comma or colon after
        // a bare "Claude"). Without "to" the words must read as an instruction, never a menu answer.
        let barePatterns = [
            "^\(please)tell\\s+\(claude)\(place)[,:]?\\s+(.+)$",
            "^\(please)claude(?:\\s+code)?\\s*[,:]\\s+(.+)$",
        ]
        for (index, pattern) in (patterns + barePatterns).enumerated() {
            guard let groups = RioText.firstMatch(pattern, in: line), let body = groups[1] else { continue }
            if index >= patterns.count, !isInstruction(body) { return nil }
            let trailing = CharacterSet(charactersIn: ". !").union(.whitespaces)
            let stripped = body.trimmingCharacters(in: trailing)
            let isQuestion = body.trimmingCharacters(in: .whitespaces).hasSuffix("?")
            guard let prompt = RioClaudeSend.sanitise(isQuestion && !stripped.hasSuffix("?") ? stripped + "?" : stripped) else {
                return nil
            }
            return .claudeCode(.send(prompt))
        }
        return nil
    }

    /// Two or more words starting with a word, and not an answer to a permission menu
    /// ("yes", "1", "approve"): those stay with the approve and deny phrases.
    private static func isInstruction(_ body: String) -> Bool {
        let text = body.trimmingCharacters(in: .whitespaces)
        return RioText.matches(#"^\p{L}[\p{L}'\-]*[,]?\s+\S"#, text)
            && !RioText.matches(#"^(?:yes|yeah|yep|yup|no|nope|ok|okay|sure|approve|approved|deny|denied|allow|accept|reject|decline|continue|proceed|go\s+ahead|do\s+it)\b"#, text)
    }

    // MARK: Meeting copilot

    private static let meeting = #"(?:the\s+|this\s+|my\s+|our\s+)?(?:meeting|call)"#

    private static let startPatterns = [
        "^\(please)(?:start|begin|turn\\s+on|enable|activate|launch)\\s+(?:the\\s+)?(?:meeting\\s+)?copilot$",
        "^\(please)(?:start|begin)\\s+listening\\s+(?:to|in\\s+on)\\s+\(meeting)$",
        "^\(please)(?:record|start\\s+recording|begin\\s+recording)\\s+\(meeting)$",
        #"^meeting\s+copilot\s+on$"#,
    ]
    private static let stopPatterns = [
        "^\(please)(?:stop|end|turn\\s+off|disable|exit|quit|shut\\s+off)\\s+(?:the\\s+)?(?:meeting\\s+)?copilot$",
        "^\(please)stop\\s+listening\\s+to\\s+\(meeting)$",
        "^\(please)(?:stop|end)\\s+recording\\s+\(meeting)$",
        #"^meeting\s+copilot\s+off$"#,
    ]
    private static let saidPatterns = [
        #"^what\s+(?:did|have)\s+(?:they|he|she|everyone|everybody|people|the\s+speaker)\s+(?:just\s+)?(?:say|said)(?:\s+(?:just\s+)?now)?$"#,
        #"^what\s+(?:was|has\s+been)\s+(?:just\s+)?said(?:\s+(?:just\s+)?now)?$"#,
        #"^what\s+was\s+that\s+(?:they|he|she)\s+(?:just\s+)?said$"#,
        #"^what\s+(?:did\s+i\s+miss|have\s+i\s+missed)$"#,
        #"^catch\s+me\s+up$"#,
        #"^repeat\s+what\s+(?:they|he|she)\s+(?:just\s+)?said$"#,
    ]
    private static let actionPatterns = [
        "^(?:(?:what\\s+(?:are|were)|list|give\\s+me|show\\s+me|read\\s+me|any)\\s+)?(?:the\\s+|my\\s+|our\\s+)?action\\s+items(?:\\s+from\\s+\(meeting))?$",
    ]
    private static let recapPatterns = [
        "^\(please)(?:recap|summari[sz]e)\\s+\(meeting)$",
        "^\(please)(?:give\\s+me|show\\s+me)\\s+(?:a\\s+)?(?:meeting\\s+|call\\s+)?recap(?:\\s+of\\s+\(meeting))?$",
        #"^(?:meeting|call)\s+recap$"#,
        "^recap\\s+of\\s+\(meeting)$",
    ]

    private static func parseMeeting(_ text: String) -> RioAction? {
        if any(stopPatterns, text) { return .meeting(.stop) }
        if any(startPatterns, text) { return .meeting(.start) }
        if any(saidPatterns, text) { return .meeting(.whatWasSaid) }
        if any(actionPatterns, text) { return .meeting(.actionItems) }
        if any(recapPatterns, text) { return .meeting(.recap) }
        return nil
    }
}
