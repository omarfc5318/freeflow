import Foundation

/// Phrases for weather, news, music, Notion and Canvas (builder S). Pure, no AppKit.
/// Every recognizer only claims phrasings that are clearly its own: it runs before the
/// calendar, memory and task parsers, so "play the video on YouTube" and "weather app" are left alone.
enum RioOutsidePhrases {
    static func parse(raw: String, simplified: String) -> RioAction? {
        RioWeatherPhrases.parse(simplified)
            ?? RioNewsPhrases.parse(simplified)
            ?? RioNotionPhrases.parse(raw)
            ?? RioCanvasPhrases.parse(simplified)
            ?? RioMusicPhrases.parse(simplified)
    }
}

/// Words that say when or how, not where.
private let timeWords = #"(?:today|tonight|tomorrow|right\s+now|now|outside|out\s+there|this\s+(?:week|weekend|morning|afternoon|evening)|please|like)"#

private func firstGroup(_ pattern: String, in text: String) -> String? {
    RioText.firstMatch(pattern, in: text)?[1]
}

enum RioWeatherPhrases {
    private static let lead = #"(?:(?:whats|what\s+is|hows|how\s+is|tell\s+me|give\s+me|check|show\s+me|get|read\s+me)\s+)?(?:the\s+|my\s+|todays\s+)?"#

    static func parse(_ s: String) -> RioAction? {
        let patterns = [
            "^\(lead)(?:weather|forecast)\\b(.*)$",
            #"^(?:is\s+it|will\s+it|is\s+it\s+going\s+to|its\s+going\s+to|are\s+we\s+going\s+to\s+get)\s+(?:rain|snow|raining|snowing|hot|cold)\b(.*)$"#,
            #"^do\s+i\s+need\s+(?:an?\s+)?(?:umbrella|jacket|coat|sunscreen)\b(.*)$"#,
            // "what's the temperature in Doha", "temperature in Doha tomorrow", "how hot is it in Doha".
            #"^(?:(?:whats|what\s+is|hows|how\s+is|tell\s+me|check)\s+)?(?:the\s+)?(?:temperature|temp)\b(.*)$"#,
            #"^how\s+(?:hot|cold|warm|humid)\s+is\s+it\b(.*)$"#,
            #"^(?:is\s+it|will\s+it\s+be)\s+(?:hot|cold|warm|sunny|windy|humid)\b(.*)$"#,
        ]
        for pattern in patterns {
            if let groups = RioText.firstMatch(pattern, in: s) { return place(in: groups[1] ?? "") }
        }
        return nil
    }

