import Foundation

// The smart resolver's output contract. The LLM answers with JSON; everything here validates
// it field by field and rebuilds a `RioAction` from known fields only, so no reply can ever
// produce anything outside the closed action set. Foundation only, pure.

enum RioSmartText {
    static let maxAnswerCharacters = 280

    /// First `maxSentences` sentences, whitespace collapsed, cut at a word boundary past
    /// `maxCharacters`. A "." inside a number ("3.14") is not a sentence end.
    static func limitSentences(_ text: String, maxSentences: Int, maxCharacters: Int) -> String {
        let collapsed = RioText.collapseWhitespace(text)
        guard !collapsed.isEmpty else { return "" }
        let characters = Array(collapsed)
        var end = characters.count
        var sentences = 0
        for index in characters.indices where ".!?".contains(characters[index]) {
            let isLast = index == characters.count - 1
            if isLast || characters[index + 1] == " " {
                sentences += 1
                if sentences == maxSentences {
                    end = index + 1
                    break
                }
            }
        }
        var result = String(characters[0..<end])
        if result.count > maxCharacters {
            var cut = String(result.prefix(maxCharacters))
            if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > maxCharacters / 2 {
                cut = String(cut[..<space])
            }
            result = cut + "\u{2026}"
        }
        return result
    }
}

enum RioSmartDates {
    /// ISO-8601 from the model, resolved in the user's time zone when it has no offset.
    /// A bare date means 9:00 that day. Anything impossible, absurdly old or more than ten years
    /// out is nil.
    static func parse(_ value: String, now: Date, timeZone: TimeZone) -> Date? {
        let text = value.trimmingCharacters(in: .whitespaces)
        let full = #"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?$"#
        var zone = timeZone
        var parts: [Int]
        if let groups = RioText.firstMatch(full, in: text) {
            parts = [1, 2, 3, 4, 5].compactMap { groups[$0].flatMap(Int.init) }
            parts.append(groups[6].flatMap(Int.init) ?? 0)
            if let offset = groups[7] {
                guard let parsed = secondsFromOffset(offset), let offsetZone = TimeZone(secondsFromGMT: parsed) else { return nil }
                zone = offsetZone
            }
        } else if let groups = RioText.firstMatch(#"^(\d{4})-(\d{2})-(\d{2})$"#, in: text) {
            parts = [1, 2, 3].compactMap { groups[$0].flatMap(Int.init) }
            parts.append(contentsOf: [9, 0, 0])
        } else {
            return nil
        }
        guard parts.count == 6 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4], second: parts[5])
        guard let date = calendar.date(from: components) else { return nil }
        // Reject rolled-over values like February 30th or hour 25.
        let check = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard check.year == parts[0], check.month == parts[1], check.day == parts[2],
              check.hour == parts[3], check.minute == parts[4], check.second == parts[5] else { return nil }
        guard date >= now.addingTimeInterval(-2 * 86_400), date <= now.addingTimeInterval(10 * 365 * 86_400) else { return nil }
        return date
    }

    private static func secondsFromOffset(_ offset: String) -> Int? {
        if offset == "Z" { return 0 }
        let sign = offset.hasPrefix("-") ? -1 : 1
        let digits = offset.dropFirst().filter(\.isNumber)
        guard digits.count == 4, let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)),
              hours <= 14, minutes < 60 else { return nil }
        return sign * (hours * 3600 + minutes * 60)
    }
}

enum RioSmartResponseParser {
    /// A plan of at most six steps ("switch to Chrome, press command N, ...").
    static let maxActions = 6
    static let maxBodyCharacters = 2_000

