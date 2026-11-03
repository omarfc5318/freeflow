import Foundation

/// Places and abbreviations the time converter knows. Pure data.
enum RioTimePlaces {
    private static let table: [String: String] = {
        var map: [String: String] = [:]
        func add(_ id: String, _ names: [String]) { for name in names { map[name] = id } }
        add("Asia/Qatar", ["doha", "qatar"])
        add("Asia/Dubai", ["dubai", "uae", "abu dhabi", "gst", "sharjah", "united arab emirates"])
        add("Asia/Riyadh", ["riyadh", "saudi", "saudi arabia", "jeddah", "mecca", "medina"])
        add("Asia/Kuwait", ["kuwait"])
        add("Asia/Bahrain", ["bahrain", "manama"])
        add("Asia/Muscat", ["muscat", "oman"])
        add("Africa/Cairo", ["cairo", "egypt"])
        add("Europe/Istanbul", ["istanbul", "turkey", "ankara"])
        add("Europe/London", ["london", "uk", "britain", "england", "bst", "united kingdom"])
        add("Europe/Paris", ["paris", "france", "berlin", "germany", "madrid", "spain", "rome", "italy", "amsterdam", "cet", "brussels", "vienna", "zurich"])
        add("America/New_York", ["new york", "nyc", "eastern", "est", "edt", "et", "boston", "miami", "washington", "atlanta"])
        add("America/Chicago", ["chicago", "central", "cst", "cdt", "ct", "dallas", "houston"])
        add("America/Denver", ["denver", "mountain", "mst", "mdt", "mt"])
        add("America/Los_Angeles", ["los angeles", "la", "san francisco", "sf", "pacific", "pst", "pdt", "pt", "seattle", "california", "davis", "san diego", "san jose"])
        add("America/Toronto", ["toronto", "montreal"])
        add("America/Vancouver", ["vancouver"])
        add("America/Mexico_City", ["mexico city", "mexico"])
        add("America/Sao_Paulo", ["sao paulo", "brazil", "rio de janeiro"])
        add("Asia/Tokyo", ["tokyo", "japan", "jst", "osaka"])
        add("Asia/Seoul", ["seoul", "korea", "south korea"])
        add("Asia/Shanghai", ["beijing", "shanghai", "china"])
        add("Asia/Hong_Kong", ["hong kong"])
        add("Asia/Singapore", ["singapore"])
        add("Australia/Sydney", ["sydney", "melbourne", "australia", "aest"])
        add("Asia/Kolkata", ["mumbai", "delhi", "new delhi", "india", "ist", "bangalore", "kolkata"])
        add("Asia/Karachi", ["karachi", "pakistan", "islamabad", "lahore"])
        add("Asia/Tehran", ["tehran", "iran"])
        add("Europe/Moscow", ["moscow", "russia"])
        add("Africa/Johannesburg", ["johannesburg", "south africa", "cape town"])
        add("Africa/Nairobi", ["nairobi", "kenya"])
        add("Africa/Lagos", ["lagos", "nigeria"])
        add("Asia/Amman", ["amman", "jordan"])
        add("Asia/Beirut", ["beirut", "lebanon"])
        add("UTC", ["utc", "gmt", "zulu"])
        return map
    }()

    private static let abbreviations: Set<String> = [
        "est", "edt", "et", "cst", "cdt", "ct", "mst", "mdt", "mt", "pst", "pdt", "pt", "utc", "gmt", "uk", "uae",
        "bst", "cet", "ist", "jst", "gst", "aest", "nyc", "la", "sf",
    ]

