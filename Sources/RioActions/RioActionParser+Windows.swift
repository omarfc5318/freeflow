import Foundation

/// Window placement and app verbs (open, quit, switch, hide) plus website-vs-app resolution.
extension RioActionParser {
    // MARK: Windows

    private static let moveVerbs = #"(?:put|move|snap|place|send|shove|slide|throw|drag|tile|stick|push)"#
    private static let article = #"(?:(?:the|my)\s+)?"#

    func parseWindow(_ s: String, inherited: Bool) -> ParsedClause? {
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
            let placement: WindowPlacement
            switch direction {
            case "left": placement = .leftHalf
            case "right": placement = .rightHalf
            case "top": placement = .topHalf
            default: placement = .bottomHalf
            }
            return windowClause(groups[1], placement, verb: verb)
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

    /// `rawApp` is the words between the verb and the placement; nil result means "not understood".
    private func windowClause(_ rawApp: String?, _ placement: WindowPlacement, verb: String) -> ParsedClause? {
        guard let name = windowAppName(rawApp) else { return nil }
        return ParsedClause(action: .window(WindowCommand(appName: name.spoken, placement: placement)), verb: verb)
    }

    /// Outer nil rejects the phrase; `spoken == nil` means the frontmost window.
    private func windowAppName(_ raw: String?) -> (spoken: String?, accepted: Bool)? {
        var text = (raw ?? "").trimmingCharacters(in: .whitespaces)
        text = RioText.replacing(#"^(?:the|my)\s+"#, with: "", in: text)
        text = RioText.replacing(#"\s+(?:window|app|application)$"#, with: "", in: text)
        let lowered = text.lowercased()
        let frontmost: Set<String> = ["", "this", "it", "that", "window", "current", "front", "frontmost", "active", "this app", "the app", "app", "current window"]
        if frontmost.contains(lowered) { return (nil, true) }
        // Quarters like "top left" are not supported; the direction would be misread as the app name.
        if let last = lowered.split(separator: " ").last,
           ["top", "bottom", "left", "right", "upper", "lower", "to", "on", "at", "in"].contains(String(last)) {
            return nil
        }
        guard Self.isPlausibleTarget(text) else { return nil }
        return (appDisplayName(for: text), true)
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
        let tails = [
            #"\s+(?:in|on)\s+(?:the\s+|my\s+)?(?:browser|web|internet|chrome|safari)$"#,
            #"\s+(?:app|application|program)$"#,
            #"\s+again$"#,
        ]
        for tail in tails { text = RioText.replacing(tail, with: "", in: text) }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private func appDisplayName(for spoken: String) -> String {
        AppNameMatcher.bestMatch(for: spoken, in: installedApps)?.name ?? spoken
    }

    /// open/launch/switch: an app wins over a website unless the app match is only a loose one.
    private func openLike(_ rawTarget: String, verb: String, requireKnown: Bool, asSwitch: Bool) -> ParsedClause? {
        let target = cleanTarget(rawTarget)
        guard Self.isPlausibleTarget(target) else { return nil }
        let verbText = verb.lowercased()
        func make(_ name: String) -> RioAction { asSwitch ? .switchToApp(name: name) : .openApp(name: name) }

        if let url = RioWebURLs.domainURL(fromSpoken: target) {
            return ParsedClause(action: .openURL(url), verb: verbText)
        }
        let site = RioWebURLs.knownSite(compactName: RioText.compact(target))
        if let match = AppNameMatcher.match(for: target, in: installedApps) {
            if let site, !match.kind.isStrong {
                return ParsedClause(action: .openURL(site), verb: verbText)
            }
            return ParsedClause(action: make(match.app.name), verb: verbText)
        }
        if let site { return ParsedClause(action: .openURL(site), verb: verbText) }
        if requireKnown { return nil }
        return ParsedClause(action: make(target), verb: verbText)
    }

    /// quit/hide: only apps, never websites.
    private func appOnly(_ rawTarget: String, verb: String, requireKnown: Bool, build: (String) -> RioAction) -> ParsedClause? {
        let target = cleanTarget(rawTarget)
        guard Self.isPlausibleTarget(target) else { return nil }
        if let match = AppNameMatcher.bestMatch(for: target, in: installedApps) {
            return ParsedClause(action: build(match.name), verb: verb.lowercased())
        }
        if requireKnown { return nil }
        return ParsedClause(action: build(target), verb: verb.lowercased())
    }
}
