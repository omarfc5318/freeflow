import Foundation

/// "what's next", "what's on my calendar tomorrow", "join my next meeting",
/// "add study session tomorrow at 7 pm". Pure: `now` and the calendar are injected.
enum RioCalendarPhrases {
    private static let cal = #"(?:calendar|schedule|agenda)"#
    private static let eventNoun = #"(?:meeting|event|appointment|class|call|lecture)"#

    static func parse(raw: String, simplified: String, now: Date, calendar: Calendar) -> RioAction? {
        let s = simplified.lowercased()
        if let range = agendaRange(s) { return .calendarAgenda(range) }
        if isJoin(s) { return .joinNextMeeting }
        return createEvent(raw: raw, now: now, calendar: calendar)
    }

    // MARK: Agenda

    private static func range(_ word: String?) -> CalendarRange {
        switch word {
        case "tomorrow": return .tomorrow
        case "next": return .next
        default: return .today
        }
    }

    private static func agendaRange(_ s: String) -> CalendarRange? {
        let day = #"(?:\s+(?:for\s+)?(today|tomorrow))?"#
        let patterns: [(String, CalendarRange?)] = [
            (#"^what(?:s|\s+is|\s+do\s+i\s+have|\s+have\s+i\s+got)(?:\s+currently)?\s+(?:on|in)\s+(?:my|the)\s+\#(cal)\#(day)$"#, nil),
            (#"^what\s+do\s+i\s+have(?:\s+(?:going\s+on|on\s+my\s+\#(cal)|on|planned|scheduled|coming\s+up))?\s+(?:for\s+)?(today|tomorrow|next)$"#, nil),
            (#"^what\s+do\s+i\s+have\s+on\s+my\s+\#(cal)\#(day)$"#, nil),
            (#"^what\s+have\s+i\s+got(?:\s+(?:on|planned|scheduled))?\s+(today|tomorrow)$"#, nil),
            (#"^what(?:s|\s+is)\s+my\s+\#(cal)\#(day)$"#, nil),
            (#"^what(?:s|\s+is|\s+does)\s+(?:my\s+day|today|tomorrow)\s+look(?:ing)?(?:\s+like)?$"#, .today),
            (#"^how\s+(?:does|is)\s+(?:my\s+day|today|tomorrow)\s+look(?:ing)?$"#, .today),
            (#"^do\s+i\s+have\s+anything(?:\s+(?:on|planned|scheduled))?\s+(?:for\s+)?(today|tomorrow)$"#, nil),
            (#"^(?:read|check|read\s+me|tell\s+me|show\s+me|show)\s+(?:my|the)\s+(?:schedule|agenda)\#(day)$"#, nil),
            (#"^(?:read|check|read\s+me|tell\s+me)\s+(?:my|the)\s+calendar\#(day)$"#, nil),
        ]
        for (pattern, fixed) in patterns {
            guard let groups = RioText.firstMatch(pattern, in: s) else { continue }
            if let fixed {
                // "what's tomorrow look like": the day word decides.
                if s.contains("tomorrow") { return .tomorrow }
                return fixed
            }
            return range(groups.last ?? nil)
        }
        if let range = dayEventRange(s) { return range }
        let next = [
            #"^what(?:s|\s+is)\s+next(?:\s+(?:on|in)\s+my\s+\#(cal))?$"#,
            #"^what(?:s|\s+is)\s+(?:my\s+)?(?:next|upcoming)\s+\#(eventNoun)$"#,
            #"^when(?:s|\s+is)\s+my\s+next\s+\#(eventNoun)$"#,
            #"^what(?:s|\s+is)\s+(?:coming\s+up|up\s+next)(?:\s+(?:on|in)\s+my\s+\#(cal))?$"#,
        ]
        return next.contains(where: { RioText.matches($0, s) }) ? .next : nil
    }

    /// "what's my 4pm", "what's my first meeting tomorrow", "what's my meeting at 3", "what do I
    /// have at 2pm": the agenda for that day (the event at that time is in it).
    private static func dayEventRange(_ s: String) -> CalendarRange? {
        let noun = #"(?:meeting|event|appointment|class|call|lecture|standup|stand\s+up|session)"#
        let day = #"(?:\s+(today|tomorrow))?"#
        let meridiem = #"(?:am|pm|a\s?m|p\s?m)"#
        let clock = #"\d{1,2}(?:\s\d{2})?"#
        let whatIs = #"^what(?:s|\s+is)\s+"#
        if let groups = RioText.firstMatch(#"^(?:what(?:s|\s+is)|when(?:s|\s+is))\s+(?:my|the)\s+(first|last|next)\s+\#(noun)(?:\s+of\s+the\s+day)?\#(day)$"#, in: s) {
            switch groups.last ?? nil {
            case "tomorrow": return .tomorrow
            case "today": return .today
            default: return groups[1] == "next" ? .next : .today
            }
        }
        let timed = [
            whatIs + #"my\s+\#(clock)\s*\#(meridiem)(?:\s+\#(noun))?\#(day)$"#,
            whatIs + #"my\s+\#(clock)\s+\#(noun)\#(day)$"#,
            whatIs + #"(?:my|the)\s+\#(noun)\s+at\s+\#(clock)(?:\s*\#(meridiem))?\#(day)$"#,
            #"^what\s+do\s+i\s+have\s+at\s+\#(clock)(?:\s*\#(meridiem))?\#(day)$"#,
        ]
        guard timed.contains(where: { RioText.matches($0, s) }) else { return nil }
        return RioText.matches(#"\btomorrow$"#, s) ? .tomorrow : .today
    }

    // MARK: Join

    private static func isJoin(_ s: String) -> Bool {
        let patterns = [
            #"^(?:i\s+(?:need|want|have)\s+to\s+|let\s+me\s+)?(?:join|jump\s+on|hop\s+on|get\s+on|dial\s+(?:in\s*to|into|in))\s+(?:(?:my|the)\s+)?(?:next\s+|upcoming\s+|current\s+)?(?:zoom\s+|google\s+meet\s+|meet\s+|teams\s+)?(?:meeting|call|class|lecture|standup|zoom|session)(?:\s+link)?$"#,
            #"^(?:open|start)\s+(?:(?:my|the)\s+)?(?:next\s+|upcoming\s+)?(?:meeting|call)(?:\s+link)?$"#,
        ]
        return patterns.contains { RioText.matches($0, s) }
    }

    // MARK: Create

    private static let blockedWords = #"\b(?:reminders?|remind|texts?|messages?|emails?|timers?|alarms?|playlists?|queue|cart|lists?|notes?|tasks?|todos?|songs?|music)\b"#

    private static func createEvent(raw: String, now: Date, calendar: Calendar) -> RioAction? {
        let text = raw.trimmingCharacters(in: CharacterSet(charactersIn: " .!?,;:\"\u{201C}\u{201D}\n\t"))
        guard let groups = RioText.firstMatch(#"^(add|schedule|book|create|put|set\s+up)\s+(.+)$"#, in: text),
              let verb = groups[1]?.lowercased(), var object = groups[2] else { return nil }
        guard !RioText.matches(blockedWords, object) else { return nil }
        // "add office hours every tuesday at 3": a repeating event is not one event. Leave it to
        // the resolver rather than add a single "Office hours every".
        guard !RioText.matches(#"\b(?:every|each|weekly|daily|monthly|yearly|weekdays|weekends|hourly|biweekly|fortnightly)\b"#, object) else { return nil }
        // "book a table at Nobu Friday at 8" is a task for the web, not a calendar entry.
        if verb == "book", RioText.matches(#"^(?:me\s+|us\s+)?(?:an?\s+|the\s+)?(?:table|tables|reservation|room|flight|flights|ticket|tickets|hotel|ride|cab|uber|taxi|seat|seats|spot|stay|trip|car|rental|court|slot)\b"#, object) {
            return nil
        }

        let calendarMention = #"\s+(?:to|on|in|onto|into)\s+(?:my|the)\s+\#(cal)\b"#
        let mentionsCalendar = RioText.matches(calendarMention, " " + object)
        object = RioText.collapseWhitespace(RioText.replacing(calendarMention, with: "", in: " " + object))
        // "put X on the left" must never become an event: "put" needs the calendar named.
        if verb == "put", !mentionsCalendar { return nil }

        object = RioText.replacing(#"^(?:me\s+|us\s+)?(?:an?\s+|the\s+)?(?:new\s+)?(?:calendar\s+)?(?:event|entry)\s*(?:called|named|titled|for|about|:)?\s*"#, with: "", in: object)
        object = RioText.replacing(#"^(?:an?\s+)"#, with: "", in: object)

        guard let parsed = RioDateTimeParser.parse(object, now: now, calendar: calendar) else { return nil }
        guard let title = cleanTitle(parsed.remainder) else { return nil }
        return .createEvent(title: title, start: parsed.start, durationMinutes: parsed.durationMinutes)
    }

    private static func cleanTitle(_ raw: String) -> String? {
        var title = RioText.replacing(#"^(?:called|named|titled|for|about)\s+"#, with: "", in: raw)
        title = RioText.replacing(#"\s+(?:for|about)$"#, with: "", in: title)
        title = RioText.collapseWhitespace(title).trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-\"'"))
        guard title.count <= 100, title.contains(where: \.isLetter) else { return nil }
        if RioText.matches(#"^(?:it|this|that|something|one|them|me)$"#, title) { return nil }
        return title.prefix(1).uppercased() + title.dropFirst()
    }
}