    static func cleaned(_ spoken: String) -> String {
        var text = RioText.collapseWhitespace(spoken.lowercased())
        text = RioText.replacing(#"^(?:the|in|at)\s+"#, with: "", in: text)
        text = RioText.replacing(#"\s+(?:time\s*zone|timezone|time)$"#, with: "", in: text)
        return text
    }

    static func zone(for spoken: String) -> (zone: TimeZone, display: String)? {
        let key = cleaned(spoken)
        guard let id = table[key], let zone = TimeZone(identifier: id) else { return nil }
        let display = abbreviations.contains(key)
            ? key.uppercased()
            : key.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return (zone, display)
    }
}

/// Time-of-day and time-zone questions ("9 AM Doha time here", "what time is it in Tokyo").
/// The clock and the local zone are always passed in.
enum RioCalcTime {
    private static let localMarkers = [
        "in my local time zone", "in my local time", "to my local time", "my local time", "in my time zone", "to my time zone",
        "in my timezone", "my time zone", "my timezone", "in local time", "to local time", "local time", "in my time",
        "to my time", "my time", "for me", "locally", "here",
    ]
    private static let leadingMarkers = ["my local time", "my time", "local time", "here"]

    static func evaluate(cleaned: String, stripped: String, now: Date, local: TimeZone) -> RioCalcAnswer? {
        if RioText.matches(
            #"^(?:what(?:s|\s+is)?(?:\s+the)?\s+time(?:\s+is\s+it)?|what\s+time\s+is\s+it|current\s+time|the\s+time)(?:\s+(?:right\s+now|now|currently))?$"#,
            cleaned
        ) {
            let text = clock(now, in: local)
            return RioCalcAnswer(value: text, sentence: "It's \(text)")
        }
        if let groups = RioText.firstMatch(
            #"^(?:(?:what(?:s|\s+is)?(?:\s+the)?\s+)|the\s+)?(?:current\s+)?time(?:\s+is\s+it)?(?:\s+(?:right\s+now|now))?\s+in\s+(.+?)(?:\s+(?:right\s+now|now))?$"#,
            in: cleaned
        ), let place = groups[1] {
            guard let target = RioTimePlaces.zone(for: place) else { return nil }
            let text = clock(now, in: target.zone)
            return RioCalcAnswer(value: text, sentence: "It's \(text) in \(target.display)")
        }
        return conversion(stripped, now: now, local: local)
    }

    // MARK: Conversion

    private enum Side {
        case here
        case place(TimeZone, String)

        var zone: TimeZone? { if case .place(let zone, _) = self { return zone } else { return nil } }
    }

    private static func conversion(_ text: String, now: Date, local: TimeZone) -> RioCalcAnswer? {
        let words = text.split(separator: " ").map(String.init)
        guard let spec = parseTime(words), spec.consumed < words.count else { return nil }
        let rest = words[spec.consumed...].joined(separator: " ")
        guard let (source, target) = sides(rest) else { return nil }
        let sourceZone = source.zone ?? local
        let targetZone = target.zone ?? local

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = sourceZone
        var parts = calendar.dateComponents([.year, .month, .day], from: now)
        parts.hour = spec.hour
        parts.minute = spec.minute
        guard let moment = calendar.date(from: parts) else { return nil }

        var targetCalendar = Calendar(identifier: .gregorian)
        targetCalendar.timeZone = targetZone
        let shift = targetCalendar.dateComponents([.day], from: targetCalendar.startOfDay(for: now), to: targetCalendar.startOfDay(for: moment)).day ?? 0
        var value = clock(moment, in: targetZone)
        if shift == -1 { value += " yesterday" } else if shift == 1 { value += " tomorrow" }

        let given = clockText(hour: spec.hour, minute: spec.minute)
        let from: String
        switch source {
        case .here: from = "\(given) here"
        case .place(_, let name): from = "\(given) in \(name)"
        }
        let to: String
        switch target {
        case .here: to = "\(value) here"
        case .place(_, let name): to = "\(value) in \(name)"
        }
        return RioCalcAnswer(value: value, sentence: "\(from) is \(to)")
    }

    private static func sides(_ rest: String) -> (Side, Side)? {
        for marker in localMarkers where rest == marker || rest.hasSuffix(" " + marker) {
            let place = rest == marker ? "" : String(rest.dropLast(marker.count + 1))
            guard let found = RioTimePlaces.zone(for: place) else { return nil }
            return (.place(found.zone, found.display), .here)
        }
        for marker in leadingMarkers where rest.hasPrefix(marker + " ") {
            let place = RioText.replacing(#"^(?:in|to|into)\s+"#, with: "", in: String(rest.dropFirst(marker.count + 1)))
            guard let found = RioTimePlaces.zone(for: place) else { return nil }
            return (.here, .place(found.zone, found.display))
        }
        if let groups = RioText.firstMatch(#"^(.+?)(?:\s+time)?\s+(?:in|to|into)\s+(.+?)$"#, in: rest),
           let from = groups[1], let to = groups[2],
           let source = RioTimePlaces.zone(for: from), let target = RioTimePlaces.zone(for: to) {
            return (.place(source.zone, source.display), .place(target.zone, target.display))
        }
        if let groups = RioText.firstMatch(#"^(?:in|to|into)\s+(.+)$"#, in: rest), let to = groups[1],
           let target = RioTimePlaces.zone(for: to) {
            return (.here, .place(target.zone, target.display))
        }
        return nil
    }

    // MARK: Time of day

    struct TimeOfDay: Equatable {
        let hour: Int
        let minute: Int
        let consumed: Int
    }

    /// "9 am", "9am", "9:30 pm", "21:00", "noon", "midnight", "nine thirty pm". A bare "9" is not a
    /// time: it needs am or pm, a colon, or a word like noon.
    static func parseTime(_ words: [String]) -> TimeOfDay? {
        guard let first = words.first else { return nil }
        switch first {
        case "noon", "midday": return TimeOfDay(hour: 12, minute: 0, consumed: 1)
        case "midnight": return TimeOfDay(hour: 0, minute: 0, consumed: 1)
        default: break
        }
        if let groups = RioText.firstMatch(#"^(\d{1,2})(?::(\d{2}))?(am|pm)?$"#, in: first), let hourText = groups[1], let hour = Int(hourText) {
            let minute = groups[2].flatMap(Int.init) ?? 0
            guard minute < 60 else { return nil }
            if let suffix = groups[3] { return twelveHour(hour, minute, suffix, consumed: 1) }
            if words.count > 1, words[1] == "am" || words[1] == "pm" { return twelveHour(hour, minute, words[1], consumed: 2) }
            guard groups[2] != nil, hour <= 23 else { return nil }
            return TimeOfDay(hour: hour, minute: minute, consumed: 1)
        }
        return spokenTime(words)
    }

    private static func spokenTime(_ words: [String]) -> TimeOfDay? {
        guard let hourWord = RioNumberWords.parse(words, at: 0), !hourWord.isFraction,
              hourWord.value >= 1, hourWord.value <= 12, hourWord.value == hourWord.value.rounded() else { return nil }
        var index = hourWord.consumed
        if index < words.count, words[index] == "oclock" || words[index] == "clock" { index += 1 }
        var minute = 0
        if index < words.count, words[index] == "oh" {
            guard index + 1 < words.count, let digit = RioNumberWords.parse(words, at: index + 1), digit.value < 10 else { return nil }
            minute = Int(digit.value)
            index += 1 + digit.consumed
        } else if index < words.count, let minuteWord = RioNumberWords.parse(words, at: index), !minuteWord.isFraction,
                  minuteWord.value >= 1, minuteWord.value <= 59 {
            minute = Int(minuteWord.value)
            index += minuteWord.consumed
        }
        guard index < words.count, words[index] == "am" || words[index] == "pm" else { return nil }
        return twelveHour(Int(hourWord.value), minute, words[index], consumed: index + 1)
    }

    private static func twelveHour(_ hour: Int, _ minute: Int, _ suffix: String, consumed: Int) -> TimeOfDay? {
        guard (1...12).contains(hour) else { return nil }
        let base = hour % 12
        return TimeOfDay(hour: suffix == "pm" ? base + 12 : base, minute: minute, consumed: consumed)
    }

    // MARK: Formatting

    static func clockText(hour: Int, minute: Int) -> String {
        let suffix = hour >= 12 ? "PM" : "AM"
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return minute == 0 ? "\(twelve) \(suffix)" : "\(twelve):" + String(format: "%02d", minute) + " \(suffix)"
    }

    private static func clock(_ date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return clockText(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
    }
}