    /// Every action the model may produce: all of `RioAction` except typeText, stopListening and
    /// emptyTrash (organizeDownloads is allowed: it always asks first). pressKeys is allowed since the understanding-first change (owner decision,
    /// 2026-11-03), but only keys `RioSmartKeyPolicy` permits.
    static let allowedActionNames: [String] = [
        "openApp", "quitApp", "switchToApp", "hideApp", "openURL", "webSearch",
        "volume", "media", "lockScreen", "screenshot", "doNotDisturb", "window",
        "sendMessage", "createReminder", "selectionTask", "replyInConversation", "readAloud", "answer",
        "startTimer", "cancelTimer", "timerStatus", "undoLast", "showHelp",
        "openFile", "revealFile", "calendarAgenda", "joinNextMeeting", "createEvent", "clipboard",
        "browser", "systemToggle", "brightness", "batteryStatus", "pressKeys",
        // Wave 3 (validated in RioSmartV3Actions).
        "describeScreen", "click", "fillField", "runTask", "remember", "recall", "forget", "draftEmail", "addNote",
        "calculate", "startTranslation", "stopTranslation", "speakLastTranslation",
        // Waves 4–5 (validated in RioSmartV45Actions).
        "searchHistory", "editLastDictation", "writeForMe", "smartPaste",
        "scheduleCommand", "addTrigger", "listAutomations", "removeAutomation",
        "recordMacro", "stopRecordingMacro", "runMacro", "findThing", "organizeDownloads", "copyTextFromScreen",
        "weather", "news", "playMusic", "notionAdd", "canvasDue", "meeting", "claudeCode",
    ]

    static func actions(from content: String, now: Date, timeZone: TimeZone) -> [RioAction] {
        plan(from: content, now: now, timeZone: timeZone).actions
    }

    /// The validated plan, plus whether valid steps past `maxActions` were dropped (so Rio can
    /// say he only did the first six).
    static func plan(from content: String, now: Date, timeZone: TimeZone) -> (actions: [RioAction], wasCut: Bool) {
        guard let json = decode(content) else { return ([], false) }
        let items: [Any]
        if let object = json as? [String: Any] {
            if let list = object["actions"] as? [Any] {
                items = list
            } else if object["action"] != nil {
                items = [object]
            } else {
                return ([], false)
            }
        } else if let list = json as? [Any] {
            items = list
        } else {
            return ([], false)
        }
        var actions: [RioAction] = []
        for item in items {
            guard let object = item as? [String: Any], let action = action(from: object, now: now, timeZone: timeZone) else { continue }
            guard actions.count < maxActions else { return (actions, true) }
            actions.append(action)
        }
        return (actions, false)
    }

    // MARK: Decoding

    private static func decode(_ content: String) -> Any? {
        var text = RioText.replacing(#"<think>[\s\S]*?</think>"#, with: "", in: content)
        text = RioText.replacing(#"<think>[\s\S]*$"#, with: "", in: text)
        text = text.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        var candidates: [(close: Character, start: String.Index)] = []
        if let brace = text.firstIndex(of: "{") { candidates.append(("}", brace)) }
        if let bracket = text.firstIndex(of: "[") { candidates.append(("]", bracket)) }
        candidates.sort { $0.start < $1.start }
        for candidate in candidates {
            guard let end = text.lastIndex(of: candidate.close), end > candidate.start else { continue }
            let slice = String(text[candidate.start...end])
            if let data = slice.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) { return json }
        }
        return nil
    }

    // MARK: Field validation

    static func hasControlCharacter(_ text: String, allowNewlines: Bool) -> Bool {
        text.unicodeScalars.contains { scalar in
            guard scalar.properties.generalCategory == .control else { return false }
            return !(allowNewlines && (scalar == "\n" || scalar == "\t" || scalar == "\r"))
        }
    }

    static func text(_ value: Any?, max: Int, multiline: Bool = false) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= max, !hasControlCharacter(trimmed, allowNewlines: multiline) else { return nil }
        return trimmed
    }

    static func isShellLike(_ text: String) -> Bool {
        text.contains { ";|`$<>\\".contains($0) } || text.contains("&&") || text.contains("../")
    }

