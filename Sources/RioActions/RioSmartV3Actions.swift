import Foundation

/// Field-by-field validation of the wave 3 actions the smart resolver may return. Like the rest
/// of the schema, every action is rebuilt from known fields only; anything odd drops the action.
enum RioSmartV3Actions {
    static let maxGoalCharacters = 300
    static let maxLabelCharacters = 80
    static let maxTextCharacters = 500
    static let maxQueryCharacters = 200
    static let maxEmailSubjectCharacters = 200
    static let maxOrdinal = 20

    static func action(kind: String, object: [String: Any], now: Date, timeZone: TimeZone) -> RioAction? {
        switch kind {
        case "describeScreen": return describeScreen(object)
        case "click": return click(object)
        case "fillField":
            guard let label = label(object["label"]),
                  let value = RioSmartResponseParser.text(object["text"], max: maxTextCharacters) else { return nil }
            return .fillField(label: label, text: value)
        case "runTask":
            return RioSmartResponseParser.text(object["goal"], max: maxGoalCharacters).map { RioAction.runTask(goal: $0) }
        case "remember":
            return RioSmartResponseParser.text(object["fact"], max: RioMemoryStore.maxFactLength).map { RioAction.remember(fact: $0) }
        case "recall": return recallOrForget(object, isForget: false)
        case "forget": return recallOrForget(object, isForget: true)
        case "draftEmail": return draftEmail(object)
        case "addNote":
            return RioSmartResponseParser.text(object["text"], max: RioNotesScripts.maxLength, multiline: true).map { RioAction.addNote(text: $0) }
        case "calculate":
            // Only maths the local calculator can really answer gets through.
            guard let expression = RioSmartResponseParser.text(object["expression"], max: maxQueryCharacters),
                  RioCalculator.evaluate(expression, now: now, timeZone: timeZone) != nil else { return nil }
            return .calculate(expression: expression)
        case "startTranslation": return .startTranslation
        case "stopTranslation": return .stopTranslation
        case "speakLastTranslation": return .speakLastTranslation
        default: return RioSmartV45Actions.action(kind: kind, object: object, now: now, timeZone: timeZone)
        }
    }

    // MARK: Fields

    /// A label on the screen: single line, no shell characters and no web addresses, so a click
    /// or fill can never be turned into "go to this site".
    static func label(_ value: Any?) -> String? {
        guard let label = RioSmartResponseParser.name(value, max: maxLabelCharacters), !containsAddress(label) else { return nil }
        return label
    }