    /// "in Davis tomorrow" -> Davis; "" -> no place; anything else isn't a weather question.
    private static func place(in rest: String) -> RioAction? {
        var text = RioText.collapseWhitespace(rest)
        text = RioText.replacing("^(?:\(timeWords)\\s*)+", with: "", in: text)
        if text.isEmpty { return .weather(place: nil) }
        guard let found = firstGroup(#"^(?:in|for|at|near)\s+(.+)$"#, in: text) else { return nil }
        let name = RioText.collapseWhitespace(RioText.replacing("(?:\\s+\(timeWords))+$", with: "", in: found))
        guard !name.isEmpty, name.split(separator: " ").count <= 5 else { return nil }
        // "the temperature in Fahrenheit" is a unit, not a place.
        guard !RioText.matches(#"^(?:celsius|fahrenheit|kelvin|c|f|degrees(?:\s+\S+)?|here|this\s+room)$"#, name) else { return nil }
        return .weather(place: name)
    }
}

enum RioNewsPhrases {
    static func parse(_ s: String) -> RioAction? {
        let pattern = #"^(?:(?:whats\s+in|whats|what\s+is|tell\s+me|give\s+me|read\s+me|read|show\s+me|get\s+me|any)\s+)?(?:the\s+|todays\s+|latest\s+|top\s+)*(?:news|headlines)\b(.*)$"#
        guard let groups = RioText.firstMatch(pattern, in: s) else { return nil }
        var rest = RioText.collapseWhitespace(groups[1] ?? "")
        rest = RioText.replacing(#"^(?:(?:today|right\s+now|now|please)\s*)+"#, with: "", in: rest)
        if rest.isEmpty { return .news(topic: nil) }
        guard let topic = firstGroup(#"^(?:about|on|for|in|regarding|from)\s+(.+)$"#, in: rest) else { return nil }
        let cleaned = RioText.collapseWhitespace(RioText.replacing(#"\s+(?:please|today)$"#, with: "", in: topic))
        return cleaned.isEmpty ? nil : .news(topic: cleaned)
    }
}

enum RioMusicPhrases {
    private static let notMusic = #"^(?:it|that|this|them|again|something|anything|music|songs?|a\s+song|some\s+music|the\s+music|something\s+else|pause|resume|continue)$"#
    /// "that again", "it one more time", "this song again": a replay, not a song called "that again".
    private static let replay = #"^(?:(?:it|that|this|them)(?:\s+(?:song|track|one|tune|video))?(?:\s+(?:again|one\s+more\s+time|once\s+more|over))?|again|one\s+more\s+time|once\s+more)$"#
    private static let controlWord = #"^(?:next|previous|prior|last|back|forward|pause|resume|continue|the\s+rest)\b"#
    private static let notASong = #"^(?:video|videos|game|games|movie|film|episode|show|clip|recording|audio|podcast|sound|message|voice\s+message)\b"#
    private static let otherService = #"\bon\s+(?:youtube|netflix|twitch|hulu|disney|prime|amazon|max|tiktok|instagram|chrome|safari|vlc|quicktime)\b"#

    static func parse(_ s: String) -> RioAction? {
        guard var query = firstGroup(#"^(?:play|listen\s+to)\s+(.+)$"#, in: s) else { return nil }
        query = RioText.replacing(#"\s+(?:on|in|using|with|through)\s+(?:my\s+)?(?:spotify|apple\s+music|music|itunes)$"#, with: "", in: query)
        let bare = RioText.replacing(#"^(?:the|a|an)\s+"#, with: "", in: query)
        if RioText.matches(controlWord, bare) || RioText.matches(notASong, bare) || RioText.matches(otherService, query) { return nil }
        query = RioText.replacing(#"^(?:me\s+)?(?:some\s+)?"#, with: "", in: query)
        query = RioText.replacing(#"^(?:the\s+)?(?:song|track|album|playlist|artist|band)\s+(?:called\s+|named\s+)?"#, with: "", in: query)
        query = RioText.collapseWhitespace(query)
        guard !query.isEmpty, !RioText.matches(notMusic, query), !RioText.matches(replay, query) else { return nil }
        return .playMusic(query: query)
    }
}

/// Spotify links Rio may hand to the system: only a track, artist, album or playlist URI. The URI
/// comes from Spotify's search response, so anything else (another scheme, a file URL) is refused.
enum RioSpotifyLink {
    static func safeURL(_ uri: String) -> URL? {
        guard RioText.matches(#"^spotify:(?:track|artist|album|playlist):[A-Za-z0-9]{1,64}$"#, uri),
              uri.hasPrefix("spotify:") else { return nil }
        return URL(string: uri)
    }
}

enum RioNotionPhrases {
    private static let verb = #"(?:add|put|save|note|jot(?:\s+down)?|log)"#
    private static let article = #"(?:my\s+|the\s+)?"#

    /// Works on the raw words so the text keeps its capitals and punctuation.
    static func parse(_ raw: String) -> RioAction? {
        let text = raw.trimmingCharacters(in: CharacterSet(charactersIn: " .!?\t\n"))
        guard text.range(of: "notion", options: .caseInsensitive) != nil else { return nil }
        let withPage = "^\(verb)\\s+(.+?)\\s+(?:to|in|into|on)\\s+\(article)(.+?)\\s+page\\s+(?:in|on|to)\\s+notion$"
        if let groups = RioText.firstMatch(withPage, in: text), let body = groups[1], let page = groups[2] {
            return make(body, page: page)
        }
        // "add call Ali to my Hala roadmap in Notion": the page is named without the word "page".
        let namedPage = "^\(verb)\\s+(.+?)\\s+(?:to|into)\\s+(?:my|the)\\s+(.+?)\\s+(?:in|on)\\s+notion$"
        if let groups = RioText.firstMatch(namedPage, in: text), let body = groups[1], let page = groups[2],
           page.range(of: "notion", options: .caseInsensitive) == nil {
            return make(body, page: page)
        }
        let leading = [
            "^\(verb)\\s+(?:to|in|into)\\s+\(article)notion\\s*[:,]?\\s*(?:that\\s+)?(.+)$",
            #"^(?:note|jot)\s+(?:in|on)\s+notion\s*[:,]?\s*(?:that\s+)?(.+)$"#,
        ]
        for pattern in leading {
            if let body = firstGroup(pattern, in: text) { return make(body, page: nil) }
        }
        let plain = "^\(verb)\\s+(.+?)\\s+(?:to|in|into|on)\\s+\(article)notion(?:\\s+(?:page|inbox|notes?))?$"
        if let body = firstGroup(plain, in: text) { return make(body, page: nil) }
        return nil
    }

    private static func make(_ body: String, page: String?) -> RioAction? {
        let cleaned = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let name = page?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .notionAdd(text: cleaned, page: (name?.isEmpty ?? true) ? nil : name)
    }
}

enum RioCanvasPhrases {
    private static let workWords = #"\b(?:assignments?|homework|coursework|quiz(?:zes)?|deadlines?|due)\b"#
    private static let otherVerbs = #"^(?:open|launch|quit|close|add|create|remind|set|make|schedule|email|text|message|send|write|type|go|switch|hide|show\s+me\s+canvas)\b"#
    private static let openCanvas = #"^(?:open(?:\s+up)?|check|go\s+to|launch|pull\s+up|bring\s+up|show\s+me|take\s+me\s+to)\s+(?:my\s+|the\s+)?canvas(?:\s+(?:site|website|page|dashboard))?(?:\s+for\s+me)?(?:\s+please)?$"#
    /// Short words that look like a course code before a number ("hw 6", "quiz 3", "at 11").
    private static let notCourses: Set<String> = [
        "hw", "quiz", "lab", "labs", "week", "day", "days", "ch", "chap", "unit", "test", "exam", "pset", "ps", "part",
        "page", "pg", "at", "by", "in", "on", "for", "the", "due", "my", "is", "am", "pm", "of", "to", "no", "and",
        "hour", "min", "top", "last", "next", "this", "set", "rio", "its", "it", "are", "was", "item", "task", "step",
    ]

    static func parse(_ s: String) -> RioAction? {
        // "open Canvas", "check Canvas": the owner's own Canvas site, never a generic one.
        if RioText.matches(openCanvas, s), let base = RioCanvasConfig.configuredBase { return .openURL(base) }
        guard !RioText.matches(otherVerbs, s) else { return nil }
        let mentionsCanvas = RioText.matches(#"\bcanvas\b"#, s) && RioText.matches(#"\b(?:assignments?|homework|coursework|quiz(?:zes)?|deadlines?|due|upcoming|to\s?do)\b"#, s)
        let asksDue = RioText.matches(workWords, s) && RioText.matches(#"\bdue\b"#, s)
        let bareDue = RioText.matches(#"^(?:whats|what\s+is)\s+due(?:\s+(?:today|tomorrow|this\s+week|next\s+week|soon))?$"#, s)
        let assignmentsOnly = RioText.matches(#"^(?:check|show|read)\s+(?:me\s+)?(?:my\s+)?(?:assignments?|homework)$"#, s)
        guard mentionsCanvas || asksDue || bareDue || assignmentsOnly else { return nil }
        // "when is the ECS119 project due" after "remember that the ECS119 project is due December 5th".
        if let thing = firstGroup(#"^when\s+(?:is|are|was|were)\s+(?:my\s+|the\s+|our\s+)?(.+?)\s+due\b"#, in: s),
           RioRememberedFacts.knows(thing) {
            return .recall(query: thing)
        }
        var parts: [String] = []
        if let found = firstGroup(#"\b(today|tonight|tomorrow|this\s+week|next\s+week)\b"#, in: s) {
            let range = RioText.collapseWhitespace(found).lowercased()
            parts.append(range == "tonight" ? "today" : range)
        }
        if let course = course(in: s) { parts.append(course) }
        return .canvasDue(range: parts.isEmpty ? nil : parts.joined(separator: " "))
    }

    /// "mat108", "ECS 119" -> "MAT108", "ECS119". The first code-looking pair that isn't "hw 6".
    static func course(in s: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\b([a-z]{2,4})\s?(\d{2,3}[a-z]?)\b"#, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        for match in regex.matches(in: s, range: range) {
            guard let letters = Range(match.range(at: 1), in: s), let digits = Range(match.range(at: 2), in: s) else { continue }
            let prefix = s[letters].lowercased()
            if notCourses.contains(prefix) { continue }
            return prefix.uppercased() + s[digits].uppercased()
        }
        return nil
    }
}
