import Foundation

/// Deterministic transcript -> [RioAction]. Pure: no AppKit, no I/O. Everything it can emit is in
/// the closed `RioAction` set, and it never emits the smart-only actions. When any part of a
/// transcript is not understood the whole thing is `.unknown`: it never runs half a command.
struct RioActionParser {
    let installedApps: [InstalledApp]
    /// Tests pass this; the app leaves it nil and reads `RioMacroRecordingState`.
    private let macroRecordingOverride: Bool?

    init(installedApps: [InstalledApp], isRecordingMacro: Bool? = nil) {
        self.installedApps = installedApps
        self.macroRecordingOverride = isRecordingMacro
    }

    private var isRecordingMacro: Bool { macroRecordingOverride ?? RioMacroRecordingState.isRecording }

    func parse(_ transcript: String) -> RioActionParse {
        analyze(transcript).parse
    }

    /// The parse plus how sure it is (understanding-first routing, see RioSmartRouting.swift).
    /// A parse is a guess when an app or window target did not resolve to an installed app.
    func analyze(_ transcript: String) -> RioParseAnalysis {
        // "2 and a half minutes" must not split into two clauses on "and" (timers only).
        let body = RioWebSearchRewrite.apply(to: RioTimerPhrases.protectingDurations(in: Self.stripEnvelope(transcript)))
        func sure(_ parse: RioActionParse) -> RioParseAnalysis {
            RioParseAnalysis(parse: parse, isConfident: true, resolverText: unknownText(body, lastWasGreedy: false))
        }
        guard !body.isEmpty else { return sure(.empty) }
        // Remember, notes and maths keep "and", "plus" and commas: claim the whole sentence first.
        // Recall is not here: "what's my next class" must reach the calendar parser first.
        if let whole = RioPersonalPhrases.wholeUtterance(body) { return sure(.actions([whole])) }
        if let layout = parseSideBySide(body) { return layout }
        if let task = RioTaskPhrases.wholeUtterance(body) { return sure(.actions([task])) }
        if let whole = wholeSentence(body) { return sure(.actions(whole)) }

        var clauses = Self.splitClauses(Self.normalizingKeyCombos(body))
        if let last = clauses.last, !Self.startsGreedyCommand(last) {
            let trimmed = Self.stripTrailingFiller(last)
            if trimmed.isEmpty { clauses.removeLast() } else { clauses[clauses.count - 1] = trimmed }
        }
        guard !clauses.isEmpty else { return sure(.empty) }

        let resolverText = unknownText(body, lastWasGreedy: clauses.last.map(Self.startsGreedyCommand) ?? false)
        var actions: [RioAction] = []
        var isConfident = true
        var inheritedVerb: String?
        var lastApp: String?
        for clause in clauses {
            guard let parsed = parseClause(clause, inheritedVerb: inheritedVerb) else {
                return RioParseAnalysis(parse: .unknown(resolverText), isConfident: false, resolverText: resolverText)
            }
            let action = Self.targeting(parsed.action, app: lastApp)
            actions.append(action)
            actions.append(contentsOf: parsed.more)
            isConfident = isConfident && parsed.isConfident
            inheritedVerb = parsed.verb
            switch action {
            case .openApp(let name), .switchToApp(let name): lastApp = name
            case .window: break
            default: lastApp = nil
            }
        }
        return RioParseAnalysis(parse: .actions(Self.mergingSiteSearches(actions)), isConfident: isConfident, resolverText: resolverText)
    }

    /// "open Chrome and put it on the left": "it" is Chrome, not whatever window is in front
    /// while Chrome is still launching.
    private static func targeting(_ action: RioAction, app: String?) -> RioAction {
        guard let app, case .window(let command) = action, command.appName == nil else { return action }
        return .window(WindowCommand(appName: app, placement: command.placement))
    }