    static func containsAddress(_ text: String) -> Bool {
        text.contains("://")
            || RioText.matches(#"(?:^|\s)(?:www\.|[a-z0-9-]+\.(?:com|org|net|io|co|edu|gov|app|dev|ai|me|ly|xyz|info|sh|to)\b)"#, text)
            || RioText.matches(#"\b(?:https?|ftp|file|javascript|data|mailto)\s*:"#, text)
    }

    private static func describeScreen(_ object: [String: Any]) -> RioAction? {
        guard RioSmartResponseParser.isPresent(object["question"]) else { return .describeScreen(question: nil) }
        guard let question = RioSmartResponseParser.text(object["question"], max: maxQueryCharacters) else { return nil }
        return .describeScreen(question: question)
    }

    private static func click(_ object: [String: Any]) -> RioAction? {
        guard let label = label(object["label"]) else { return nil }
        guard RioSmartResponseParser.isPresent(object["ordinal"]) else { return .click(label: label, ordinal: nil) }
        guard let ordinal = RioSmartResponseParser.integer(object["ordinal"]), (1...maxOrdinal).contains(ordinal) else { return nil }
        return .click(label: label, ordinal: ordinal)
    }

    /// "forget" never accepts a wipe-everything query: that stays a button in Settings.
    private static func recallOrForget(_ object: [String: Any], isForget: Bool) -> RioAction? {
        guard let query = RioSmartResponseParser.text(object["query"], max: maxQueryCharacters) else {
            // Recall with no query lists what Rio remembers; forget always needs one.
            return isForget || RioSmartResponseParser.isPresent(object["query"]) ? nil : .recall(query: "")
        }
        if isForget {
            guard !RioText.matches(#"^(?:everything|all|all of it|all my .*|everything .*|memories|my memories|my memory|the lot)$"#, query) else { return nil }
            return .forget(query: query)
        }
        return .recall(query: query)
    }

    private static func draftEmail(_ object: [String: Any]) -> RioAction? {
        guard let body = RioSmartResponseParser.text(object["body"], max: RioSmartResponseParser.maxBodyCharacters, multiline: true) else { return nil }
        var recipient: String?
        if RioSmartResponseParser.isPresent(object["to"]) {
            guard let to = RioSmartResponseParser.name(object["to"], max: 100) else { return nil }
            recipient = to
        }
        var subject: String?
        if RioSmartResponseParser.isPresent(object["subject"]) {
            guard let value = RioSmartResponseParser.text(object["subject"], max: maxEmailSubjectCharacters) else { return nil }
            subject = value
        }
        return .draftEmail(to: recipient, subject: subject, body: body)
    }
}

/// Field-by-field validation of the wave 4–5 actions (automations, macros, writing, the outside
/// world, meetings and Claude Code). The same validators the local phrases rely on decide what
/// is acceptable: a schedule must parse with `RioScheduleParser`, a trigger with `RioTriggerKind`,
/// a Claude prompt with `RioClaudeSend`. Confirmations and refusals for these steps are applied
/// by the coordinator exactly as for the owner's own words.
enum RioSmartV45Actions {
    static let maxInstructionCharacters = 400
    static let maxCommandCharacters = 200
    static let maxWhenCharacters = 80
    static let maxNameCharacters = 60
    static let maxSearchCharacters = 120
    static let canvasRanges: Set<String> = ["today", "tomorrow", "this week", "next week"]

    static func action(kind: String, object: [String: Any], now: Date, timeZone: TimeZone) -> RioAction? {
        typealias P = RioSmartResponseParser
        switch kind {
        case "searchHistory": return P.text(object["query"], max: maxSearchCharacters).map { RioAction.searchHistory(query: $0) }
        case "editLastDictation": return instruction(object).map { RioAction.editLastDictation(instruction: $0) }
        case "writeForMe": return instruction(object).map { RioAction.writeForMe(instruction: $0) }
        case "smartPaste": return instruction(object).map { RioAction.smartPaste(instruction: $0) }
        case "scheduleCommand": return schedule(object, now: now, timeZone: timeZone)
        case "addTrigger":
            guard let command = command(object["command"]), let spec = P.name(object["trigger"], max: maxWhenCharacters),
                  let trigger = RioTriggerKind(spec: spec) else { return nil }
            return .addTrigger(command: command, trigger: trigger.spec)
        case "listAutomations": return .listAutomations
        case "removeAutomation": return P.name(object["name"], max: maxNameCharacters).map { RioAction.removeAutomation(name: $0) }
        case "recordMacro":
            guard P.isPresent(object["name"]) else { return .recordMacro(name: "") }
            return P.name(object["name"], max: maxNameCharacters).map { RioAction.recordMacro(name: $0) }
        case "stopRecordingMacro": return .stopRecordingMacro
        case "runMacro": return P.name(object["name"], max: maxNameCharacters).map { RioAction.runMacro(name: $0) }
        case "findThing": return P.name(object["query"], max: maxSearchCharacters).map { RioAction.findThing(query: $0) }
        case "organizeDownloads": return .organizeDownloads
        case "copyTextFromScreen": return .copyTextFromScreen
        case "weather": return optionalName(object["place"]).map { RioAction.weather(place: $0) }
        case "news": return optionalName(object["topic"]).map { RioAction.news(topic: $0) }
        case "playMusic": return P.name(object["query"], max: RioSmartV3Actions.maxQueryCharacters).map { RioAction.playMusic(query: $0) }
        case "notionAdd":
            guard let text = P.text(object["text"], max: P.maxBodyCharacters, multiline: true),
                  let page = optionalName(object["page"]) else { return nil }
            return .notionAdd(text: text, page: page)
        case "canvasDue": return canvas(object)
        case "meeting": return (object["command"] as? String).flatMap(MeetingCommand.init(rawValue:)).map(RioAction.meeting)
        case "claudeCode": return claude(object)
        default: return nil
        }
    }

    private static func instruction(_ object: [String: Any]) -> String? {
        RioSmartResponseParser.text(object["instruction"], max: maxInstructionCharacters)
    }

    /// A command Rio will run later as the owner's own words: one plain line, nothing shell-like,
    /// and never another automation (no schedules inside schedules).
    private static func command(_ value: Any?) -> String? {
        guard let command = RioSmartResponseParser.name(value, max: maxCommandCharacters),
              !RioText.matches(#"^(?:schedule|automate|every|each|whenever|when)\b"#, command) else { return nil }
        return command
    }

    /// `.some(nil)` when the field is absent, nil when it is present but unusable.
    private static func optionalName(_ value: Any?) -> String?? {
        guard RioSmartResponseParser.isPresent(value) else { return .some(nil) }
        guard let name = RioSmartResponseParser.name(value, max: 80) else { return nil }
        return .some(name)
    }

    private static func schedule(_ object: [String: Any], now: Date, timeZone: TimeZone) -> RioAction? {
        guard let command = command(object["command"]),
              let raw = RioSmartResponseParser.text(object["when"], max: maxWhenCharacters) else { return nil }
        var when = raw.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        when = RioText.replacing(#"\b([ap])\.\s?m\.?"#, with: "$1m", in: when)
        when = RioText.collapseWhitespace(when.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:")))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard RioScheduleParser.parse(when, now: now, calendar: calendar) != nil else { return nil }
        return .scheduleCommand(command: command, when: when)
    }

    private static func canvas(_ object: [String: Any]) -> RioAction? {
        guard RioSmartResponseParser.isPresent(object["range"]) else { return .canvasDue(range: nil) }
        guard let raw = (object["range"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        let range = raw == "tonight" ? "today" : RioText.collapseWhitespace(raw)
        return canvasRanges.contains(range) ? .canvasDue(range: range) : nil
    }

    private static func claude(_ object: [String: Any]) -> RioAction? {
        switch object["command"] as? String {
        case "send":
            guard let raw = RioSmartResponseParser.text(object["prompt"], max: RioClaudeSend.maxLength),
                  let prompt = RioClaudeSend.sanitise(raw) else { return nil }
            return .claudeCode(.send(prompt))
        case "approve": return .claudeCode(.approve)
        case "deny": return .claudeCode(.deny)
        case "status": return .claudeCode(.status)
        default: return nil
        }
    }
}
