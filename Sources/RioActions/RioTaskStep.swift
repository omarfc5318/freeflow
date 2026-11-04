import Foundation

// The multi-step agent's protocol (builder K). The model answers each turn with exactly ONE JSON
// object. Everything here validates it field by field and rebuilds a `RioAction` from known
// fields only, so no reply (including one steered by hostile page text) can produce anything
// outside the closed set the agent is allowed to use. Foundation only, pure.

enum RioTaskStep: Equatable {
    /// An action to run through the executor. `modelFlaggedRisky` can only add caution.
    case act(RioAction, narration: String, modelFlaggedRisky: Bool)
    /// Give the page a moment.
    case wait(seconds: Double, narration: String)
    case done(summary: String)
    /// A question or a job only the user can do; control goes back to them.
    case ask(question: String)
}

enum RioTaskStepError: Error, Equatable {
    case notJSON
    case multipleSteps
    case unknownStep(String)
    case invalidField(String)
}

enum RioTaskStepParser {
    static let maxNarrationCharacters = 80
    static let maxLabelCharacters = 80
    static let maxTextCharacters = 500
    static let maxSummaryCharacters = 280

    /// Tab commands are out: a page-steered agent must not open tabs or read other tabs.
    static let allowedBrowserCommands: Set<BrowserCommand> = [
        .back, .forward, .reload, .scrollDown, .scrollUp, .scrollToTop, .scrollToBottom, .find,
    ]
    /// Keys the agent may press on their own. Letters and digits are deliberately absent: typing
    /// goes through `typeText` / `fillField`, where the sensitive-text checks live.
    static let allowedPlainKeys: Set<String> = [
        "return", "tab", "escape", "space", "delete", "up", "down", "left", "right",
        "home", "end", "pageup", "pagedown",
    ]
    /// Command shortcuts the agent may use (find, select all).
    /// ⌘F and ⌘A only. ⌘L/⌘T are excluded: focusing the address bar and typing would let the
    /// agent reach any URL without the `webURL` checks; it navigates with `openURL` instead.
    static let allowedCommandKeys: Set<String> = ["f", "a"]

    static func parse(_ content: String) -> Result<RioTaskStep, RioTaskStepError> {
        guard let json = decode(content) else { return .failure(.notJSON) }
        guard let object = json as? [String: Any] else { return .failure(.multipleSteps) }
        if object["actions"] != nil { return .failure(.multipleSteps) }
        guard let name = object["step"] as? String else { return .failure(.invalidField("step")) }
        return step(named: name, object: object)
    }

    // MARK: Steps