    /// "open youtube and play 3blue1brown" is one YouTube search, not YouTube plus Spotify.
    private static func mergingSiteSearches(_ actions: [RioAction]) -> [RioAction] {
        var result: [RioAction] = []
        for action in actions {
            if case .playMusic(let query) = action, case .openURL(let site)? = result.last,
               let search = RioWebURLs.videoSiteSearchURL(site: site, query: query) {
                result[result.count - 1] = .openURL(search)
            } else {
                result.append(action)
            }
        }
        return result
    }

    // MARK: Whole sentences

    /// Phrases that own the whole sentence, commas and "and" included. Automations and Claude
    /// prompts are only taken here when the sentence would otherwise be split.
    private func wholeSentence(_ body: String) -> [RioAction]? {
        let simple = RioText.simplify(body)
        if Self.isStopListening(simple) { return [.stopListening] }
        if isRecordingMacro, Self.isBareMacroStop(simple) { return [.stopRecordingMacro] }
        let claude = Self.normalizingClaude(body)
        if RioText.matches(#"^(?:please\s+)?(?:tell|ask)\s+claude\b"#, claude),
           let action = RioMeetingPhrases.parse(raw: claude, simplified: RioText.simplify(claude)) {
            return [action]
        }
        if Self.splitClauses(body).count > 1,
           let action = RioAutomationPhrases.parse(raw: body, simplified: simple) {
            return [action]
        }
        return nil
    }

    /// Whisper hears "Claude" as "cloud" ("tell cloud to run the tests").
    static func normalizingClaude(_ text: String) -> String {
        RioText.replacing(#"^((?:please\s+)?(?:tell|ask))\s+(?:cloud|clod|claud|clawed|cloude)\b"#, with: "$1 Claude", in: text)
    }

    /// While "watch me" is recording: "stop recording", "I'm done", "that's it".
    private static func isBareMacroStop(_ s: String) -> Bool {
        RioText.matches(
            #"^(?:(?:stop|end|finish)\s+(?:recording|watching)(?:\s+(?:now|it))?|(?:im|i am|were|we are)\s+(?:done|finished)|(?:all\s+)?done(?:\s+recording)?|finished|thats it)$"#,
            s
        )
    }

    /// "Cmd+Tab" and "command plus shift plus T" join keys; a final "command plus" is the + key.
    static func normalizingKeyCombos(_ text: String) -> String {
        let mods = "command|cmd|control|ctrl|option|opt|alt|shift"
        let keyWord = "(?:\(mods)|[a-z0-9]|f[0-9]{1,2}|tab|enter|return|space|escape|esc|delete|up|down|left|right)"
        var result = RioText.replacing("\\b(\(mods))\\s*\\+\\s*(?=[A-Za-z0-9])", with: "$1 ", in: text)
        result = RioText.replacing("\\b(\(mods))\\s+plus\\s+(?=\(keyWord)\\b)", with: "$1 ", in: result)
        return RioText.replacing("\\b(\(mods))\\s+plus\\b", with: "$1 equals", in: result)
    }

    /// The text handed to the smart resolver: the command without the name or trailing filler.
    private func unknownText(_ body: String, lastWasGreedy: Bool) -> String {
        let text = lastWasGreedy ? body : Self.stripTrailingFiller(body)
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " .!,;:"))
    }

    // MARK: Clause parsing

    struct ParsedClause {
        let action: RioAction
        /// The verb a following verb-less clause may reuse ("open Chrome and Spotify").
        let verb: String?
        /// False when the target is only a guess (not an installed app, a known site or the
        /// front window): the smart resolver is asked first.
        var isConfident = true
        /// Steps that run right after `action` ("type git status and press enter").
        var more: [RioAction] = []
    }

    private func parseClause(_ raw: String, inheritedVerb: String?) -> ParsedClause? {
        if let direct = parseDirect(raw) { return direct }
        guard let verb = inheritedVerb else { return nil }
        return parseInherited(verb: verb, rest: RioText.simplify(raw))
    }

