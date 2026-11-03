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
        default: return nil
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
