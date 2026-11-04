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

    private static let claude = #"claude(?:\s+code)?"#
    private static let please = #"(?:(?:please|hey)\s+)?"#
    private static let thatIt = #"(?:that|it|this|the\s+(?:permission|request|prompt)|claudes?\s+(?:request|permission))"#

    private static let approvePatterns = [
        "^\(please)approve\\s+\(thatIt)$",
        "^\(please)approve\\s+\(claude)$",
        "^\(please)say\\s+yes\\s+to\\s+\(claude)$",
        "^\(please)tell\\s+\(claude)\\s+yes$",
    ]
    private static let denyPatterns = [
        "^\(please)(?:deny|reject|decline|refuse)\\s+\(thatIt)$",
        "^\(please)say\\s+no\\s+to\\s+\(claude)$",
        "^\(please)tell\\s+\(claude)\\s+no$",
    ]
    private static let statusPatterns = [
        "^\(please)(?:whats|what is)\\s+\(claude)\\s+(?:doing|up to)(?:\\s+right\\s+now)?$",
        "^\(please)(?:hows|how is)\\s+\(claude)\\s+doing$",
        "^\(please)check\\s+on\\s+\(claude)$",
        "^\(please)is\\s+\(claude)\\s+(?:done|finished)$",
    ]

    private static func parseClaude(raw: String, text: String) -> RioAction? {
        if any(denyPatterns, text) { return .claudeCode(.deny) }
        if any(approvePatterns, text) { return .claudeCode(.approve) }
        if any(statusPatterns, text) { return .claudeCode(.status) }
        return parseSend(raw)
    }

    private static func parseSend(_ raw: String) -> RioAction? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{2019}", with: "'")
        let tell = "^\(please)tell\\s+\(claude)[,:]?\\s+(?:to|that)\\s+(.+)$"
        let ask = "^\(please)ask\\s+\(claude)[,:]?\\s+(?:to\\s+)?(.+)$"
        for pattern in [tell, ask] {
            guard let groups = RioText.firstMatch(pattern, in: line), let body = groups[1] else { continue }
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
