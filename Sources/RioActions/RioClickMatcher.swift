import Foundation

// Pure label matching for click by voice (builder J). The AX layer turns a window into a list of
// `RioClickElement`s; everything about "which one did the user mean" lives here so it can be tested
// over synthetic lists. Foundation only.

enum RioClickKind: Equatable {
    case button, link, checkbox, radio, menuItem, tab, row, textField, popUp, other
}

struct RioClickElement: Equatable {
    /// Position in the AX walk; the handler maps it back to the live element.
    let index: Int
    let kind: RioClickKind
    /// Everything the element says about itself, best first: title, description, label, help,
    /// placeholder, text of its children.
    let texts: [String]
    let frame: CGRect?
    let isEnabled: Bool
    /// For checkboxes, radios and switches: the current state when known.
    let isChecked: Bool?
}

enum RioToggleIntent: Equatable {
    case on, off
}

enum RioClickOutcome: Equatable {
    case none
    case unique(RioClickElement)
    /// Several equally good matches, in reading order, at most `RioClickMatcher.maxChoices`.
    case ambiguous([RioClickElement])
    case ordinalOutOfRange(available: Int)
}

struct RioClickResolution: Equatable {
    let outcome: RioClickOutcome
    /// Set by "check", "uncheck", "tick", "untick".
    let toggle: RioToggleIntent?
}

enum RioClickMatcher {
    /// How many choices Rio will number on screen.
    static let maxChoices = 9

    // MARK: Entry points

    static func resolve(label: String, ordinal: Int?, in elements: [RioClickElement]) -> RioClickResolution {
        let plain = rank(Query(label), ordinal: ordinal, elements)
        guard let (verb, rest) = splitToggleVerb(label) else { return RioClickResolution(outcome: plain.outcome, toggle: nil) }
        // A real "Check out" button beats reading "check" as a verb.
        if plain.isStrong { return RioClickResolution(outcome: plain.outcome, toggle: nil) }
        let toggled = rank(Query(rest), ordinal: ordinal, elements)
        guard toggled.outcome != .none else { return RioClickResolution(outcome: plain.outcome, toggle: nil) }
        return RioClickResolution(outcome: toggled.outcome, toggle: verb)
    }

    /// Whether a press is needed to reach the wanted state ("check" on a ticked box does nothing).
    static func needsToggle(_ intent: RioToggleIntent?, current: Bool?) -> Bool {
        guard let intent, let current else { return true }
        return (intent == .on) != current
    }

    // MARK: Query

    private static let roleNouns: [String: RioClickKind] = [
        "button": .button, "buttons": .button, "link": .link, "links": .link, "tab": .tab, "tabs": .tab,
        "checkbox": .checkbox, "toggle": .checkbox, "switch": .checkbox, "radio": .radio,
        "menu": .menuItem, "field": .textField, "textbox": .textField, "dropdown": .popUp, "row": .row,
    ]
    /// Words that name a kind of control but add nothing to the text match.
    private static let fillerNouns: Set<String> = ["icon", "item", "option", "box", "bar", "input", "area", "arrow"]
    private static let articles: Set<String> = ["the", "a", "an", "this", "that", "my"]

    private struct Query {
        let words: [String]
        let compact: String
        let kinds: Set<RioClickKind>

        init(_ label: String) {
            var tokens = normalize(label).split(separator: " ").map(String.init)
            while let first = tokens.first, articles.contains(first) { tokens.removeFirst() }
            var kinds = Set<RioClickKind>()
            // Role nouns are only dropped from the end ("Send button"), and only when something is left,
            // unless the whole label is the role ("link").
            while let last = tokens.last {
                if let kind = roleNouns[last] {
                    kinds.insert(kind)
                    if kind == .textField || kind == .checkbox { kinds.insert(kind) }
                } else if !fillerNouns.contains(last) {
                    break
                } else if tokens.count == 1 {
                    break
                }
                tokens.removeLast()
            }
            // "menu item" / "radio button": a second role noun in a row is dropped the same way.
            self.words = tokens
            self.compact = tokens.joined()
            self.kinds = kinds
        }

        var isRoleOnly: Bool { words.isEmpty && !kinds.isEmpty }
    }