    private func parseDirect(_ raw: String) -> ParsedClause? {
        if let typed = Self.parseType(raw), let first = typed.first {
            return ParsedClause(action: first, verb: nil, more: Array(typed.dropFirst()))
        }
        if let term = Self.findInPageTerm(raw) {
            return ParsedClause(action: .browser(.find), verb: nil, more: [.typeText(term)])
        }
        if let action = parseSearch(raw) { return ParsedClause(action: action, verb: nil) }
        let s = RioText.simplify(raw)
        guard !s.isEmpty else { return nil }
        if Self.isStopListening(s) { return ParsedClause(action: .stopListening, verb: nil) }
        if let action = Self.parseVolume(s) ?? Self.parseMedia(s) ?? Self.parseLock(s)
            ?? Self.parseScreenshot(s) ?? Self.parseDoNotDisturb(s) {
            return ParsedClause(action: action, verb: nil)
        }
        if let repeated = Self.parseRepeatedKey(s) { return repeated }
        // "press command tab" is a shortcut, never a click on a tab called "Cmd".
        if RioText.matches(#"^(?:press|hit)\s"#, s), let combo = RioKeyCombos.parse(s),
           combo.command || combo.control || combo.option || combo.shift {
            return ParsedClause(action: .pressKeys(combo), verb: "press")
        }
        if let action = RioExtraPhrases.parse(raw: raw, simplified: s) {
            if case .pressKeys = action { return ParsedClause(action: action, verb: "press") }
            return ParsedClause(action: action, verb: nil)
        }
        if let window = parseWindow(s, inherited: false) { return window }
        return parseAppVerb(s, inherited: false)
    }

    /// "Warp on the right" after "put Chrome on the left"; "Spotify" after "open Chrome";
    /// "delete" after "press command A".
    private func parseInherited(verb: String, rest: String) -> ParsedClause? {
        guard !rest.isEmpty else { return nil }
        let combined = "\(verb) \(rest)"
        if verb == "press" {
            return RioKeyCombos.parse(combined).map { ParsedClause(action: .pressKeys($0), verb: "press") }
        }
        if let window = parseWindow(combined, inherited: true) { return window }
        return parseAppVerb(combined, inherited: true)
    }

    // MARK: Keys

    static let maxKeyRepeats = 10

    /// "press enter twice", "press the down arrow three times": the same plain key, repeated.
    /// Shortcuts never repeat ("press command q twice" would quit two apps).
    private static func parseRepeatedKey(_ s: String) -> ParsedClause? {
        guard let groups = RioText.firstMatch(#"^((?:press|hit|tap)\s+.+?)\s+(?:(once|twice|thrice)|(\w+)\s+times)$"#, in: s),
              let keys = groups[1], let combo = RioKeyCombos.parse(keys),
              !combo.command, !combo.control, !combo.option else { return nil }
        let count: Int?
        switch groups[2]?.lowercased() {
        case "once": count = 1
        case "twice": count = 2
        case "thrice": count = 3
        default: count = groups[3].flatMap { RioText.number(from: $0) }
        }
        guard let count, (1...maxKeyRepeats).contains(count) else { return nil }
        return ParsedClause(action: .pressKeys(combo), verb: "press", more: Array(repeating: .pressKeys(combo), count: count - 1))
    }

    // MARK: Type

    /// "type git status and press enter" types, then presses the key.
    private static let typedKeyTail =
        #"^(.+?)(?:\s*,\s*(?:and\s+(?:then\s+)?|then\s+)?|\s+(?:and\s+(?:then\s+)?|then\s+))(?:press|hit)\s+(?:the\s+)?(enter|return|tab)(?:\s+key)?$"#

    private static func parseType(_ raw: String) -> [RioAction]? {
        guard let groups = RioText.firstMatch(#"^(type|write)\s*[:,]?\s+(.+)$"#, in: raw),
              let verb = groups[1]?.lowercased(), let rest = groups[2] else { return nil }
        var text = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // "type hello into the search box" fills a field (builder J), not dictation at the cursor.
        if RioText.matches(#"\s(?:in|into)\s+(?:the\s+)?.+\s(?:box|field|bar|input)$"#, text.lowercased()) { return nil }
        if verb == "write" {
            // "write down quiz on Friday" is a note, never text typed into the focused field.
            if let note = RioText.firstMatch(#"^down\s+(?:that\s+)?(.+)$"#, in: text)?[1] {
                let body = note.trimmingCharacters(in: CharacterSet(charactersIn: " .!\n\t"))
                guard !body.isEmpty, body.count <= RioNotesScripts.maxLength else { return nil }
                return [.addNote(text: body.prefix(1).uppercased() + body.dropFirst())]
            }
            // "write a poem about the sea" is a request for the smart resolver, not dictation.
            if RioText.matches(#"^(?:a|an|me|us|up|to|my|something|it|him|her|them|the|some|for|down)\b"#, text) { return nil }
            // "write that I'm out of office": the "that" introduces the words.
            if let words = RioText.firstMatch(#"^that\s+(.+)$"#, in: text)?[1] {
                guard !RioText.matches(#"^(?:down|up|out|again|for\s+me)$"#, words) else { return nil }
                text = words
            }
        }
        var actions: [RioAction] = []
        if let groups = RioText.firstMatch(typedKeyTail, in: text), let words = groups[1], let key = groups[2],
           let combo = RioKeyCombos.parse("press \(key)") {
            let typed = words.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            guard !typed.isEmpty else { return nil }
            actions = [.typeText(typed), .pressKeys(combo)]
        } else {
            actions = [.typeText(text)]
        }
        return actions
    }

    // MARK: Stop listening

    private static func isStopListening(_ s: String) -> Bool {
        RioText.matches(
            #"^(?:(?:ok|okay|alright|all right|so|thanks|thank you|cool|great|perfect)\s+)*(?:you can\s+)?(?:stop listening|go to sleep|thats all(?: for now)?|that is all(?: for now)?|thatll be all|that will be all|stop conversation mode|end conversation mode|conversation mode off|turn off conversation mode|stop the conversation|good ?bye|bye(?: bye)?(?: for now)?|good ?night)(?:\s+(?:rio|thanks|thank you))?$"#,
            s
        )
    }

    // MARK: Search

    /// "search this page for budget", "find useEffect on this page": the term for Find.
    private static func findInPageTerm(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: CharacterSet(charactersIn: " .!?,;:"))
        let page = #"(?:this|the|current)\s+(?:web\s?)?page"#
        let patterns = [
            "^(?:search|find|look)\\s+(?:on\\s+|in\\s+|through\\s+)?\(page)\\s+for\\s+(.+)$",
            "^(?:find|search\\s+for|look\\s+for)\\s+(.+?)\\s+(?:on|in)\\s+\(page)$",
            "^find\\s+(?:on|in)\\s+(?:the\\s+|this\\s+)?page\\s+(.+)$",
        ]
        for pattern in patterns {
            if let groups = RioText.firstMatch(pattern, in: text), let term = cleanQuery(groups[1]) { return term }
        }
        return nil
    }

    private func parseSearch(_ raw: String) -> RioAction? {
        var text = raw.trimmingCharacters(in: CharacterSet(charactersIn: " .!,;:"))
        // A polite tail never belongs to the query.
        text = RioText.replacing(#"[,\s]+(?:please|bro)$"#, with: "", in: text)

        let sites: [(name: String, build: (String) -> URL?)] = [
            (#"(?:youtube|you\s?tube)"#, RioWebURLs.youtubeSearchURL(query:)),
            (#"amazon(?:\.com)?"#, RioWebURLs.amazonSearchURL(query:)),
            (#"(?:github|git\s?hub)(?:\.com)?"#, RioWebURLs.githubSearchURL(query:)),
            (#"(?:stack\s?overflow|stack\s+over\s+flow)(?:\.com)?"#, RioWebURLs.stackOverflowSearchURL(query:)),
        ]
        for site in sites {
            let patterns = [
                "^(?:search|look)\\s+(?:on\\s+|in\\s+)?\(site.name)\\s+(?:for\\s+)?(.+)$",
                "^(?:search|look)\\s+(?:up\\s+|for\\s+)?(.+?)\\s+(?:on|in)\\s+\(site.name)$",
                "^(?:find|search)\\s+(.+?)\\s+on\\s+\(site.name)$",
                "^\(site.name)\\s+search\\s+(?:for\\s+)?(.+)$",
            ]
            for pattern in patterns {
                if let groups = RioText.firstMatch(pattern, in: text), let query = Self.cleanQuery(groups[1]) {
                    return site.build(query).map(RioAction.openURL)
                }
            }
        }
        // "play lofi on youtube" / "watch 3blue1brown on YouTube" is a YouTube search.
        if let groups = RioText.firstMatch(#"^(?:play|watch|put\s+on)\s+(.+?)\s+on\s+(?:youtube|you\s?tube)$"#, in: text),
           let query = Self.cleanQuery(groups[1]),
           !RioText.matches(#"^(?:it|this|that|something|anything|(?:the|this|that|a)\s+(?:video|clip|one))$"#, query) {
            return RioWebURLs.youtubeSearchURL(query: query).map(RioAction.openURL)
        }
        if let site = Self.siteSearch(text) { return site }
        if RioText.matches(#"^google\b"#, text) {
            let whole = RioText.simplify(text)
            if RioWebURLs.isKnownSite(spoken: whole) { return nil }
            if AppNameMatcher.match(for: whole, in: installedApps)?.kind.isStrong == true { return nil }
            if RioText.compact(whole) == "googlechrome" { return nil }
        }
        // "search my history for the budget" is the owner's own dictation timeline (N), not the web.
        if RioText.matches(#"^search\s+(?:through\s+)?my\s+(?:dictations?|history|timeline|transcripts?|past\s+dictations?)\s+for\b"#, text) {
            return nil
        }
        let webPatterns = [
            #"^search\s+(?:(?:the\s+web|google|online|the\s+internet|bing)\s+)?(?:for\s+|up\s+)?(.+)$"#,
            #"^look\s+up\s+(.+)$"#,
            #"^look\s+(.+?)\s+up$"#,
            #"^google\s+(?:for\s+)?(.+)$"#,
        ]
        for pattern in webPatterns {
            if let groups = RioText.firstMatch(pattern, in: text), let query = Self.cleanQuery(groups[1]) {
                // "look up the weather in Dubai" is the weather, not a web page about it.
                let simple = RioText.simplify(query)
                if let answer = RioWeatherPhrases.parse(simple) ?? RioNewsPhrases.parse(simple) { return answer }
                return .webSearch(query: query)
            }
        }
        return nil
    }

    /// "search reddit for mechanical keyboards": a Google search limited to that known site.
    private static func siteSearch(_ text: String) -> RioAction? {
        guard let groups = RioText.firstMatch(#"^search\s+(?:on\s+|in\s+)?(.+?)\s+for\s+(.+)$"#, in: text),
              let spoken = groups[1], let query = cleanQuery(groups[2]),
              !["google", "bing", "duckduckgo", "yahoo", "theweb", "web", "theinternet", "internet"].contains(RioText.compact(spoken)),
              let host = RioWebURLs.knownSite(compactName: RioText.compact(spoken))?.host else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return .webSearch(query: "site:\(bare) \(query)")
    }

    private static func cleanQuery(_ raw: String?) -> String? {
        guard var query = raw?.trimmingCharacters(in: CharacterSet(charactersIn: " .!;:\"")) else { return nil }
        query = RioText.collapseWhitespace(query)
        if RioText.matches(#"^(?:for|up|the web|google|youtube)$"#, query) { return nil }
        return query.isEmpty ? nil : query
    }

    // MARK: Envelope: name, greetings, fillers

    private static let nameVariants = "rio|ryo|reo|rhio|riyo|ryoh|rioh|ria|rea|rhea"
    /// Mishearings that are only a name when a command verb follows ("rear open notes").
    private static let nameBeforeVerb = "rear|real"
    private static let commandVerbs = "open|launch|quit|close|switch|play|pause|set|turn|start|stop|put|move|search|go|show|mute|unmute|volume|hide|take|what|how|remind|remember|undo|help|text|message"
    /// Verbs a lone interjection may stand in front of ("like open Chrome").
    private static let leadVerbs = commandVerbs + "|type|write|find|lock|tell|ask|read|send|press|hit|maximi[sz]e|minimi[sz]e|cent(?:er|re)|whats|when|where|who|is|do|can|could|make|give|add|note|jot|call|email|reply|skip|resume|translate|summari[sz]e|google|look"
    /// Arabic fillers Whisper keeps in English speech; never a command on their own.
    private static let arabicFillers = #"yalla|habibi|habibti|wallah|wallahi|inshallah|insha\s?allah|law\s+samaht"#
    /// Interjections set off by a comma ("Rio, sorry, open Chrome"). "wait" and "never mind"
    /// only go when more follows, so a bare "never mind" still reaches undo.
    private static let commaInterjections = arabicFillers + #"|shoof|like|basically|actually|sorry|oops|oh|right|wait|hold\s+on|never\s?mind|forget\s+that"#
    private static let hesitation = #"(?:\s*,)?\s*(?<![\p{L}\p{N}'\x{2019}])(?:uh+|um+|er+m|erm|hmm+|mhm|mm+)(?![\p{L}\p{N}'\x{2019}])[.!?]?\s*,?"#

    /// Removes a leading name/greeting/filler ("yo Rio, can you ...") and returns the rest.
    static func stripEnvelope(_ transcript: String) -> String {
        var text = transcript.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t\"\u{201C}\u{201D}"))
        let leading = [
            #"^(?:hey|yo|yoo|okay|ok|alright|all right|so|well|um|uh|erm|hmm|mm|please)\b[\s,.!?:;-]*"#,
            "^(?:hi|hello)\\b(?:[\\s,.!?:;]|-(?![\\d.(]))*(?=(?:\(nameVariants))\\b)",
            "^(?:\(nameVariants))(?:['\u{2019}]?s)?\\b(?:[\\s,.!?:;]|-(?![\\d.(]))*",
            "^(?:\(nameBeforeVerb))[\\s,.!?:;-]+(?=(?:\(commandVerbs))\\b)",
            "^yo(?:\(nameVariants))\\b(?:[\\s,.!?:;]|-(?![\\d.(]))*",
            "^(?:\(commaInterjections))\\s*[,.!]+\\s*(?=\\S)",
            "^(?:\(arabicFillers)|basically)\\s+(?=\\S)",
            "^(?:like|basically|actually|sorry|oops|oh|shoof|never\\s?mind)\\s+(?=(?:\(leadVerbs))\\b)",
            #"^(?:can|could|would|will)\s+you\s*,?\s+(?:please\s*,?\s+)?"#,
            #"^(?:i\s+(?:want|need)\s+you\s+to|i\s*(?:'|\x{2019})?d\s+like\s+you\s+to|go\s+ahead\s+and|just)\s+"#,
        ]
        var changed = true
        while changed {
            changed = false
            for pattern in leading {
                let next = RioText.replacing(pattern, with: "", in: text)
                if next != text {
                    text = next
                    changed = true
                }
            }
            // A leading minus stays when a number follows ("-2^2"); a dash before words goes.
            text = RioText.replacing(#"^-+\s+"#, with: "", in: text)
            text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:\n\t"))
            // "open, um, Chrome": a hesitation goes with the commas around it, so the comma it
            // leaves can't split the command. Never inside a message body.
            if !startsGreedyCommand(text) {
                let next = RioText.collapseWhitespace(RioText.replacing(hesitation, with: " ", in: text))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,;:\n\t"))
                if next != text {
                    text = next
                    changed = true
                }
            }
        }
        return text
    }

    /// "open Chrome yalla": the Arabic filler goes only after a command, so "when did I say
    /// yalla" keeps its word.
    private static let trailingArabicCommand = "^(?:open|launch|quit|close|switch|play|pause|set|turn|start|stop|put|move|go|show|mute|unmute|hide|take|undo|lock|maximi[sz]e|minimi[sz]e)\\b"

    static func stripTrailingFiller(_ text: String) -> String {
        var result = text
        // "now" stays after "from" and "right" ("an hour from now"); "right now" goes as one;
        // "man" goes only after a comma ("play spider man").
        let pattern = #"(?:[\s,.!?;:]+(?:please|bro|bruh|dude|buddy|thanks|thank you|for me|real quick|quickly|right now)|(?<!\bfrom)(?<!\bright)[\s,.!?;:]+now|\s*,\s*man)\s*[.!?]*$"#
        let arabic = "[\\s,.!?;:]+(?:\(arabicFillers))\\s*[.!?]*$"
        let stripsArabic = RioText.matches(trailingArabicCommand, text)
        while true {
            var next = RioText.replacing(pattern, with: "", in: result)
            if stripsArabic { next = RioText.replacing(arabic, with: "", in: next) }
            if next == result { break }
            result = next
        }
        // A bare filler word is the whole clause.
        if RioText.matches(#"^(?:please|bro|bruh|dude|man|buddy|thanks|thank you|now)[\s.!?,]*$"#, result) { return "" }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " ,.!;:\n\t"))
    }

    // MARK: Clause splitting

    // Message bodies keep "and" and trailing words too: "text Ali saying I'm late and I'll call".
    private static let greedyStart = #"^(?:type|write|search|google|look\s+up|youtube\s+search|you\s?tube\s+search|amazon\s+search|reply|tell\s+(?:them|him|her)|text|message|send\s+(?:a\s+)?(?:text|message))\b"#

    static func startsGreedyCommand(_ clause: String) -> Bool {
        RioText.matches(greedyStart, clause)
    }

    /// Splits on "and", "then", "plus", commas and semicolons. Once a type/search clause starts
    /// it keeps the rest of the sentence, so "search for cats and dogs" stays one query.
    static func splitClauses(_ text: String) -> [String] {
        let pattern = #"\s*,?\s*\b(?:and\s+then|and\s+also|after\s+that|then|and|plus|also)\b\s*|\s*[,;]\s*|\s+&\s+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [text] }
        let full = NSRange(text.startIndex..., in: text)
        var pieces: [(text: String, separator: String)] = []
        var cursor = text.startIndex
        var pendingSeparator = ""
        for match in regex.matches(in: text, options: [], range: full) {
            guard let range = Range(match.range, in: text) else { continue }
            pieces.append((String(text[cursor..<range.lowerBound]), pendingSeparator))
            pendingSeparator = String(text[range])
            cursor = range.upperBound
        }
        pieces.append((String(text[cursor...]), pendingSeparator))

        var clauses: [String] = []
        var index = 0
        while index < pieces.count {
            let piece = pieces[index].text.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.!"))
            if startsGreedyCommand(piece) {
                var merged = pieces[index].text
                for later in pieces[(index + 1)...] { merged += later.separator + later.text }
                clauses.append(merged.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:\n\t")))
                break
            }
            if !piece.isEmpty { clauses.append(piece) }
            index += 1
        }
        return clauses
    }
}
