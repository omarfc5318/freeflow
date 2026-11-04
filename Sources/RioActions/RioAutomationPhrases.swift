import Foundation

/// Phrases for scheduled commands, triggers and macros (builder P). Pure, no AppKit. Every pattern
/// is anchored and needs a command verb of its own, so "set a timer for 20 minutes", "remind me in
/// 20 minutes to call mom", "stop recording" (the meeting) and "what's my schedule" are not ours.
enum RioAutomationPhrases {
    static func parse(raw: String, simplified: String) -> RioAction? {
        let text = tidy(raw)
        guard !text.isEmpty else { return nil }
        let lower = RioText.simplify(text).lowercased()
        return list(lower) ?? stopRecording(lower) ?? record(text) ?? runMacro(text) ?? remove(text)
            ?? trigger(text) ?? schedule(text)
    }

    private static func tidy(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t\"\u{201C}\u{201D}"))
        text = RioText.replacing(#"[,\s]+(?:please|thanks|thank you)[\s.!]*$"#, with: "", in: text)
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " .!?\n\t"))
    }

    /// Verbs a scheduled or triggered command can start with.
    private static let verbs: Set<String> = [
        "open", "quit", "close", "lock", "mute", "unmute", "turn", "set", "play", "pause", "resume", "text",
        "message", "send", "run", "start", "stop", "hide", "launch", "switch", "take", "screenshot", "dim",
        "toggle", "enable", "disable", "put", "skip", "show", "tell", "call", "remind", "read", "email",
        "brighten", "raise", "lower", "go", "search", "type", "press", "join", "empty",
    ]

    private static func startsWithVerb(_ command: String) -> Bool {
        guard let first = command.split(separator: " ").first else { return false }
        let word = String(first).lowercased().trimmingCharacters(in: .punctuationCharacters)
        guard verbs.contains(word) else { return false }
        // Timers, alarms and reminders with their own time belong to the voice and reminder parsers.
        return !RioText.matches(#"^set\s+(?:a|an|the|my)?\s*(?:timer|alarm|reminder|countdown)\b"#, command)
    }

    /// Commands whose words after the verb are a message or a prompt.
    private static let messageVerbs: Set<String> = ["text", "message", "tell", "reply", "send", "email", "write", "type", "ask"]

    private static func startsWithMessageVerb(_ command: String) -> Bool {
        guard let first = command.split(separator: " ").first else { return false }
        return messageVerbs.contains(String(first).lowercased().trimmingCharacters(in: .punctuationCharacters))
    }

    // MARK: Splitting "<when or trigger> <command>"

    /// Splits at the first comma, else at the first command verb at or after `minIndex`.
    private static func split(_ text: String, minIndex: Int) -> (head: String, command: String)? {
        if let comma = text.firstIndex(of: ",") {
            let head = String(text[..<comma])
            let command = cleanCommand(String(text[text.index(after: comma)...]))
            return startsWithVerb(command) ? (head, command) : nil
        }
        let words = text.split(separator: " ").map(String.init)
        guard words.count > minIndex else { return nil }
        for index in minIndex..<words.count {
            let word = words[index].lowercased().trimmingCharacters(in: .punctuationCharacters)
            guard verbs.contains(word) else { continue }
            let command = cleanCommand(words[index...].joined(separator: " "))
            if startsWithVerb(command) { return (words[..<index].joined(separator: " "), command) }
        }
        return nil
    }

    private static func cleanCommand(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:"))
        return RioText.replacing(#"^(?:then|and then|to|and)\s+"#, with: "", in: trimmed)
    }

    private static func cleanHead(_ text: String) -> String {
        let head = RioText.replacing(#"\s+(?:to|and|then)$"#, with: "", in: text.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:")))
        return head
    }

    // MARK: Scheduled commands

    private static let whenStart = #"^(?:every|each|daily|weekdays|weekly|in\s+\S+\s+(?:minutes?|mins?|hours?|hrs?)\b|at\s+\d|tomorrow|tonight|on\s+(?:mon|tues|wednes|thurs|fri|satur|sun)day|next\s+\w+day)"#
    private static let scheduleLead = #"^(?:please\s+)?(?:schedule|automate|set\s+up\s+a\s+schedule(?:\s+to)?)\s*[:,]?\s*(?:a\s+command\s*)?"#
    private static let trailingWhenAlways = #"^(.+?)\s+((?:every|each)\s+.+|daily(?:\s+.+)?|weekdays(?:\s+.+)?|in\s+(?:\d+|an?|one|two|three|four|five|ten|fifteen|twenty|thirty|forty five|a couple of)\s+(?:minutes?|mins?|hours?|hrs?))$"#
    private static let trailingWhenScheduled = #"^(.+?)\s+((?:every|each)\s+.+|daily(?:\s+.+)?|weekdays(?:\s+.+)?|in\s+\S+\s+(?:minutes?|mins?|hours?|hrs?)|at\s+\d.*|tomorrow.*|tonight.*)$"#

    private static func schedule(_ text: String) -> RioAction? {
        let stripped = RioText.replacing(scheduleLead, with: "", in: text)
        let hadSchedule = stripped != text
        let body = stripped.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }

        if RioText.matches(whenStart, body), let parts = split(body, minIndex: 1) {
            let head = cleanHead(parts.head)
            guard RioText.matches(whenStart, head) else { return nil }
            return make(command: parts.command, when: head)
        }
        guard startsWithVerb(body) else { return nil }
        // "text Sarah I'll be home in 20 minutes": time words at the end belong to the message.
        // A message is scheduled only with "schedule" or a leading time ("in 10 minutes, text mom").
        if !hadSchedule, startsWithMessageVerb(body) { return nil }
        let pattern = hadSchedule ? trailingWhenScheduled : trailingWhenAlways
        if let groups = RioText.firstMatch(pattern, in: body), let command = groups[1], let when = groups[2] {
            return make(command: cleanCommand(command), when: when)
        }
        return nil
    }

    private static func make(command: String, when: String) -> RioAction? {
        guard startsWithVerb(command) else { return nil }
        var whenText = when.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        whenText = RioText.replacing(#"\b([ap])\.\s?m\.?"#, with: "$1m", in: whenText)
        whenText = whenText.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:"))
        return .scheduleCommand(command: command, when: RioText.collapseWhitespace(whenText))
    }

    // MARK: Triggers

    private static let triggerLead = #"^(?:when|whenever|once|every\s+time|each\s+time)\s+"#
    private static let triggerTrail = #"^(.+?)\s+(?:when|whenever|every\s+time|each\s+time)\s+(.+)$"#

    private static func trigger(_ text: String) -> RioAction? {
        if RioText.matches(triggerLead, text) {
            let rest = RioText.replacing(triggerLead, with: "", in: text)
            guard let parts = split(rest, minIndex: 2), let kind = classify(parts.head) else { return nil }
            return .addTrigger(command: parts.command, trigger: kind.spec)
        }
        guard startsWithVerb(text), let groups = RioText.firstMatch(triggerTrail, in: text),
              let command = groups[1], let head = groups[2], startsWithVerb(command),
              let kind = classify(head) else { return nil }
        return .addTrigger(command: cleanCommand(command), trigger: kind.spec)
    }

    private static let article = #"(?:my\s+|the\s+|a\s+|an\s+)?"#

    private static func classify(_ head: String) -> RioTriggerKind? {
        let text = RioText.replacing(#"^i\s+"#, with: "", in: head.trimmingCharacters(in: .whitespaces))
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:"))
        return display(text) ?? wifi(text) ?? audio(text)
    }

    private static func display(_ text: String) -> RioTriggerKind? {
        let thing = #"(?:external\s+|second\s+|another\s+)?(?:display|monitor|screen)s?"#
        let a = #"^(?:connect|plug\s+in|plug|attach|hook\s+up)\s+(?:(?:to|into)\s+)?\#(article)\#(thing)$"#
        let b = #"^\#(article)\#(thing)\s+(?:connects?|is\s+connected|is\s+plugged\s+in|gets\s+connected|plugs\s+in|gets\s+plugged\s+in)$"#
        return RioText.matches(a, text) || RioText.matches(b, text) ? .displayConnected : nil
    }

    private static func wifi(_ text: String) -> RioTriggerKind? {
        let fi = #"wi[\s-]?fi"#
        let verb = #"(?:join|joins|connect\s+to|connects\s+to|get\s+on|am\s+on)"#
        let patterns = [
            #"^\#(verb)\s+(?:the\s+|my\s+)?\#(fi)(?:\s+network)?\s*(?:called|named)?\s+(.+)$"#,
            #"^\#(verb)\s+(?:the\s+|my\s+)?network\s*(?:called|named)?\s+(.+)$"#,
            #"^\#(verb)\s+(?:the\s+)?(.+?)\s+(?:\#(fi)|network)$"#,
        ]
        for pattern in patterns {
            if let groups = RioText.firstMatch(pattern, in: text), let name = groups[1]?.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")),
               !name.isEmpty, name.split(separator: " ").count <= 5 {
                return .wifi(ssid: name)
            }
        }
        return nil
    }

    private static func audio(_ text: String) -> RioTriggerKind? {
        let patterns = [
            #"^(?:connect|plug\s+in|put\s+on|pair\s+with|pair)\s+\#(article)(.+)$"#,
            #"^\#(article)(.+?)\s+(?:connects?|connected|is\s+connected|pairs|is\s+paired|gets\s+connected)$"#,
        ]
        for pattern in patterns {
            guard let groups = RioText.firstMatch(pattern, in: text), let name = groups[1]?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty, name.split(separator: " ").count <= 4,
                  !RioText.matches(#"^(?:to|into|up|in|on)\b|\b(?:vpn|wifi|wi-fi|network|internet|bluetooth|server|account)\b"#, name),
                  !RioText.matches(#"^(?:display|monitor|screen)s?$"#, name) else { continue }
            return .audioOutput(name: name)
        }
        return nil
    }

    // MARK: List and remove

    private static func list(_ s: String) -> RioAction? {
        let nouns = #"(?:automations?|macros?|triggers?|scheduled\s+commands?|scheduled\s+tasks?)"#
        let patterns = [
            #"^(?:list|show|show\s+me|read|tell\s+me|what\s+are|whats|what\s+is)\s+(?:all\s+)?(?:of\s+)?(?:my\s+|the\s+)?\#(nouns)$"#,
            #"^what\s+\#(nouns)\s+do\s+i\s+have(?:\s+set\s+up)?$"#,
            #"^do\s+i\s+have\s+any\s+\#(nouns)$"#,
        ]
        return patterns.contains { RioText.matches($0, s) } ? .listAutomations : nil
    }

    private static let datey = #"^(?:today|tomorrow|tonight|this|next|monday|tuesday|wednesday|thursday|friday|saturday|sunday|the week|the day)\b"#

    private static func remove(_ text: String) -> RioAction? {
        let verb = #"(?:remove|delete|cancel|stop|turn\s+off)"#
        let noun = #"(?:automation|schedule|scheduled\s+command|trigger|macro)"#
        let patterns = [
            #"^\#(verb)\s+(?:the\s+|my\s+)?\#(noun)\s+(?:called\s+|named\s+|for\s+)?(.+)$"#,
            #"^\#(verb)\s+(?:the\s+|my\s+)(.+?)\s+\#(noun)$"#,
        ]
        for pattern in patterns {
            guard let groups = RioText.firstMatch(pattern, in: text), let name = clean(groups[1]), !name.isEmpty,
                  !RioText.matches(datey, name) else { continue }
            return .removeAutomation(name: name)
        }
        return nil
    }

    // MARK: Macros

    private static func clean(_ name: String?) -> String? {
        let result = name?.trimmingCharacters(in: CharacterSet(charactersIn: " \"'\u{201C}\u{201D}.,!?"))
        return result.map(RioText.collapseWhitespace)
    }

    private static func record(_ text: String) -> RioAction? {
        let patterns = [
            #"^(?:start\s+|begin\s+)?(?:recording|record)\s+(?:a\s+|an\s+|new\s+)?(?:new\s+)?macro(?:\s+(?:called|named)\s+(.+))?$"#,
            #"^watch\s+me(?:\s+(?:and\s+)?(?:call|name)\s+it\s+(.+))?$"#,
            #"^learn\s+(?:this|a)\s+macro(?:\s+(?:called|named)\s+(.+))?$"#,
        ]
        for pattern in patterns {
            if let groups = RioText.firstMatch(pattern, in: text) { return .recordMacro(name: clean(groups[1]) ?? "") }
        }
        return nil
    }

    private static func stopRecording(_ s: String) -> RioAction? {
        let patterns = [
            #"^(?:stop|end|finish)\s+(?:recording|watching)\s+(?:the\s+|my\s+|this\s+)?macro$"#,
            #"^(?:stop|done)\s+watching(?:\s+me)?$"#,
        ]
        return patterns.contains { RioText.matches($0, s) } ? .stopRecordingMacro : nil
    }

    private static func runMacro(_ text: String) -> RioAction? {
        let verb = #"(?:run|play\s+back|playback|replay|do|play|start)"#
        let patterns = [
            #"^\#(verb)\s+(?:the\s+|my\s+)?macro\s+(?:called\s+|named\s+)?(.+)$"#,
            #"^\#(verb)\s+(?:the\s+|my\s+)?(.+?)\s+macro$"#,
        ]
        for pattern in patterns {
            if let groups = RioText.firstMatch(pattern, in: text), let name = clean(groups[1]), !name.isEmpty {
                return .runMacro(name: name)
            }
        }
        return nil
    }
}
