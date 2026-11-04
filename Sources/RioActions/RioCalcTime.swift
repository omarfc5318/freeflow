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
        return relative(cleaned, now: now, local: local)
            ?? daysUntil(cleaned, now: now, local: local)
            ?? weekday(cleaned, now: now, local: local)
            ?? conversion(stripped, now: now, local: local)
    }

    // MARK: Relative times and dates (round 3)

    private static let unitSeconds: [String: Double] = [
        "second": 1, "seconds": 1, "sec": 1, "secs": 1, "minute": 60, "minutes": 60, "min": 60, "mins": 60,
        "hour": 3_600, "hours": 3_600, "hr": 3_600, "hrs": 3_600, "day": 86_400, "days": 86_400,
        "week": 604_800, "weeks": 604_800,
    ]
    static let maxRelativeSeconds = 366.0 * 86_400

    /// "25 minutes from now", "what time will it be in 45 minutes", "3 hours ago".
    private static func relative(_ text: String, now: Date, local: TimeZone) -> RioCalcAnswer? {
        let amount = #"(an?|\d+(?:\.\d+)?|[a-z]+(?: [a-z]+)?) (seconds?|secs?|minutes?|mins?|hours?|hrs?|days?|weeks?)"#
        let lead = #"^(?:(?:whats|what is|what time is it|what time will it be|what time would it be|what time is|the time)\s+)?"#
        var groups = RioText.firstMatch(lead + amount + #" (from now|ago)$"#, in: text)
        if groups == nil, let later = RioText.firstMatch(#"^what time (?:will|would) it be in "# + amount + #"(?: from now)?$"#, in: text) {
            groups = [later[0], later[1], later[2], "from now"]
        }
        guard let groups, let spoken = groups[1], let unit = groups[2].flatMap({ unitSeconds[$0] }),
              let count = spokenCount(spoken) else { return nil }
        let isPast = groups[3] == "ago"
        let seconds = count * unit
        guard seconds > 0, seconds <= maxRelativeSeconds else { return nil }
        let moment = now.addingTimeInterval(isPast ? -seconds : seconds)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = local
        let value: String
        if unit >= 86_400 {
            value = dayText(moment, calendar: calendar)
        } else {
            let shift = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: moment)).day ?? 0
            value = clock(moment, in: local) + (shift == 1 ? " tomorrow" : shift == -1 ? " yesterday" : shift == 0 ? "" : " on " + dayText(moment, calendar: calendar))
        }
        let phrase = "\(spoken) \(groups[2] ?? "") \(isPast ? "ago" : "from now")"
        return RioCalcAnswer(value: value, sentence: "\(phrase.prefix(1).uppercased() + phrase.dropFirst()) \(isPast ? "was" : "is") \(value)")
    }

    /// "an", "25", "twenty five", "1.5".
    private static func spokenCount(_ text: String) -> Double? {
        if text == "a" || text == "an" { return 1 }
        if let value = Double(text) { return value }
        let words = text.split(separator: " ").map(String.init)
        guard let parsed = RioNumberWords.parse(words, at: 0), parsed.consumed == words.count else { return nil }
        return parsed.value
    }

    /// "how many days until December 8", "how long until Friday", "days till christmas".
    private static func daysUntil(_ text: String, now: Date, local: TimeZone) -> RioCalcAnswer? {
        guard let groups = RioText.firstMatch(
            #"^(?:how many (days|weeks)(?: are)?(?: (?:left|there))?|how long(?: is it)?|(days|weeks))(?: left)? (?:until|till|til|to|before) (.+)$"#,
            in: text
        ), let spokenDate = groups[3] else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = local
        guard let target = date(spokenDate, now: now, calendar: calendar, preferPast: false) else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: target.date).day ?? 0
        guard days >= 0 else { return nil }
        let name = target.name
        if days == 0 { return RioCalcAnswer(value: "0 days", sentence: "\(name) is today") }
        let wantsWeeks = (groups[1] ?? groups[2]) == "weeks"
        let value: String
        if wantsWeeks, days >= 7 {
            let weeks = days / 7, rest = days % 7
            value = "\(weeks) week\(weeks == 1 ? "" : "s")" + (rest == 0 ? "" : " and \(rest) day\(rest == 1 ? "" : "s")")
        } else {
            value = "\(days) day\(days == 1 ? "" : "s")"
        }
        return RioCalcAnswer(value: value, sentence: "\(value) until \(name)")
    }

    /// "what day is November 26", "what day of the week was July 4".
    private static func weekday(_ text: String, now: Date, local: TimeZone) -> RioCalcAnswer? {
        guard let groups = RioText.firstMatch(
            #"^what day(?: of the week)? (is|was|will|does|did)(?: it)?(?: on)? (.+?)(?: (?:be|fall on|land on|fall|land))?$"#, in: text
        ), let tense = groups[1], let spokenDate = groups[2] else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = local
        guard let target = date(spokenDate, now: now, calendar: calendar, preferPast: tense == "was" || tense == "did") else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = local
        formatter.dateFormat = "EEEE"
        let day = formatter.string(from: target.date)
        let past = target.date < calendar.startOfDay(for: now)
        return RioCalcAnswer(value: day, sentence: "\(target.name) \(past ? "was" : "is") a \(day)")
    }

    private static let months: [String: Int] = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3, "april": 4, "apr": 4, "may": 5,
        "june": 6, "jun": 6, "july": 7, "jul": 7, "august": 8, "aug": 8, "september": 9, "sept": 9, "sep": 9,
        "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12,
    ]
    private static let monthNames = [
        "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December",
    ]
    private static let holidays: [String: (month: Int, day: Int, name: String)] = [
        "christmas": (12, 25, "Christmas"), "christmas day": (12, 25, "Christmas"), "christmas eve": (12, 24, "Christmas Eve"),
        "new year": (1, 1, "New Year's Day"), "new years": (1, 1, "New Year's Day"), "new years day": (1, 1, "New Year's Day"),
        "halloween": (10, 31, "Halloween"), "valentines day": (2, 14, "Valentine's Day"),
    ]

    /// A spoken date ("december 8", "the 8th of december", "dec 8 2027", "christmas") as the start of
    /// that day: the next one from today, or this year's when `preferPast`.
    private static func date(_ spoken: String, now: Date, calendar: Calendar, preferPast: Bool) -> (date: Date, name: String)? {
        let text = RioText.replacing(#"^(?:the|on)\s+"#, with: "", in: spoken)
        var month: Int?
        var day: Int?
        var year: Int?
        var name: String?
        if let holiday = holidays[text] {
            (month, day, name) = (holiday.month, holiday.day, holiday.name)
        } else if let g = RioText.firstMatch(#"^([a-z]+) (\d{1,2})(?:st|nd|rd|th)?(?: (\d{4}))?$"#, in: text), let m = g[1].flatMap({ months[$0] }) {
            (month, day, year) = (m, g[2].flatMap(Int.init), g[3].flatMap(Int.init))
        } else if let g = RioText.firstMatch(#"^(\d{1,2})(?:st|nd|rd|th)? (?:of )?([a-z]+)(?: (\d{4}))?$"#, in: text), let m = g[2].flatMap({ months[$0] }) {
            (month, day, year) = (m, g[1].flatMap(Int.init), g[3].flatMap(Int.init))
        }
        guard let month, let day, (1...31).contains(day) else { return nil }
        let today = calendar.startOfDay(for: now)
        var chosenYear = year ?? calendar.component(.year, from: now)
        func make(_ y: Int) -> Date? {
            guard let made = calendar.date(from: DateComponents(year: y, month: month, day: day)),
                  calendar.component(.day, from: made) == day else { return nil }
            return made
        }
        guard var result = make(chosenYear) else { return nil }
        if year == nil, !preferPast, result < today {
            chosenYear += 1
            guard let next = make(chosenYear) else { return nil }
            result = next
        }
        let label = name ?? "\(monthNames[month - 1]) \(day)" + (year.map { ", \($0)" } ?? "")
        return (result, label)
    }

    private static func dayText(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: date)
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