    private static func step(named name: String, object: [String: Any]) -> Result<RioTaskStep, RioTaskStepError> {
        switch name {
        case "done":
            guard let summary = text(object["summary"], max: maxSummaryCharacters, multiline: true) else { return .failure(.invalidField("summary")) }
            return .success(.done(summary: RioText.collapseWhitespace(summary)))
        case "ask":
            guard let question = text(object["question"], max: maxSummaryCharacters, multiline: true) else { return .failure(.invalidField("question")) }
            return .success(.ask(question: RioText.collapseWhitespace(question)))
        case "wait":
            guard let number = object["seconds"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue >= 0.5, number.doubleValue <= 5 else { return .failure(.invalidField("seconds")) }
            return .success(.wait(seconds: number.doubleValue, narration: narration(object, fallback: "Waiting for the page")))
        case "openURL", "click", "fillField", "typeText", "pressKeys", "browser":
            guard let action = action(named: name, object: object) else { return .failure(.invalidField(name)) }
            let risky = flag(object["risky"])
            return .success(.act(action, narration: narration(object, fallback: RioTaskDescriber.narration(for: action)), modelFlaggedRisky: risky))
        default:
            return .failure(.unknownStep(String(name.prefix(30))))
        }
    }

    private static func action(named name: String, object: [String: Any]) -> RioAction? {
        switch name {
        case "openURL":
            return webURL(object["url"]).map(RioAction.openURL)
        case "click":
            guard let label = label(object["label"]) else { return nil }
            var ordinal: Int?
            if let raw = object["ordinal"], !(raw is NSNull) {
                guard let value = integer(raw), (1...20).contains(value) else { return nil }
                ordinal = value
            }
            return .click(label: label, ordinal: ordinal)
        case "fillField":
            guard let label = label(object["label"]), let value = text(object["text"], max: maxTextCharacters) else { return nil }
            return .fillField(label: label, text: value)
        case "typeText":
            return text(object["text"], max: maxTextCharacters).map(RioAction.typeText)
        case "pressKeys":
            return keyCombo(object)
        case "browser":
            guard let raw = object["command"] as? String, let command = BrowserCommand(rawValue: raw),
                  allowedBrowserCommands.contains(command) else { return nil }
            return .browser(command)
        default:
            return nil
        }
    }

    private static func keyCombo(_ object: [String: Any]) -> RioAction? {
        guard let key = object["key"] as? String, KeyCombo.allowedKeys.contains(key) else { return nil }
        let command = flag(object["command"]), shift = flag(object["shift"])
        guard !flag(object["option"]), !flag(object["control"]) else { return nil }
        if command {
            guard allowedCommandKeys.contains(key), !shift else { return nil }
        } else {
            guard allowedPlainKeys.contains(key) else { return nil }
        }
        return .pressKeys(KeyCombo(key: key, command: command, shift: shift, option: false, control: false))
    }

    // MARK: Fields

    private static func narration(_ object: [String: Any], fallback: String) -> String {
        guard let say = text(object["say"], max: 400) else { return fallback }
        let collapsed = RioText.collapseWhitespace(say)
        guard collapsed.count > maxNarrationCharacters else { return collapsed }
        return String(collapsed.prefix(maxNarrationCharacters)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    private static func flag(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == number.doubleValue.rounded(), abs(number.doubleValue) < 1e6 else { return nil }
        return number.intValue
    }

    private static func hasControlCharacter(_ text: String, allowNewlines: Bool) -> Bool {
        text.unicodeScalars.contains { scalar in
            guard scalar.properties.generalCategory == .control else { return false }
            return !(allowNewlines && (scalar == "\n" || scalar == "\t" || scalar == "\r"))
        }
    }

    private static func text(_ value: Any?, max: Int, multiline: Bool = false) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= max, !hasControlCharacter(trimmed, allowNewlines: multiline) else { return nil }
        return trimmed
    }

    /// Element labels: single line, no URLs smuggled in, nothing shell-like.
    private static func label(_ value: Any?) -> String? {
        guard let label = text(value, max: maxLabelCharacters) else { return nil }
        let lower = label.lowercased()
        if lower.contains("://") || lower.contains("www.") { return nil }
        if label.contains(where: { ";|`$<>\\".contains($0) }) || label.contains("&&") || label.contains("../") { return nil }
        return label
    }

    private static func webURL(_ value: Any?) -> URL? {
        guard let string = text(value, max: 2_048), !string.contains(where: { $0.isWhitespace }),
              let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."),
              !RioWebHostRules.isLocalHost(host) else { return nil }
        return url
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
        guard let candidate = candidates.first, let end = text.lastIndex(of: candidate.close), end > candidate.start,
              let data = String(text[candidate.start...end]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

/// Plain-English text for a step: the confirmation panel shows `describe`, the bear's progress
/// card shows `narration`.
enum RioTaskDescriber {
    static func describe(_ action: RioAction) -> String {
        switch action {
        case .click(let label, let ordinal):
            return ordinal.map { "Click \"\(label)\" (number \($0))" } ?? "Click \"\(label)\""
        case .fillField(let label, let text): return "Type \"\(text)\" into \"\(label)\""
        case .typeText(let text): return "Type \"\(text)\""
        case .openURL(let url): return "Open \(url.absoluteString)"
        case .pressKeys(let combo): return "Press \(keyName(combo))"
        case .browser(let command): return browserName(command)
        default: return "Run a step"
        }
    }

    static func narration(for action: RioAction) -> String {
        switch action {
        case .openURL(let url): return "Opening \(url.host ?? "a page")"
        case .click(let label, _): return "Clicking \"\(label)\""
        case .fillField(let label, _): return "Filling in \"\(label)\""
        case .typeText: return "Typing"
        case .pressKeys(let combo): return "Pressing \(keyName(combo))"
        case .browser(let command): return browserName(command)
        default: return "Working"
        }
    }

    private static func keyName(_ combo: KeyCombo) -> String {
        let key = combo.key.count == 1 ? combo.key.uppercased() : combo.key.prefix(1).uppercased() + combo.key.dropFirst()
        return (combo.command ? "Command-" : "") + (combo.shift ? "Shift-" : "") + key
    }

    private static func browserName(_ command: BrowserCommand) -> String {
        switch command {
        case .scrollDown: return "Scroll down"
        case .scrollUp: return "Scroll up"
        case .scrollToTop: return "Scroll to the top"
        case .scrollToBottom: return "Scroll to the bottom"
        case .back: return "Go back"
        case .forward: return "Go forward"
        case .reload: return "Reload the page"
        case .newTab: return "Open a new tab"
        case .nextTab: return "Next tab"
        case .previousTab: return "Previous tab"
        case .find: return "Find on the page"
        default: return "Browser command"
        }
    }
}