    /// App names, contacts, languages and file queries: single line, nothing shell-like.
    static func name(_ value: Any?, max: Int = 80) -> String? {
        guard let value = text(value, max: max), !isShellLike(value) else { return nil }
        return value
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == number.doubleValue.rounded(), abs(number.doubleValue) < 1e12 else { return nil }
        return number.intValue
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func isPresent(_ value: Any?) -> Bool {
        value != nil && !(value is NSNull)
    }

    private static func webURL(_ value: Any?) -> URL? {
        guard let string = text(value, max: 2_048), !string.contains(where: { $0.isWhitespace }),
              let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.user == nil, url.password == nil,
              let host = url.host, host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."),
              !RioWebHostRules.isLocalHost(host) else { return nil }
        return url
    }

    private static func language(_ value: Any?) -> String? {
        guard let language = text(value, max: 30), RioText.matches(#"^[\p{L}][\p{L} '\-]*$"#, language) else { return nil }
        return language
    }

    private static func level(_ object: [String: Any]) -> Int? {
        integer(object["level"]).map { min(100, max(0, $0)) }
    }

    // MARK: Action construction

    private static func action(from object: [String: Any], now: Date, timeZone: TimeZone) -> RioAction? {
        guard let kind = object["action"] as? String, allowedActionNames.contains(kind) else { return nil }
        switch kind {
        case "openApp": return name(object["name"]).map(RioAction.openApp)
        case "quitApp": return name(object["name"]).map(RioAction.quitApp)
        case "switchToApp": return name(object["name"]).map(RioAction.switchToApp)
        case "hideApp": return name(object["name"]).map(RioAction.hideApp)
        case "openURL": return webURL(object["url"]).map(RioAction.openURL)
        case "webSearch": return text(object["query"], max: 200).map { RioAction.webSearch(query: $0) }
        case "volume": return volumeChange(object, allowMute: true).map(RioAction.volume)
        case "brightness": return volumeChange(object, allowMute: false).map(RioAction.brightness)
        case "media": return (object["command"] as? String).flatMap(MediaCommand.init(rawValue:)).map(RioAction.media)
        case "lockScreen": return .lockScreen
        case "screenshot": return (object["kind"] as? String).flatMap(ScreenshotKind.init(rawValue:)).map(RioAction.screenshot)
        case "doNotDisturb": return boolean(object["isOn"]).map { RioAction.doNotDisturb(isOn: $0) }
        case "window": return windowCommand(object)
        case "sendMessage":
            guard let to = name(object["to"], max: 100),
                  let body = text(object["body"], max: maxBodyCharacters, multiline: true) else { return nil }
            return .sendMessage(to: to, body: body)
        case "replyInConversation":
            return text(object["body"], max: maxBodyCharacters, multiline: true).map { RioAction.replyInConversation(body: $0) }
        case "createReminder": return reminder(object, now: now, timeZone: timeZone)
        case "selectionTask": return selectionTask(object)
        case "readAloud": return (object["target"] as? String).flatMap(ReadTarget.init(rawValue:)).map(RioAction.readAloud)
        case "answer":
            guard let raw = text(object["text"], max: 4_000, multiline: true) else { return nil }
            let limited = RioSmartText.limitSentences(raw, maxSentences: 2, maxCharacters: RioSmartText.maxAnswerCharacters)
            return limited.isEmpty ? nil : .answer(limited)
        case "startTimer": return timer(object)
        case "cancelTimer": return .cancelTimer
        case "timerStatus": return .timerStatus
        case "undoLast": return .undoLast
        case "showHelp": return .showHelp
        case "openFile": return name(object["query"], max: 100).map { RioAction.openFile(query: $0) }
        case "revealFile": return name(object["query"], max: 100).map { RioAction.revealFile(query: $0) }
        case "calendarAgenda": return (object["range"] as? String).flatMap(CalendarRange.init(rawValue:)).map(RioAction.calendarAgenda)
        case "joinNextMeeting": return .joinNextMeeting
        case "createEvent": return event(object, now: now, timeZone: timeZone)
        case "clipboard": return clipboard(object)
        case "browser": return (object["command"] as? String).flatMap(BrowserCommand.init(rawValue:)).map(RioAction.browser)
        case "systemToggle":
            guard let setting = (object["setting"] as? String).flatMap(SystemSetting.init(rawValue:)),
                  let isOn = boolean(object["isOn"]) else { return nil }
            return .systemToggle(setting, isOn: isOn)
        case "batteryStatus": return .batteryStatus
        case "pressKeys": return keyPress(object)
        default: return RioSmartV3Actions.action(kind: kind, object: object, now: now, timeZone: timeZone)
        }
    }

    /// `{"key":"n","modifiers":["command"]}`: one allow-listed key, each modifier at most once, and
    /// nothing `RioSmartKeyPolicy` refuses (quit, delete, Return, a bare Space, force quit).
    private static func keyPress(_ object: [String: Any]) -> RioAction? {
        guard let rawKey = object["key"] as? String else { return nil }
        let key = rawKey.trimmingCharacters(in: .whitespaces).lowercased()
        var modifiers: [String] = []
        if isPresent(object["modifiers"]) {
            guard let list = object["modifiers"] as? [Any], list.count <= 4 else { return nil }
            for item in list {
                guard let name = (item as? String)?.trimmingCharacters(in: .whitespaces).lowercased(),
                      RioSmartKeyPolicy.modifierNames.contains(name), !modifiers.contains(name) else { return nil }
                modifiers.append(name)
            }
        }
        let combo = KeyCombo(
            key: key, command: modifiers.contains("command"), shift: modifiers.contains("shift"),
            option: modifiers.contains("option"), control: modifiers.contains("control")
        )
        return RioSmartKeyPolicy.isAllowed(combo) ? .pressKeys(combo) : nil
    }

    private static func volumeChange(_ object: [String: Any], allowMute: Bool) -> VolumeChange? {
        switch object["mode"] as? String {
        case "up": return .up
        case "down": return .down
        case "set": return level(object).map(VolumeChange.set)
        case "mute": return allowMute ? .mute : nil
        case "unmute": return allowMute ? .unmute : nil
        default: return nil
        }
    }

    private static func windowCommand(_ object: [String: Any]) -> RioAction? {
        guard let placement = (object["placement"] as? String).flatMap(WindowPlacement.init(rawValue:)) else { return nil }
        var appName: String?
        if isPresent(object["appName"]) {
            guard let parsed = name(object["appName"]) else { return nil }
            appName = parsed
        }
        return .window(WindowCommand(appName: appName, placement: placement))
    }

    private static func selectionTask(_ object: [String: Any]) -> RioAction? {
        switch object["task"] as? String {
        case "summarize": return .selectionTask(.summarize)
        case "explain": return .selectionTask(.explain)
        case "improve": return .selectionTask(.improve)
        case "translate": return language(object["language"]).map { RioAction.selectionTask(.translate(language: $0)) }
        default: return nil
        }
    }

    private static func reminder(_ object: [String: Any], now: Date, timeZone: TimeZone) -> RioAction? {
        guard let title = text(object["title"], max: 200) else { return nil }
        guard isPresent(object["due"]) else { return .createReminder(title: title, due: nil) }
        guard let raw = object["due"] as? String, let due = RioSmartDates.parse(raw, now: now, timeZone: timeZone) else { return nil }
        return .createReminder(title: title, due: due)
    }

    private static func event(_ object: [String: Any], now: Date, timeZone: TimeZone) -> RioAction? {
        guard let title = text(object["title"], max: 200),
              let raw = object["start"] as? String,
              let start = RioSmartDates.parse(raw, now: now, timeZone: timeZone) else { return nil }
        var minutes: Int?
        if isPresent(object["durationMinutes"]) {
            guard let value = integer(object["durationMinutes"]), (1...1_440).contains(value) else { return nil }
            minutes = value
        }
        return .createEvent(title: title, start: start, durationMinutes: minutes)
    }

    private static func timer(_ object: [String: Any]) -> RioAction? {
        guard let seconds = integer(object["seconds"]), (1...86_400).contains(seconds) else { return nil }
        return .startTimer(seconds: seconds, label: text(object["label"], max: 60))
    }

    private static func clipboard(_ object: [String: Any]) -> RioAction? {
        switch object["command"] as? String {
        case "readCurrent": return .clipboard(.readCurrent)
        case "showHistory": return .clipboard(.showHistory)
        case "pasteRecent": return .clipboard(.pasteRecent(matching: text(object["matching"], max: 60)))
        default: return nil
        }
    }
}
