import Foundation

/// "remind me to submit homework 6 tonight at 11:59", "remind me in 20 minutes to switch the
/// laundry", "set a reminder for 9 pm to submit the lab", "add a reminder: buy a blue book".
/// The owner's own words become a local `.createReminder` (EventKit, no network). Pure: `now`
/// and the calendar are injected. It only answers when it is sure: a time it can't place
/// ("at 9", "at 13 pm", "an hour from now") or a repeating reminder ("every day at 9") returns
/// nil, so the resolver and the scheduler keep those. No time at all is an undated reminder.
/// Claimed on the whole sentence, so an "and" inside the title is not split.
enum RioReminderPhrases {
    static let maxTitleLength = 200

    static func parse(_ text: String) -> RioAction? {
        parse(text, now: Date(), calendar: .current)
    }

    static func parse(_ text: String, now: Date, calendar: Calendar) -> RioAction? {
        let sentence = tidy(text)
        guard !sentence.isEmpty, !RioText.matches(repeating, sentence) else { return nil }
        if let rest = RioText.firstMatch(#"^remind\s+me\s+(.+)$"#, in: sentence)?[1] {
            return remindMe(rest, now: now, calendar: calendar)
        }
        let setForm = #"^(?:set|add|create|make|put\s+in|schedule)\s+(?:me\s+)?(?:a\s+|an\s+|the\s+)?(?:new\s+)?reminder\b\s*(.*)$"#
        if let rest = RioText.firstMatch(setForm, in: sentence)?[1] ?? RioText.firstMatch(#"^(?:new\s+)?reminder\s*[:,\-]\s*(.+)$"#, in: sentence)?[1] {
            return reminder(from: stripLead(rest), now: now, calendar: calendar)
        }
        return nil
    }

    // MARK: Forms

    /// "every day at 9", "each morning", "daily", "on weekdays": the scheduler's.
    private static let repeating = #"\b(?:every|each|daily|weekly|monthly|yearly|weekdays|weekends|hourly)\b"#

    /// "remind me (when) to X" / "remind me to X (when)" / "remind me about X".
    private static func remindMe(_ rest: String, now: Date, calendar: Calendar) -> RioAction? {
        guard let groups = RioText.firstMatch(#"^(.*?)\b(?:to|that|about)\s+(.+)$"#, in: rest),
              let prefix = groups[1]?.trimmingCharacters(in: .whitespaces), let title = groups[2] else { return nil }
        // Anything before "to" must be a time, all of it: "remind me tomorrow morning to ...".
        if !prefix.isEmpty {
            let alone = RioDateTimeParser.parse(prefix, now: now, calendar: calendar)
                ?? RioDateTimeParser.parseDay(prefix, now: now, calendar: calendar)
            guard let alone, alone.remainder.isEmpty else { return nil }
        }
        return reminder(from: prefix.isEmpty ? title : prefix + " " + title, now: now, calendar: calendar)
    }

    /// The title and due date from "call mom at 5" / "for 9 pm to submit the lab".
    private static func reminder(from text: String, now: Date, calendar: Calendar) -> RioAction? {
        guard !text.isEmpty else { return nil }
        if let timed = RioDateTimeParser.parse(text, now: now, calendar: calendar) ?? RioDateTimeParser.parseDay(text, now: now, calendar: calendar) {
            guard let title = cleanTitle(timed.remainder) else { return nil }
            return .createReminder(title: title, due: timed.start)
        }
        // No time it could place: an undated reminder, unless it still names a time.
        guard !RioText.matches(timeWords, text), let title = cleanTitle(text) else { return nil }
        return .createReminder(title: title, due: nil)
    }

    // MARK: Text

    /// A time the date parser could not place: leave the whole request to the resolver.
    private static let timeWords = #"(?:\d\s*(?:am|pm|a\.m|p\.m)\b|\d:\d|\bat\s+\d|\b(?:noon|midnight|tonight|tomorrow|today|later|soon|o'?clock|weekend|morning|afternoon|evening|sunday|monday|tuesday|wednesday|thursday|friday|saturday|next\s+(?:week|month|year))\b|\bfrom\s+now\b|\b(?:\d+|an?|one|two|three|four|five|six|seven|eight|nine|ten|fifteen|twenty|thirty|forty|fifty|sixty|ninety|half|couple\s+of)\s+(?:hours?|minutes?|mins?|hrs?|seconds?)\b|\bin\s+(?:an?|\d+|one|two|three|four|five|ten|twenty|thirty)\s+(?:days?|weeks?|months?)\b)"#

    private static func tidy(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t\"\u{201C}\u{201D}"))
        text = RioText.replacing(#"^(?:(?:hey\s+)?rio\s*[,.!]?\s+)?(?:please\s+)?"#, with: "", in: text)
        text = RioText.replacing(#"[,\s]+(?:please|thanks|thank you)[\s.!]*$"#, with: "", in: text)
        return RioText.collapseWhitespace(text.trimmingCharacters(in: CharacterSet(charactersIn: " .!?\n\t")))
    }

    /// ": buy a blue book", "to renew the domain", "called pick up the cake".
    private static func stripLead(_ rest: String) -> String {
        RioText.replacing(#"^(?:[:,\-]\s*|(?:called|named|titled|saying|that\s+says)\s+)"#, with: "", in: rest)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func cleanTitle(_ raw: String) -> String? {
        var title = RioText.replacing(#"^(?:(?:to|that|about|for|me|i\s+need\s+to|i\s+have\s+to|i\s+should)\s+)+"#, with: "", in: raw)
        title = RioText.collapseWhitespace(title).trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-\"'"))
        guard !title.isEmpty, title.count <= maxTitleLength, title.contains(where: \.isLetter),
              !RioText.matches(timeWords, title),
              // "prep for monday's meeting" lost its day word: the title is broken, not a reminder.
              !RioText.matches(#"(?:^|\s)'s\b"#, title),
              !RioText.matches(#"^(?:it|this|that|something|them|me)$"#, title) else { return nil }
        return title.prefix(1).uppercased() + title.dropFirst()
    }
}
