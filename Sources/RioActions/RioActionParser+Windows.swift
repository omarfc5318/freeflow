import Foundation

/// Window placement and app verbs (open, quit, switch, hide) plus website-vs-app resolution.
extension RioActionParser {
    // MARK: Windows

    private static let moveVerbs = #"(?:put|move|snap|place|send|shove|slide|throw|drag|tile|stick|push)"#
    private static let article = #"(?:(?:the|my)\s+)?"#

    func parseWindow(_ s: String, inherited: Bool) -> ParsedClause? {
        // "top half", "left half of the screen": the frontmost window.
        if let groups = RioText.firstMatch(#"^(?:the\s+)?(left|right|top|bottom)\s+half(?:\s+of\s+(?:the|my)\s+(?:screen|display|monitor))?$"#, in: s),
           let direction = groups[1]?.lowercased() {
            return ParsedClause(action: .window(WindowCommand(appName: nil, placement: Self.half(direction))), verb: "put")
        }
        let verbPattern = "^(\(Self.moveVerbs)|maximi[sz]e|make|full\\s?screen|go|cent(?:er|re)|minimi[sz]e|enlarge|expand)\\b"
        guard let verb = RioText.firstMatch(verbPattern, in: s)?[1]?.lowercased() else { return nil }

        // Next screen: "move Chrome to the other screen".
        let nextScreen = "^\(Self.moveVerbs)\\s+\(Self.article)(.*?)\\s*(?:window\\s+)?(?:over\\s+)?(?:to|onto|on|in)\\s+(?:the\\s+|my\\s+)?(?:other|next|second|another|external|secondary|different)\\s+(?:screen|display|monitor)$"
        if let groups = RioText.firstMatch(nextScreen, in: s) {
            return windowClause(groups[1], .nextScreen, verb: verb)
        }
        // Center: "put Chrome in the center".
        let centered = "^\(Self.moveVerbs)\\s+\(Self.article)(.*?)\\s*(?:window\\s+)?(?:in|at|to|into)\\s+(?:the\\s+)?(?:center|centre|middle)(?:\\s+of\\s+(?:the|my)\\s+screen)?$"
        if let groups = RioText.firstMatch(centered, in: s) {
            return windowClause(groups[1], .center, verb: verb)
        }
        // Halves: "move Chrome to the left", "snap chrome right", "put it on top".
        let halves = "^\(Self.moveVerbs)\\s+\(Self.article)(.*?)\\s*(?:window\\s+)?(?:over\\s+)?(?:(?:to|on|at|in|into|onto)\\s+)?(?:the\\s+)?(left|right|top|bottom)(?:\\s+(?:half|side|part))?(?:\\s+of\\s+(?:the|my)\\s+(?:screen|display|monitor))?$"
        if let groups = RioText.firstMatch(halves, in: s), let direction = groups[2]?.lowercased() {
            return windowClause(groups[1], Self.half(direction), verb: verb)
        }
        if let groups = RioText.firstMatch(#"^(?:maximi[sz]e|enlarge|expand)(?:\s+(?:the|my))?(?:\s+(.*?))?(?:\s+window)?$"#, in: s) {
            return windowClause(groups[1], .maximize, verb: verb)
        }
        if let groups = RioText.firstMatch(#"^make\s+(?:(?:the|my)\s+)?(.*?)\s*(?:window\s+)?(?:full\s?screen|maximi[sz]ed|fill the screen)$"#, in: s) {
            return windowClause(groups[1], .maximize, verb: verb)
        }
        if let groups = RioText.firstMatch(#"^(?:go\s+)?full\s?screen(?:\s+(?:the|my))?(?:\s+(.*?))?(?:\s+window)?$"#, in: s) {
            return windowClause(groups[1], .maximize, verb: verb)
        }
        if let groups = RioText.firstMatch(#"^cent(?:er|re)(?:\s+(?:the|my))?(?:\s+(.*?))?(?:\s+window)?$"#, in: s) {
            return windowClause(groups[1], .center, verb: verb)
        }
        if let groups = RioText.firstMatch(#"^minimi[sz]e(?:\s+(?:the|my))?(?:\s+(.*?))?(?:\s+window)?$"#, in: s) {
            return windowClause(groups[1], .minimize, verb: verb)
        }
        return nil
    }

    static func half(_ direction: String) -> WindowPlacement {
        switch direction {
        case "left": return .leftHalf
        case "right": return .rightHalf
        case "top": return .topHalf
        default: return .bottomHalf
        }
    }

    // MARK: Side by side

    /// "split screen Chrome and Safari", "put Chrome and Warp side by side", and
    /// "open Chrome and Safari and put them side by side". Two known apps only.
    func parseSideBySide(_ body: String) -> RioParseAnalysis? {
        let text = body.trimmingCharacters(in: CharacterSet(charactersIn: " .!?,;"))
        let trailing = #"^(.*?)[\s,]*(?:and\s+|then\s+)?(?:put|place|snap|tile|arrange|lay\s+out|set)\s+(?:them|those|both|the\s+two)\s+(?:up\s+)?(?:side\s+by\s+side|next\s+to\s+each\s+other|in\s+(?:a\s+)?split\s+screen)$"#
        if let groups = RioText.firstMatch(trailing, in: text), let prefix = groups[1], !prefix.isEmpty,
           case let opened = analyze(prefix), case .actions(let actions) = opened.parse {
            var names: [String] = []
            for action in actions {
                switch action {
                case .openApp(let name), .switchToApp(let name): names.append(name)
                default: break
                }
            }
            guard names.count >= 2 else { return nil }
            let layout = actions + [Self.sideBySide(names[names.count - 2]), Self.sideBySide(names[names.count - 1], right: true)]
            return RioParseAnalysis(parse: .actions(layout), isConfident: opened.isConfident, resolverText: text)
        }
        // "Chrome left, Warp right": two installed apps, one per side.
        let sides = #"^(.+?)\s+(?:(?:on|to)\s+(?:the\s+)?)?(left|right)[\s,]+(?:and\s+)?(.+?)\s+(?:(?:on|to)\s+(?:the\s+)?)?(left|right)$"#
        if let groups = RioText.firstMatch(sides, in: text), let firstSide = groups[2]?.lowercased(), let secondSide = groups[4]?.lowercased(),
           firstSide != secondSide, let first = groups[1].flatMap(knownAppName), let second = groups[3].flatMap(knownAppName), first != second {
            let (left, right) = firstSide == "left" ? (first, second) : (second, first)
            return RioParseAnalysis(
                parse: .actions([Self.sideBySide(left), Self.sideBySide(right, right: true)]), isConfident: true, resolverText: text
            )
        }
        let named = [
            #"^(?:(?:put|place|snap|tile|arrange|show|set\s+up)\s+)?(.+?)\s+and\s+(.+?)\s+(?:side\s+by\s+side|next\s+to\s+each\s+other)$"#,
            #"^(?:split\s+(?:the\s+)?(?:screen|view)|split\s+screen)(?:\s+(?:with|between))?\s+(.+?)\s+and\s+(.+)$"#,
            #"^(?:put|place|snap|tile|arrange)\s+(.+?)\s+and\s+(.+?)\s+in\s+(?:a\s+)?split\s+screen$"#,
        ]
        for pattern in named {
            guard let groups = RioText.firstMatch(pattern, in: text), let first = groups[1], let second = groups[2],
                  let left = knownAppName(first), let right = knownAppName(second), left != right else { continue }
            return RioParseAnalysis(
                parse: .actions([Self.sideBySide(left), Self.sideBySide(right, right: true)]), isConfident: true, resolverText: text
            )
        }
        return nil
    }

    private static func sideBySide(_ name: String, right: Bool = false) -> RioAction {
        .window(WindowCommand(appName: name, placement: right ? .rightHalf : .leftHalf))
    }

    private func knownAppName(_ spoken: String) -> String? {
        let cleaned = cleanTarget(RioText.replacing(#"^(?:the|my)\s+"#, with: "", in: spoken))
        guard Self.isPlausibleTarget(cleaned) else { return nil }
        return AppNameMatcher.bestMatch(for: cleaned, in: installedApps)?.name
    }

    /// `rawApp` is the words between the verb and the placement; nil result means "not understood".
    private func windowClause(_ rawApp: String?, _ placement: WindowPlacement, verb: String) -> ParsedClause? {
        guard let name = windowAppName(rawApp) else { return nil }
        return ParsedClause(
            action: .window(WindowCommand(appName: name.spoken, placement: placement)), verb: verb, isConfident: name.isKnown
        )
    }

    /// Outer nil rejects the phrase; `spoken == nil` means the frontmost window. `isKnown` is
    /// false when the name is not an installed app (only a guess).
    private func windowAppName(_ raw: String?) -> (spoken: String?, isKnown: Bool)? {
        var text = (raw ?? "").trimmingCharacters(in: .whitespaces)
        text = RioText.replacing(#"^(?:the|my)\s+"#, with: "", in: text)
        text = RioText.replacing(#"\s+(?:window|app|application|browser)$"#, with: "", in: text)
        let lowered = text.lowercased()
        let frontmost: Set<String> = ["", "this", "it", "that", "window", "current", "front", "frontmost", "active", "this app", "the app", "app", "current window"]
        if frontmost.contains(lowered) { return (nil, true) }
        // Quarters like "top left" are not supported; the direction would be misread as the app name.
        if let last = lowered.split(separator: " ").last,
           ["top", "bottom", "left", "right", "upper", "lower", "to", "on", "at", "in"].contains(String(last)) {
            return nil
        }
        guard Self.isPlausibleTarget(text) else { return nil }
        if let match = AppNameMatcher.match(for: text, in: installedApps) { return (match.app.name, match.kind.isConfident) }
        return (text, false)
    }

    // MARK: App verbs

    private static let rejectedFirstWords: Set<String> = [
        "a", "an", "new", "this", "that", "it", "its", "these", "those", "some", "any", "all", "everything",
        "every", "file", "files", "folder", "folders", "window", "windows", "tab", "tabs", "door", "lights",
        "light", "here", "there", "them", "him", "her", "me", "us", "what", "how", "why", "when",
        "where", "who", "which", "anything", "something", "someone", "computer", "mac", "laptop", "pc",
        "down", "up", "off", "on",
    ]

    /// Words that name a thing, not a joke or a sentence.
    static func isPlausibleTarget(_ text: String) -> Bool {
        let words = text.lowercased().split(separator: " ").map(String.init)
        guard (1...8).contains(words.count), let first = words.first else { return false }
        guard !rejectedFirstWords.contains(first) else { return false }
        return text.contains(where: { $0.isLetter || $0.isNumber })
    }

    func parseAppVerb(_ s: String, inherited: Bool) -> ParsedClause? {
        let lenientOpen = #"open(?:\s+up)?|launch|fire\s+up|boot\s+up"#
        let strictOpen = #"start(?:\s+up)?|run|bring\s+up|pull\s+up|load"#

        if let groups = RioText.firstMatch("^(\(lenientOpen))\\s+(.+)$", in: s), let verb = groups[1], let target = groups[2] {
            return openLike(target, verb: verb, requireKnown: inherited, asSwitch: false)
        }
        if let groups = RioText.firstMatch("^(\(strictOpen))\\s+(.+)$", in: s), let verb = groups[1], let target = groups[2] {
            return openLike(target, verb: verb, requireKnown: true, asSwitch: false)
        }
        if let groups = RioText.firstMatch(#"^(switch\s+(?:over\s+)?to)\s+(.+)$"#, in: s), let verb = groups[1], let target = groups[2] {
            return openLike(target, verb: verb, requireKnown: inherited, asSwitch: true)
        }
        if let groups = RioText.firstMatch(#"^(go\s+to|jump\s+to|show(?:\s+me)?|take\s+me\s+to|focus(?:\s+on)?|bring\s+(?:me\s+)?to|activate|navigate\s+to|visit)\s+(.+)$"#, in: s),
           let verb = groups[1], let target = groups[2] {
            return openLike(target, verb: verb, requireKnown: true, asSwitch: true)
        }
        if let groups = RioText.firstMatch(#"^(quit|close|kill|exit|terminate|force\s+quit|shut\s+down|shut)\s+(.+)$"#, in: s),
           let verb = groups[1], let target = groups[2] {
            return appOnly(target, verb: verb, requireKnown: inherited) { .quitApp(name: $0) }
        }
        if let groups = RioText.firstMatch(#"^(hide)\s+(.+)$"#, in: s), let verb = groups[1], let target = groups[2] {
            return appOnly(target, verb: verb, requireKnown: inherited) { .hideApp(name: $0) }
        }
        return nil
    }

    private func cleanTarget(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)
        text = RioText.replacing(#"^(?:(?:the|my|up|out)\s+)+"#, with: "", in: text)
        // "open the website amazon dot com": the noun is not part of the name.
        text = RioText.replacing(#"^(?:(?:the|my)\s+)?(?:web\s?site|site|web\s?page|page)\s+(?=\S)"#, with: "", in: text)
        let tails = [
            #"\s+(?:in|on)\s+(?:the\s+|my\s+)?(?:browser|web|internet|chrome|safari)$"#,
            #"\s+(?:app|application|program|(?:web\s+)?browser)$"#,
            #"\s+again$"#,
        ]
        for tail in tails { text = RioText.replacing(tail, with: "", in: text) }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// "open Chrome in incognito": the mode is left to the smart resolver.
    private static let privateModeTail = #"\s+(?:in|with)\s+(?:an?\s+)?(?:incognito|private|privacy)(?:\s+(?:mode|window|tab|browsing))?$"#

    /// open/launch/switch: an app wins over a website unless the app match is only a loose one.
    private func openLike(_ rawTarget: String, verb: String, requireKnown: Bool, asSwitch: Bool) -> ParsedClause? {
        var target = cleanTarget(rawTarget)
        let wantsPrivateMode = RioText.matches(Self.privateModeTail, target)
        if wantsPrivateMode { target = cleanTarget(RioText.replacing(Self.privateModeTail, with: "", in: target)) }
        guard Self.isPlausibleTarget(target) else { return nil }
        let verbText = verb.lowercased()
        func make(_ name: String) -> RioAction { asSwitch ? .switchToApp(name: name) : .openApp(name: name) }

        if let url = RioWebURLs.localURL(fromSpoken: target) ?? RioWebURLs.domainURL(fromSpoken: target) {
            return ParsedClause(action: .openURL(url), verb: verbText)
        }
        // "open chrome and canvas", "open canvas in safari": the owner's own Canvas site.
        if RioText.compact(target) == "canvas", let canvas = RioCanvasConfig.configuredBase {
            return ParsedClause(action: .openURL(canvas), verb: verbText)
        }
        if let file = documentTarget(raw: rawTarget, target: target) {
            return ParsedClause(action: .openFile(query: file), verb: verbText)
        }
        target = withoutArabicArticle(target)
        let site = RioWebURLs.knownSite(compactName: RioText.compact(target))
        if let match = AppNameMatcher.match(for: target, in: installedApps) {
            if let site, !match.kind.isStrong {
                return ParsedClause(action: .openURL(site), verb: verbText)
            }
            return ParsedClause(action: make(match.app.name), verb: verbText, isConfident: match.kind.isConfident && !wantsPrivateMode)
        }
        if let site { return ParsedClause(action: .openURL(site), verb: verbText) }
        if requireKnown { return nil }
        // Not installed, not a known site: only a name that clearly names an app ("Photoshop",
        // "the Photoshop app") gets "I couldn't find it". The rest goes to the smart resolver.
        // Either way it is a guess, so the smart resolver gets the first say.
        guard Self.looksLikeAppName(raw: rawTarget, target: target) else { return nil }
        return ParsedClause(action: make(target), verb: verbText, isConfident: false)
    }

    private static let documentWords = #"\b(?:notes|homework|hw|slides|pdf|syllabus|lecture|essay|resume|doc|docs|document|documents)\b"#

    /// "open my MAT 108 notes" is a file, not an app called "MAT 108 notes". A bare "my notes"
    /// stays the Notes app, and an installed app or known site with that name wins.
    private func documentTarget(raw: String, target: String) -> String? {
        guard RioText.matches(#"^\s*(?:my|the|our)\s+"#, raw), target.split(separator: " ").count >= 2,
              RioText.matches(Self.documentWords, target),
              RioWebURLs.knownSite(compactName: RioText.compact(target)) == nil,
              AppNameMatcher.match(for: target, in: installedApps)?.kind.isStrong != true else { return nil }
        return target
    }

    /// "open el WhatsApp": the Arabic article goes only when the name without it is an app or a
    /// known site, so "Al Jazeera" keeps its "Al".
    private func withoutArabicArticle(_ target: String) -> String {
        guard let rest = RioText.firstMatch(#"^(?:el|al)\s+(.+)$"#, in: target)?[1] else { return target }
        let whole = RioText.compact(target)
        if AppNameMatcher.match(for: target, in: installedApps) != nil || RioWebURLs.knownSite(compactName: whole) != nil { return target }
        let isKnown = AppNameMatcher.match(for: rest, in: installedApps) != nil || RioWebURLs.knownSite(compactName: RioText.compact(rest)) != nil
        return isKnown ? rest : target
    }

    /// A capitalised word ("Photoshop") or an explicit "app" suffix.
    private static func looksLikeAppName(raw: String, target: String) -> Bool {
        if RioText.matches(#"\s(?:app|application|program)$"#, raw) { return true }
        return target.split(separator: " ").contains { $0.first?.isUppercase == true }
    }

    /// quit/hide: only apps, never websites.
    private func appOnly(_ rawTarget: String, verb: String, requireKnown: Bool, build: (String) -> RioAction) -> ParsedClause? {
        let target = cleanTarget(rawTarget)
        guard Self.isPlausibleTarget(target) else { return nil }
        if let match = AppNameMatcher.match(for: target, in: installedApps) {
            return ParsedClause(action: build(match.app.name), verb: verb.lowercased(), isConfident: match.kind.isConfident)
        }
        if requireKnown || !Self.looksLikeAppName(raw: rawTarget, target: target) { return nil }
        return ParsedClause(action: build(target), verb: verb.lowercased(), isConfident: false)
    }
}