    private static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let mapped = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar)
                ? Character(scalar) : " "
        }
        return RioText.collapseWhitespace(String(mapped))
    }

    private static func splitToggleVerb(_ label: String) -> (RioToggleIntent, String)? {
        let words = label.split(separator: " ", maxSplits: 1).map(String.init)
        guard words.count == 2 else { return nil }
        switch words[0].lowercased() {
        case "check", "tick": return (.on, words[1])
        case "uncheck", "untick": return (.off, words[1])
        default: return nil
        }
    }

    // MARK: Ranking

    private struct Ranked {
        let outcome: RioClickOutcome
        let isStrong: Bool
    }

    private struct Scored {
        let element: RioClickElement
        let score: Int
    }

    private static let strongScore = 95

    private static func rank(_ query: Query, ordinal: Int?, _ elements: [RioClickElement]) -> Ranked {
        guard !query.words.isEmpty || query.isRoleOnly || ordinal != nil else { return Ranked(outcome: .none, isStrong: false) }
        let live = dedupe(elements.filter { $0.isEnabled })
        var scored: [Scored] = []
        for element in live {
            if query.isRoleOnly {
                if query.kinds.contains(element.kind) { scored.append(Scored(element: element, score: 100)) }
                continue
            }
            guard var best = element.texts.map({ score(query, text: $0) }).max(), best > 0 else { continue }
            if query.kinds.contains(element.kind) { best += 5 }
            scored.append(Scored(element: element, score: best))
        }
        guard let top = scored.map(\.score).max() else { return Ranked(outcome: .none, isStrong: false) }
        let strong = top >= strongScore
        let tier = scored.filter { $0.score == top }.map(\.element)
        let ordered = readingOrder(tier)

        if let ordinal {
            // "The second Reply": rank among everything that matched as well as the best one did.
            let position = ordinal < 0 ? ordered.count + ordinal : ordinal - 1
            guard position >= 0, position < ordered.count else {
                return Ranked(outcome: .ordinalOutOfRange(available: ordered.count), isStrong: strong)
            }
            return Ranked(outcome: .unique(ordered[position]), isStrong: strong)
        }
        if ordered.count == 1 { return Ranked(outcome: .unique(ordered[0]), isStrong: strong) }
        return Ranked(outcome: .ambiguous(Array(ordered.prefix(maxChoices))), isStrong: strong)
    }

    /// Exact 100, same letters 95, prefix 80, every word present 65, substring 50, one typo 35.
    private static func score(_ query: Query, text: String) -> Int {
        let normalized = normalize(text)
        guard !normalized.isEmpty, !query.words.isEmpty else { return 0 }
        let textWords = normalized.split(separator: " ").map(String.init)
        let label = query.words.joined(separator: " ")
        if normalized == label { return 100 }
        let textCompact = textWords.joined()
        if textCompact == query.compact { return 95 }
        if normalized.hasPrefix(label + " ") || (query.compact.count >= 3 && textCompact.hasPrefix(query.compact)) { return 80 }
        if query.words.allSatisfy({ word in textWords.contains(word) }) { return 65 }
        if query.compact.count >= 3, textCompact.contains(query.compact) { return 50 }
        let distance = editDistance(query.compact, textCompact)
        let limit = query.compact.count >= 9 ? 2 : (query.compact.count >= 5 ? 1 : 0)
        if limit > 0, distance <= limit { return 35 }
        return 0
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if abs(a.count - b.count) > 2 { return 99 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    // MARK: Order and duplicates

    /// Top to bottom, then left to right; rows within 8 points count as one row. Unframed last.
    static func readingOrder(_ elements: [RioClickElement]) -> [RioClickElement] {
        let framed = elements.filter { $0.frame != nil }.sorted { lhs, rhs in
            guard let l = lhs.frame, let r = rhs.frame else { return false }
            if abs(l.minY - r.minY) > 8 { return l.minY < r.minY }
            if l.minX != r.minX { return l.minX < r.minX }
            return lhs.index < rhs.index
        }
        return framed + elements.filter { $0.frame == nil }.sorted { $0.index < $1.index }
    }

    /// Chromium and Electron often expose a button and its wrapper with the same text and frame.
    private static func dedupe(_ elements: [RioClickElement]) -> [RioClickElement] {
        var seen = Set<String>()
        var result: [RioClickElement] = []
        for element in elements {
            guard let frame = element.frame else { result.append(element); continue }
            let key = "\(Int(frame.minX / 4)),\(Int(frame.minY / 4)),\(Int(frame.width / 4)),\(Int(frame.height / 4))|\(normalize(element.texts.first ?? ""))"
            if seen.insert(key).inserted { result.append(element) }
        }
        return result
    }
}
