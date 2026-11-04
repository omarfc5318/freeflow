import Foundation

/// Pure phrase parser for screen understanding and click by voice (builder J). It only claims
/// phrasings that are clearly its own, so "open Chrome", "press command q", "check my battery" or
/// "explain this" still reach the other parsers. Foundation only.
///
/// Conventions the handler and the smart resolver share:
/// - `.click(label:ordinal:)`: the label keeps a trailing role noun ("Send button", "link") because
///   the matcher uses it as a soft hint. Ordinals are 1-based; -1 means "the last one".
/// - "check/uncheck/tick/untick …" keep their verb as the first word of the label so the matcher
///   can tell "check remember me" (set it on) from "click Remember me" (flip it).
/// - `.click(label: "", ordinal: n)` is "the second one": it picks from the choices Rio just
///   numbered on screen.
enum RioScreenPhrases {
    static func parse(raw: String, simplified: String) -> RioAction? {
        let question = questionText(raw)
        if let action = parseDescribe(question) { return action }
        let s = simplified.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if let pick = parsePick(s) { return pick }
        if let check = parseCheck(s) { return check }
        if let fill = parseFill(raw) { return fill }
        return parseClick(s)
    }

    // MARK: Describe the screen

    /// The raw text with sentence punctuation removed but apostrophes kept ("what's").
    private static func questionText(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\u{2019}", with: "'")
        text = RioText.replacing(#"[,;:!?"“”]"#, with: " ", in: text)
        text = RioText.collapseWhitespace(text)
        return text.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    private static let screenNoun = #"(?:screen|window|display|monitor)"#
    private static let errorNoun = #"(?:error|warning|alert|popup|pop up|dialog|dialogue|notification|prompt)"#

    private static func parseDescribe(_ q: String) -> RioAction? {
        guard !q.isEmpty else { return nil }
        let plain = [
            #"^(?:tell me\s+)?what(?:'?s| is)\s+(?:going on\s+|happening\s+|showing\s+|open\s+)?(?:on|in)\s+(?:my|the|this)\s+"# + screenNoun + #"(?:\s+(?:right\s+)?now)?$"#,
            #"^what\s+do\s+you\s+see(?:\s+(?:on|in)\s+(?:my|the|this)\s+"# + screenNoun + #")?(?:\s+(?:right\s+)?now)?$"#,
            #"^what\s+am\s+i\s+(?:looking|staring)\s+at(?:\s+(?:right\s+)?now)?$"#,
            #"^(?:describe|summari[sz]e|explain|look at|analy[sz]e)\s+(?:what(?:'?s| is)\s+on\s+)?(?:my|the|this)\s+(?:"# + screenNoun + #"|page|tab)$"#,
            #"^what(?:'?s| is)\s+(?:this|that)\s+(?:window|page|screen|tab|app)$"#,
        ]
        if plain.contains(where: { RioText.matches($0, q) }) { return .describeScreen(question: nil) }

        let questions = [
            #"^what\s+(?:does|did|do)\s+(?:this|that|the|these)\s+"# + errorNoun + #"(?:\s+(?:message|code))?\s+(?:mean|say|says|tell me|indicate)$"#,
            #"^what\s+(?:does|did|do)\s+(?:this|that|the)\s+(?:message|code|log|output)\s+(?:mean|say|says)$"#,
            #"^what(?:'?s| is)\s+(?:this|that|the)\s+"# + errorNoun + #"(?:\s+(?:message|about))?$"#,
            #"^(?:what|which|where|who|how many|how much)\b.*\b(?:on|in)\s+(?:my|the|this)\s+(?:screen|window|page|tab)$"#,
        ]
        if questions.contains(where: { RioText.matches($0, q) }) { return .describeScreen(question: q) }

        let lookAt = #"^(?:look at|check|read)\s+(?:my|the|this)\s+screen\s+(?:and|then|so)\s+(?:(?:tell|show)\s+me\s+)?(.+)$"#
        if let groups = RioText.firstMatch(lookAt, in: q), let rest = groups[1],
           !rest.trimmingCharacters(in: .whitespaces).isEmpty {
            return .describeScreen(question: rest.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    // MARK: Ordinals

    private static let ordinalWords: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7,
        "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13,
        "fourteenth": 14, "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18,
        "nineteenth": 19, "twentieth": 20, "last": -1, "penultimate": -2,
    ]
    /// "twenty first", "thirty second": compound ordinals, all past the cap.
    private static let ordinalTens: Set<String> = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    private static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10,
    ]
    private static let maxOrdinal = 20

    private static func ordinal(_ word: String) -> Int? {
        let lower = word.lowercased()
        if let value = ordinalWords[lower] { return value }
        if let groups = RioText.firstMatch(#"^(\d{1,2})(?:st|nd|rd|th)$"#, in: lower), let digits = groups[1],
           let value = Int(digits), (1...maxOrdinal).contains(value) {
            return value
        }
        return nil
    }

    enum OrdinalPhrase: Equatable {
        case none
        /// The position and how many leading words said it.
        case value(Int, used: Int)
        /// "the twenty first one": a position past `maxOrdinal`, or one the matcher can't count.
        case overCap
    }

    /// The ordinal at the start of `words`: "second", "3rd", "last", "second to last", "next to
    /// last", "penultimate", "twenty first".
    static func ordinalPhrase(_ words: [String]) -> OrdinalPhrase {
        guard let first = words.first?.lowercased() else { return .none }
        if words.count >= 3, ["to", "from"].contains(words[1].lowercased()), words[2].lowercased() == "last" {
            if first == "second" || first == "next" { return .value(-2, used: 3) }
            if first == "third" { return .value(-3, used: 3) }
            return .overCap
        }
        if ordinalTens.contains(first), words.count >= 2, let unit = ordinalWords[words[1].lowercased()], unit > 0, unit < 10 {
            return .overCap
        }
        if let groups = RioText.firstMatch(#"^(\d+)(?:st|nd|rd|th)$"#, in: first), let digits = groups[1], let value = Int(digits),
           value > maxOrdinal || value == 0 {
            return .overCap
        }
        if let value = ordinal(first) { return .value(value, used: 1) }
        return .none
    }

    private static func cardinal(_ word: String) -> Int? {
        let lower = word.lowercased()
        if let value = numberWords[lower] { return value }
        if let value = Int(lower), (1...maxOrdinal).contains(value) { return value }
        return nil
    }

    // MARK: Pick one of the numbered choices

    /// "open the 5th result", "select the third option", "choose the last link": a click.
    private static let pickNouns: [String: String] = [
        "result": "link", "results": "link", "search result": "link", "link": "link", "option": "option",
        "item": "item", "one": "", "choice": "",
    ]

    private static func parsePick(_ s: String) -> RioAction? {
        let text = s.lowercased()
        let nounPick = #"^(?:open|select|choose|pick)\s+(?:the\s+)?(.+?)\s+(search\s+result|results?|link|option|item|one|choice)$"#
        if let groups = RioText.firstMatch(nounPick, in: text), let words = groups[1], let noun = groups[2],
           let label = pickNouns[noun] {
            switch ordinalPhrase(words.split(separator: " ").map(String.init)) {
            case .value(let value, let used) where used == words.split(separator: " ").count:
                return .click(label: label, ordinal: value)
            case .overCap: return nil
            default: break
            }
        }
        let byNumber = #"^(?:(?:pick|choose|select|take|go with)\s+)?(?:the\s+)?(?:number|option|choice)\s+(\w+)$"#
        if let groups = RioText.firstMatch(byNumber, in: text), let word = groups[1], let value = cardinal(word) {
            return .click(label: "", ordinal: value)
        }
        let byOrdinal = #"^(?:(pick|choose|select|take|go with)\s+)?(?:(the)\s+)?(\w+?)(\s+one)?$"#
        if let groups = RioText.firstMatch(byOrdinal, in: text), let word = groups[3], let value = ordinal(word),
           groups[1] != nil || groups[2] != nil || groups[4] != nil {
            return .click(label: "", ordinal: value)
        }
        return nil
    }

    // MARK: Click

    private static let roleNouns: Set<String> = [
        "button", "buttons", "link", "links", "tab", "tabs", "checkbox", "box", "toggle", "switch", "icon",
        "menu", "option", "radio", "item", "field", "dropdown", "arrow", "row",
    ]
    private static let colorWords: Set<String> = [
        "blue", "red", "green", "yellow", "orange", "purple", "pink", "gray", "grey", "black", "white",
        "big", "small", "little", "large", "round",
    ]
    private static let colourHints: Set<String> = [
        "blue", "red", "green", "yellow", "orange", "purple", "pink", "gray", "grey", "black", "white",
    ]
    private static let pronounLabels: Set<String> = ["it", "this", "that", "here", "there", "them", "one", "ones", "something", "please", "now", "thanks"]
    private static let maxLabelWords = 8
    /// Words a spoken key press is made of ("press shift tab", "hit the down arrow"): never a click.
    private static let keyWords: Set<String> = [
        "shift", "control", "ctrl", "command", "cmd", "option", "opt", "alt", "tab", "arrow", "up", "down", "left",
        "right", "return", "enter", "escape", "esc", "space", "spacebar", "delete", "backspace",
    ]
    /// Buttons whose own text ends in "now" ("Buy now", "Sign up now"): the "now" stays in the label.
    private static let nowLabelWords: Set<String> = [
        "buy", "shop", "order", "join", "book", "subscribe", "download", "install", "start", "try", "apply", "register",
        "up", "upgrade", "update", "restart", "play", "watch", "listen", "call", "pay", "checkout", "donate", "reserve",
        "enroll", "get", "continue",
    ]

    /// "press shift tab", "hit the left arrow": every word a modifier or key name.
    private static func isKeyPress(_ label: String) -> Bool {
        var words = label.lowercased().split(separator: " ").map(String.init)
        if words.count > 1, ["key", "button"].contains(words.last ?? "") { words.removeLast() }
        return !words.isEmpty && words.allSatisfy(keyWords.contains)
    }

    private static func parseClick(_ s: String) -> RioAction? {
        let pattern = #"^(?:(?:please|can you|could you|go ahead and)\s+)?(click|tap|press|hit)(?:\s+on)?\s+(.+)$"#
        guard let groups = RioText.firstMatch(pattern, in: s), let verb = groups[1]?.lowercased(),
              var rest = groups[2] else { return nil }
        rest = RioText.replacing(#"\s+(?:please|for me|thanks|thank you)$"#, with: "", in: rest)
        // "click buy now" is the "Buy now" button; "click send now" is Send.
        if let groups = RioText.firstMatch(#"^(.*?)(\S+)\s+now$"#, in: rest), let before = groups[2],
           !nowLabelWords.contains(before.lowercased()) {
            rest = (groups[1] ?? "") + before
        }
        guard let parts = splitTarget(rest, normalizeBox: true) else { return nil }
        let lastWord = parts.label.split(separator: " ").last.map { String($0).lowercased() } ?? ""
        // "press return" and "hit enter" are keys, not clicks: those verbs need a role noun.
        if verb == "press" || verb == "hit", !roleNouns.contains(lastWord) { return nil }
        // "press tab", "press shift tab" and "press the down arrow" are keys; "press the second tab"
        // or "press the Save button" is a click.
        // A "... button" counts as a key only when every word is a key ("the return button"), so
        // "press the home button" still clicks Home.
        let namesButton = parts.label.lowercased().hasSuffix(" button")
        if verb == "press" || verb == "hit", parts.ordinal == nil,
           isKeyPress(parts.label) || (!namesButton && RioKeyCombos.parse(s) != nil) {
            return nil
        }
        if parts.label.isEmpty { return parts.ordinal == nil ? nil : .click(label: "", ordinal: parts.ordinal) }
        let withoutColours = parts.label.split(separator: " ").drop { colourHints.contains($0.lowercased()) }.joined(separator: " ")
        if pronounLabels.contains(withoutColours.lowercased()) { return nil }
        if RioText.matches(#"\b(?:times|twice|once)$"#, parts.label) { return nil }
        return .click(label: parts.label, ordinal: parts.ordinal)
    }

    /// Splits "the second blue Submit button" into (ordinal 2, label "Submit button").
    private static func splitTarget(_ text: String, normalizeBox: Bool) -> (label: String, ordinal: Int?)? {
        var words = text.split(separator: " ").map(String.init)
        while let first = words.first, ["the", "a", "an", "this", "that", "my"].contains(first.lowercased()) {
            words.removeFirst()
        }
        var ordinalValue: Int?
        switch ordinalPhrase(words) {
        case .overCap: return nil
        case .value(let value, let used):
            ordinalValue = value
            words.removeFirst(used)
        case .none: break
        }
        if ordinalValue != nil {
            // "the last one", "the 1st one": any control at that position.
            if words.count == 1, ["one", "ones"].contains(words[0].lowercased()) { words.removeAll() }
        } else if words.count >= 2, words[0].lowercased() == "number", let value = cardinal(words[1]) {
            ordinalValue = value
            words.removeFirst(2)
        }
        // Colours stay in the label as a soft hint for the matcher ("the blue button" prefers a
        // control whose text or description says blue); size words carry no meaning and go.
        var colours: [String] = []
        while let first = words.first, colorWords.contains(first.lowercased()) {
            if colourHints.contains(first.lowercased()) { colours.append(first) }
            words.removeFirst()
        }
        if !words.isEmpty { words.insert(contentsOf: colours, at: 0) }
        guard words.count <= maxLabelWords else { return nil }
        if normalizeBox, words.count >= 2, words[words.count - 2].lowercased() == "check", words[words.count - 1].lowercased() == "box" {
            words.replaceSubrange((words.count - 2)..., with: ["checkbox"])
        }
        return (words.joined(separator: " "), ordinalValue)
    }

    // MARK: Check and uncheck

    private static let looksLikeABox = #"(?:box|checkbox|toggle|switch|radio|radio button)$"#
    private static let commonCheckTargets =
        #"^(?:remember|keep me|stay|i agree|i accept|i am not a robot|im not a robot|agree|accept|terms|newsletter|subscribe|sign me up)"#

    private static func parseCheck(_ s: String) -> RioAction? {
        guard let groups = RioText.firstMatch(#"^(check|uncheck|tick|untick)\s+(.+)$"#, in: s),
              let verb = groups[1]?.lowercased(), let rest = groups[2] else { return nil }
        guard let parts = splitTarget(rest, normalizeBox: true) else { return nil }
        var label = parts.label
        if label.isEmpty { return nil }
        if RioText.matches(#"(?:^|\s)box$"#, label), !label.lowercased().hasSuffix("checkbox") {
            label = String(label.dropLast(3)) + "checkbox"
        }
        // "check" is also "have a look at": only claim it for things that are clearly boxes.
        if verb == "check",
           !RioText.matches(looksLikeABox, label), !RioText.matches(commonCheckTargets, label.lowercased()) {
            return nil
        }
        return .click(label: "\(verb) \(label)", ordinal: parts.ordinal)
    }

    // MARK: Fill a field

    private static let fieldNoun = #"(?:box|field|bar|input|area|textbox|text box|text field)"#

    private static func parseFill(_ raw: String) -> RioAction? {
        let text = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))).replacingOccurrences(of: "\u{2019}", with: "'")
        let fill = #"^fill(?:\s+in)?\s+(?:the|my)\s+(.+?)\s+with\s+(.+)$"#
        if let groups = RioText.firstMatch(fill, in: text), let label = fieldLabel(groups[1]), let value = fieldText(groups[2]) {
            return .fillField(label: label, text: value)
        }
        let into = #"^(?:(?:put|enter|insert|input|paste|type|write)\s+)(.+?)\s+(?:in|into|in to|inside)\s+(?:the|my)\s+(.+)$"#
        if let groups = RioText.firstMatch(into, in: text), let value = fieldText(groups[1]), let label = fieldLabel(groups[2]) {
            return .fillField(label: label, text: value)
        }
        return nil
    }

    private static func fieldLabel(_ raw: String?) -> String? {
        guard let label = raw.map(RioText.collapseWhitespace), !label.isEmpty,
              label.split(separator: " ").count <= 6,
              RioText.matches(#"(?:^|\s)"# + fieldNoun + "$", label) else { return nil }
        return label
    }

    private static func fieldText(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"\u{201C}\u{201D}"))
        value = RioText.collapseWhitespace(value)
        return value.isEmpty ? nil : value
    }
}
