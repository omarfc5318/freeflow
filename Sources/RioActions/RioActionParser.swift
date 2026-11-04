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
        let said = RioWebSearchRewrite.apply(to: RioTimerPhrases.protectingDurations(in: Self.stripEnvelope(transcript)))
        // "quit Safari, wait no": the last command is taken back; what came before it still runs.
        let takeBack = Self.trailingTakeBack(said)
        let takenBack = takeBack?.remainder
        let body = takenBack ?? said
        func sure(_ parse: RioActionParse) -> RioParseAnalysis {
            RioParseAnalysis(parse: parse, isConfident: true, resolverText: unknownText(said, lastWasGreedy: false))
        }
        func whole(_ actions: [RioAction]) -> RioParseAnalysis {
            sure(takenBack == nil ? .actions(actions) : .empty)
        }
        guard !body.isEmpty else { return sure(.empty) }
        // "open Chrome... actually never mind" takes the whole thing back.
        if Self.cancelsItself(said) || takeBack?.cancelsAll == true { return sure(.empty) }
        // Remember, notes and maths keep "and", "plus" and commas: claim the whole sentence first.
        // Recall is not here: "what's my next class" must reach the calendar parser first.
        if let personal = RioPersonalPhrases.wholeUtterance(body) { return whole([personal]) }
        if let layout = parseSideBySide(body) { return takenBack == nil ? layout : sure(.empty) }
        if let task = RioTaskPhrases.wholeUtterance(body) { return whole([task]) }
        if let sentence = wholeSentence(body) { return whole(sentence) }
        // "Do the same for Warp" after "open Chrome and put it on the left": both steps for Warp.
        if let chain = sameForChain(body) {
            guard takenBack == nil else { return sure(.empty) }
            return RioParseAnalysis(parse: .actions([chain.action] + chain.more), isConfident: chain.isConfident,
                                    resolverText: unknownText(said, lastWasGreedy: false))
        }

        var parts = Self.splitClauseParts(Self.normalizingKeyCombos(body))
        if let last = parts.last, !Self.startsGreedyCommand(last.text) {
            let trimmed = Self.stripTrailingFiller(last.text)
            if trimmed.isEmpty { parts.removeLast() } else { parts[parts.count - 1].text = trimmed }
        }
        // "open Chrome, thanks Rio, quit Xcode": a filler clause in the middle is not a command.
        parts = parts.filter { Self.startsGreedyCommand($0.text) || !Self.stripTrailingFiller($0.text).isEmpty }
        if takenBack != nil, !parts.isEmpty { parts.removeLast() }
        guard !parts.isEmpty else { return sure(.empty) }

        // The resolver hears the take-back too: it must not run what the owner took back.
        let resolverText = unknownText(said, lastWasGreedy: parts.last.map { Self.startsGreedyCommand($0.text) } ?? false)
        var state = ClauseState()
        for part in parts {
            let before = part.isCorrection ? state.undoingLast() : state
            guard let parsed = parseClause(part.text, state: before) else {
                return RioParseAnalysis(parse: .unknown(resolverText), isConfident: false, resolverText: resolverText)
            }
            state = before.adding(parsed)
        }
        return RioParseAnalysis(parse: .actions(Self.mergingSiteSearches(state.actions)), isConfident: state.isConfident, resolverText: resolverText)
    }

    /// What the clauses so far have done. A self-correction ("open Chrome, I mean Safari")
    /// undoes the last clause and parses the new one in its place.
    struct ClauseState {
        var actions: [RioAction] = []
        var isConfident = true
        /// The verb a following verb-less clause may reuse ("open Chrome and Spotify").
        var inheritedVerb: String?
        /// The app "it" means in a later clause ("open Chrome and put it on the left").
        var lastApp: String?
        /// True once a clause opened an app, a site or a tab ("open Chrome, new tab, github.com").
        var hasOpened = false
        private var previous: [ClauseState] = []

        /// The state before the last clause, keeping that clause's verb: "open Chrome, I mean
        /// Safari" opens Safari instead.
        func undoingLast() -> ClauseState {
            guard var before = previous.last else { return self }
            before.inheritedVerb = inheritedVerb
            return before
        }

        func adding(_ parsed: ParsedClause) -> ClauseState {
            var next = self
            next.previous = previous + [self]
            let action = RioActionParser.targeting(parsed.action, app: lastApp)
            next.actions = actions + [action] + parsed.more
            next.isConfident = isConfident && parsed.isConfident
            next.inheritedVerb = parsed.verb
            switch action {
            case .openApp(let name), .switchToApp(let name): next.lastApp = name
            case .window(let command): next.lastApp = command.appName ?? lastApp
            default: next.lastApp = nil
            }
            switch action {
            case .openApp, .switchToApp, .openURL, .browser(.newTab): next.hasOpened = true
            default: break
            }
            return next
        }
    }

    /// "open Chrome and put it on the left": "it" is Chrome, not whatever window is in front
    /// while Chrome is still launching.
    static func targeting(_ action: RioAction, app: String?) -> RioAction {
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
        // While "watch me" records, "I'm done" ends the recording, not the conversation.
        if isRecordingMacro, Self.isBareMacroStop(simple) { return [.stopRecordingMacro] }
        if Self.isStopListening(simple, wholeSentence: true) { return [.stopListening] }
        let claude = Self.normalizingClaude(body)
        // "tell Claude, run the tests", "Claude: add a dark mode toggle" (a comma or colon after
        // the name, so a sentence that merely starts with "Claude" is not taken).
        if RioText.matches(#"^(?:please\s+)?(?:(?:tell|ask)\s+claude\b|claude(?:\s+code)?\s*[,:])"#, claude),
           let action = RioMeetingPhrases.parse(raw: claude, simplified: RioText.simplify(claude)) {
            return [action]
        }
        // "Claude run the tests", "cloud code status", "ask Claude how do I ...".
        if let action = Self.claudeAtStart(body) { return [action] }
        if Self.splitClauses(body).count > 1,
           let action = RioAutomationPhrases.parse(raw: body, simplified: simple) {
            return [action]
        }
        return nil
    }

    /// Whisper hears "Claude" as "cloud" ("tell cloud to run the tests").
    /// "tell the cloud to push the branch", "ask clawed what it's doing".
    static func normalizingClaude(_ text: String) -> String {
        RioText.replacing(
            #"^((?:please\s+)?(?:tell|ask))\s+(?:the\s+(?:claude|cloud|clod|claud|clawed|cloude)|cloud|clod|claud|clawed|cloude)\b"#,
            with: "$1 Claude", in: text
        )
    }

    /// A trailing "never mind" / "forget it" after a command cancels the whole utterance. In a
    /// message body it needs a correction word too ("text Ali saying hi, actually never mind").
    static func cancelsItself(_ body: String) -> Bool {
        let cancel = #"(?:never\s?mind|forget\s+(?:it|that|about\s+it)|scratch\s+that|cancel\s+that)[\s.!]*$"#
        let marked = "\\S[\\s,.;!?]*\\b(?:actually|wait|no|oh|sorry)[\\s,.!]+\(cancel)"
        if startsGreedyCommand(body) { return RioText.matches("[,.;!?]\\s*(?:actually|wait|no|oh|sorry)[\\s,.!]+\(cancel)", body) }
        return RioText.matches(marked, body) || RioText.matches("\\S\\s*[,.;!?]+\\s*\(cancel)", body)
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

    private func parseClause(_ raw: String, state: ClauseState) -> ParsedClause? {
        if let app = state.lastApp, let pronoun = Self.pronounAppVerb(raw, app: app) { return pronoun }
        if let bigger = Self.makeItBigger(raw, app: state.lastApp) { return bigger }
        // "search the codebase for useAuth" is the editor's search: the resolver plans it.
        if Self.isCodeScopeSearch(raw) { return nil }
        // "search for cats and open the first result": a pick from results that haven't loaded yet
        // is the brain's job. On its own, "open the first one" clicks what is on screen.
        if !state.actions.isEmpty, RioText.matches(Self.resultPick, RioText.simplify(raw)) { return nil }
        if let direct = parseDirect(raw) { return direct }
        let rest = RioText.simplify(raw)
        guard let verb = state.inheritedVerb else {
            // "open Chrome, new tab, github.com": a bare site after something was opened, or a
            // spoken domain on its own, is opened too.
            guard state.hasOpened || RioText.matches(#"\.|\sdot\s"#, raw),
                  let site = parseInherited(verb: "open", rest: rest), case .openURL = site.action else { return nil }
            return site
        }
        return parseInherited(verb: verb, rest: rest)
    }

    /// "open Chrome and then quit it": "it" is the app a previous clause named.
    private static func pronounAppVerb(_ raw: String, app: String) -> ParsedClause? {
        guard let groups = RioText.firstMatch(#"^(quit|close|kill|exit|hide|force\s+quit)\s+(?:it|that|this|that\s+app|this\s+app)(?:\s+(?:too|again|now))?$"#, in: RioText.simplify(raw)),
              let verb = groups[1]?.lowercased() else { return nil }
        return ParsedClause(action: verb == "hide" ? .hideApp(name: app) : .quitApp(name: app), verb: verb)
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
        if isRecordingMacro, Self.isBareMacroStop(s) { return ParsedClause(action: .stopRecordingMacro, verb: nil) }
        if Self.isStopListening(s, wholeSentence: false) { return ParsedClause(action: .stopListening, verb: nil) }
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
        // "search youtube for lofi and play the first one": a pick from the results, not a song.
        if RioText.matches(Self.resultPick, s), s.hasPrefix("play") { return nil }
        if let action = RioExtraPhrases.parse(raw: raw, simplified: s) {
            if case .pressKeys = action { return ParsedClause(action: action, verb: "press") }
            // "open canvas and chrome": the next clause can borrow "open".
            if Self.opensSomething(action), RioText.matches(#"^(?:open(?:\s+up)?|launch)\b"#, s) {
                return ParsedClause(action: action, verb: "open")
            }
            return ParsedClause(action: action, verb: nil)
        }
        if let window = parseWindow(s, inherited: false) { return window }
        return parseAppVerb(s, inherited: false)
    }

    static let resultPick = #"^(?:play|open|click)\s+(?:the\s+)?(?:first|second|third|top|last|next)\s+(?:one|result|video|link|song|hit)$"#

    private static func opensSomething(_ action: RioAction) -> Bool {
        switch action {
        case .openURL, .openApp, .openFile: return true
        default: return false
        }
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
            actions = [.typeText(spokenSymbols(typed)), .pressKeys(combo)]
        } else {
            actions = [.typeText(spokenSymbols(text))]
        }
        return actions
    }

    private static let cliWords: Set<String> = [
        "cd", "ls", "git", "npm", "npx", "yarn", "pnpm", "bun", "brew", "cat", "mkdir", "rm", "rmdir", "mv", "cp",
        "touch", "echo", "grep", "python", "python3", "pip", "pip3", "node", "make", "swift", "swiftc", "sudo", "ssh",
        "curl", "wget", "vim", "nvim", "nano", "chmod", "chown", "docker", "kubectl", "cargo", "pwd", "less", "head",
        "tail", "tar", "unzip", "xcodebuild", "gh", "deno", "uv", "pytest", "export", "source",
    ]
    private static let symbolWords: [String: String] = ["tilde": "~", "slash": "/", "dash": "-", "dot": ".", "underscore": "_"]

    /// "type cd tilde slash hala" types "cd ~/hala"; "type omar at example dot com" types the
    /// address. Only a shell command (a CLI first word, or two or more symbol words) or an email
    /// is converted: "type the dash is broken" stays as said.
    static func spokenSymbols(_ text: String) -> String {
        let email = #"\b([A-Za-z0-9]+(?:\s+(?:dot|underscore)\s+[A-Za-z0-9]+)*)\s+at\s+([A-Za-z0-9-]+(?:\s+dot\s+[A-Za-z0-9-]+)*\s+dot\s+(?:com|org|net|edu|io|co|ai|dev|me|us|uk|ae|qa|app))\b"#
        var result = text
        if let regex = try? NSRegularExpression(pattern: email, options: [.caseInsensitive]) {
            let range = NSRange(result.startIndex..., in: result)
            for match in regex.matches(in: result, range: range).reversed() {
                guard let whole = Range(match.range, in: result), let user = Range(match.range(at: 1), in: result),
                      let host = Range(match.range(at: 2), in: result) else { continue }
                let address = joinSymbols(String(result[user])) + "@" + joinSymbols(String(result[host]))
                result.replaceSubrange(whole, with: address.lowercased())
            }
        }
        let words = result.split(separator: " ").map(String.init)
        guard let first = words.first?.lowercased() else { return result }
        let symbolCount = words.filter { symbolWords[$0.lowercased()] != nil }.count
        guard symbolCount > 0, cliWords.contains(first) || symbolCount >= 2 else { return result }
        return joinSymbols(result, keepFirstApart: true)
    }

    /// Joins spoken symbols to their neighbours: "feature slash login" -> "feature/login",
    /// "ls dash la" -> "ls -la", "cd dot dot" -> "cd ..".
    private static func joinSymbols(_ text: String, keepFirstApart: Bool = false) -> String {
        var output = ""
        var gluesNext = false
        for (index, word) in text.split(separator: " ").map(String.init).enumerated() {
            let symbol = symbolWords[word.lowercased()]
            let token = symbol ?? word
            let gluesBack = symbol.map { ["/", ".", "_"].contains($0) } ?? false
            let afterCommand = keepFirstApart && index == 1
            if !output.isEmpty, !gluesNext, !(gluesBack && !afterCommand) { output += " " }
            output += token
            gluesNext = symbol != nil
        }
        return output
    }

    // MARK: Stop listening

    /// Structural: Rio himself is told to stop listening, rest, go, go quiet or switch off, or
    /// is told goodbye ("stop listening", "go to sleep", "take a break", "turn yourself off",
    /// "you can go now", "good night"), with any thanks or name after. "that's it", "I'm done",
    /// a bare "sleep" or "off" only count as the whole sentence, so "open Chrome and that's it"
    /// never ends the conversation by accident. The meeting's mic ("mic off", "mute the mic") is
    /// not Rio's: those go on to the other paths (finding 64, 97b).
    static func isStopListening(_ s: String, wholeSentence: Bool) -> Bool {
        let lead = #"^(?:(?:ok|okay|alright|all right|so|thanks|thank you|cool|great|perfect)\s+)*"#
        let yourself = #"(?:yourself|urself)"#
        let listen = #"stop listening(?: to me)?|quit listening|stop (?:the )?conversation(?: mode)?|end (?:the )?conversation(?: mode)?|conversation mode off|turn off conversation mode|thats all(?: for now)?|that is all(?: for now)?|thatll be all|that will be all"#
        let rest = #"go (?:to )?sleep|go (?:rest|quiet|offline|away)|(?:take|have) a (?:break|rest|nap|breather)|take (?:five|ten)|quiet mode|sleep mode|leave me alone|(?:you can|you may) (?:go|leave|rest|sleep|stop listening)(?: now)?"#
        let off = "(?:turn|switch|shut|power) \(yourself) (?:off|down)|(?:turn|switch|shut|power) (?:off|down) \(yourself)|mute \(yourself)|(?:turn|switch|shut) off your (?:mic|microphone|ears)|(?:turn|switch|shut) your (?:mic|microphone|ears) off"
        let goodbye = #"good ?bye|bye(?: bye)?|good ?night|night night"#
        let whole = #"|thats it|that is it|(?:were|we are|im|i am) done(?: here)?|sleep|rest|off|leave|see (?:you|ya)(?: later)?|take care"#
        let tail = "(?:\\s+(?:\(nameVariants)|thanks|thank you|now|for now|here|for (?:a )?(?:bit|while|minute|second|sec)|buddy|bro|man))*$"
        let phrases = [listen, rest, off, goodbye].joined(separator: "|")
        return RioText.matches(lead + "(?:" + phrases + (wholeSentence ? whole : "") + ")" + tail, s)
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
        // "search that on Amazon", "look it up": the last search or the selection, never the word.
        if Self.isPronounSearch(text) { return nil }

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
        if let local = Self.localScopeSearch(text) { return local }
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
        if RioText.matches(#"^(?:for|up|the web|google|youtube)$"#, query) || isPronounQuery(query) { return nil }
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
            // "so yeah Rio open Chrome": only before the name or a command.
            "^(?:yeah|yep|yea|yup)\\b[\\s,.!?]*(?=(?:\(nameVariants)|\(leadVerbs))\\b)",
            #"^(?:can|could|would|will)\s+you\s*,?\s+(?:please\s*,?\s+)?"#,
            #"^(?:i\s+(?:want|need)\s+you\s+to|i\s*(?:'|\x{2019})?d\s+like\s+you\s+to|go\s+ahead\s+and|just)\s+"#,
            // "do this, open Chrome", "do me a favor and open Chrome": only when a command follows,
            // so a bare "do this" still reaches the resolver whole (finding 20a).
            "^do\\s+(?:this|the\\s+following|me\\s+a\\s+(?:favou?r|solid))(?:\\s+for\\s+me)?(?:\\s*[,.:;!?-]+\\s*(?:and\\s+)?|\\s+and\\s+)(?=(?:\(leadVerbs)|reply|respond|answer|snap)\\b)",
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
        let thanks = "[\\s,.!?;:]+(?:thanks|thank you)(?:\\s+(?:\(nameVariants)))?\\s*[.!?]*$"
        let pattern = #"(?:[\s,.!?;:]+(?:please|bro|bruh|dude|buddy|thanks|thank you|for me|real quick|quickly|right now)|(?<!\bfrom)(?<!\bright)[\s,.!?;:]+now|\s*,\s*man)\s*[.!?]*$"#
        let arabic = "[\\s,.!?;:]+(?:\(arabicFillers))\\s*[.!?]*$"
        let stripsArabic = RioText.matches(trailingArabicCommand, text)
        while true {
            let withoutThanks = RioText.replacing(thanks, with: "", in: result)
            // "say thanks", "tell Ahmed thank you": the thanks is the message.
            if withoutThanks != result, isBareMessageVerb(withoutThanks) { break }
            var next = RioText.replacing(pattern, with: "", in: withoutThanks)
            if stripsArabic { next = RioText.replacing(arabic, with: "", in: next) }
            if next == result { break }
            result = next
        }
        // A bare filler word is the whole clause.
        if RioText.matches(#"^(?:please|bro|bruh|dude|man|buddy|thanks|thank you|now)[\s.!?,]*$"#, result) { return "" }
        // "Thanks Rio." or a lone "Rio" left between two commands.
        if RioText.matches("^(?:(?:thanks|thank you|cheers)[\\s,]+)?(?:\(nameVariants))[\\s.!?,]*$", result)
            || RioText.matches("^(?:thanks|thank you|cheers)[\\s.!?,]*$", result) { return "" }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " ,.!;:\n\t"))
    }

    // MARK: Clause splitting

    // Message bodies keep "and" and trailing words too: "text Ali saying I'm late and I'll call".
    private static let greedyStart = #"^(?:type|write|search|google|look\s+up|youtube\s+search|you\s?tube\s+search|amazon\s+search|reply|respond|say|tell\s+(?!(?:me|us|the|claude|cloud|clod|claud|clawed|cloude)\b)\S+|text|message|send\s+(?:a\s+)?(?:text|message))\b"#
    private static let searchStart = #"^(?:search|google|look\s+up|youtube\s+search|you\s?tube\s+search|amazon\s+search)\b"#
    static var searchStartPattern: String { searchStart }
    private static let messageStart = #"^(?:reply|tell\s+(?:them|him|her)|text|message|send\s+(?:a\s+)?(?:text|message))\b"#
    /// The verbs that start a new command after "and then" inside a search or a message body.
    private static let chainVerbs = #"(?:open|launch|quit|close|switch|play|pause|put|move|snap|search|google|mute|unmute|hide|lock|take|set|turn|remind|reply|click|press|hit|type|text|message|send|email|maximi[sz]e|minimi[sz]e|go\s+to|show\s+me|start|stop|find|look\s+up)\b"#

    static func startsGreedyCommand(_ clause: String) -> Bool {
        RioText.matches(greedyStart, clause)
    }

    struct ClausePart: Equatable {
        var text: String
        /// "open Chrome, I mean Safari": this clause replaces the one before it.
        var isCorrection = false
    }

    private enum Separator: Equatable {
        case start
        /// ", Rio," / ". Rio" between two commands.
        case punctuatedName
        /// "open chrome Rio quit xcode": the name right before a command verb.
        case bareName
        /// "wait no", "I mean", "actually".
        case correction
        /// "and then", "then", "and also", "after that".
        case chain
        /// "and", "plus", ",", ";", "&", a spoken "comma".
        case soft
        /// A sentence end: "Open Chrome. Quit Xcode."
        case sentence
    }

    private static let separatorPattern: String = {
        let name = "(?:\(nameVariants))"
        let groups = [
            "\\s*[,.;!?]+\\s*(?:and\\s+)?\(name)\\b[\\s,.;!?:]*(?=\\p{L})",
            "\\s+(?:and\\s+)?\(name)\\b[\\s,.;!?:]*(?=(?:\(leadVerbs))\\b)",
            // A bare "actually" or "sorry" only after a pause ("remind me to actually study" stays).
            #"\s*[,.;!?]*\s*\b(?:wait\s*[,.]?\s*no|no\s*[,.]?\s*wait|(?:no|sorry|oops)\s*[,.]?\s*i\s+mean|i\s+mean)\b[\s,.;!?:]*|\s*[,.;!?]+\s*(?:no\s*[,.]?\s*)?(?:actually|sorry)\b[\s,.;!?:]*"#,
            #"\s*,?\s*\b(?:and\s+then|and\s+also|after\s+that|then|also)\b\s*"#,
            #"\s*,?\s*\b(?:and|plus)\b\s*|\s*[,;]\s*|\s+&\s+|\s+comma\s+"#,
            // Not after a lone letter ("9 a.m. tomorrow", "U.S.") or a title ("Dr. Kim").
            #"(?<![\s.]\p{L})(?<!^\p{L})(?<!\b(?:mr|mrs|ms|dr|st|vs|etc|jr|sr|prof))(?:\.+|[!?]+)\s+(?=\p{L})"#,
        ]
        return groups.map { "(\($0))" }.joined(separator: "|")
    }()

    private static let separatorKinds: [Separator] = [.punctuatedName, .bareName, .correction, .chain, .soft, .sentence]

    /// Splits on "and", "then", "plus", commas, semicolons, sentence ends and a second "Rio".
    /// Once a type/search/message clause starts it keeps the rest of the sentence, so "search
    /// for cats and dogs" stays one query, until "and then" (or a new "Rio") starts a command.
    static func splitClauses(_ text: String) -> [String] {
        splitClauseParts(text).map(\.text)
    }

    static func splitClauseParts(_ text: String) -> [ClausePart] {
        guard let regex = try? NSRegularExpression(pattern: separatorPattern, options: [.caseInsensitive]) else {
            return [ClausePart(text: text)]
        }
        let full = NSRange(text.startIndex..., in: text)
        var pieces: [(text: String, separator: String, kind: Separator)] = []
        var cursor = text.startIndex
        var pendingSeparator = ""
        var pendingKind = Separator.start
        for match in regex.matches(in: text, options: [], range: full) {
            guard let range = Range(match.range, in: text) else { continue }
            pieces.append((String(text[cursor..<range.lowerBound]), pendingSeparator, pendingKind))
            pendingSeparator = String(text[range])
            pendingKind = (1...separatorKinds.count).first { match.range(at: $0).location != NSNotFound }
                .map { separatorKinds[$0 - 1] } ?? .soft
            cursor = range.upperBound
        }
        pieces.append((String(text[cursor...]), pendingSeparator, pendingKind))

        let edge = CharacterSet(charactersIn: " ,;:.!")
        var parts: [ClausePart] = []
        var index = 0
        while index < pieces.count {
            let piece = pieces[index].text.trimmingCharacters(in: edge)
            if startsGreedyCommand(piece) {
                var merged = pieces[index].text
                var next = index + 1
                while next < pieces.count, !endsGreedy(piece, at: pieces[next]) {
                    merged += pieces[next].separator + pieces[next].text
                    next += 1
                }
                // "reply saying sounds good and send it": sending already waits for a confirm.
                if next < pieces.count, isMessage(piece), isSendIt(pieces[next].text) { next += 1 }
                parts.append(ClausePart(text: cleanedGreedy(merged)))
                index = next
                continue
            }
            if !piece.isEmpty {
                // "and actually maximize it": a correction word right after another separator is not one.
                let previousText = index > 0 ? pieces[index - 1].text.trimmingCharacters(in: edge) : ""
                let corrects = pieces[index].kind == .correction && !previousText.isEmpty && !parts.isEmpty
                parts.append(ClausePart(text: piece, isCorrection: corrects))
            }
            index += 1
        }
        return parts
    }

    /// Where a greedy clause stops: a new "Rio" + command, "and then" + command, and (in a
    /// search only) a plain "and" + command ("search for cats and open the first result").
    private static func endsGreedy(_ greedy: String, at piece: (text: String, separator: String, kind: Separator)) -> Bool {
        let next = piece.text.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.!"))
        let startsCommand = RioText.matches("^" + chainVerbs, next)
        switch piece.kind {
        case .punctuatedName: return RioText.matches("^(?:\(leadVerbs))\\b", next)
        case .chain: return startsCommand || (isMessage(greedy) && isSendIt(next))
        case .soft:
            if isMessage(greedy), isSendIt(next), !piece.separator.contains("comma") { return true }
            return RioText.matches(searchStart, greedy) && startsCommand
                && RioText.matches(#"^\s*,?\s*(?:and\b|,)"#, piece.separator)
        default: return false
        }
    }

    private static func isMessage(_ clause: String) -> Bool { RioText.matches(messageStart, clause) }

    private static func isSendIt(_ text: String) -> Bool {
        RioText.matches(#"^\s*send(?:\s+it)?(?:\s+(?:now|please))?[\s.!]*$"#, text)
    }

    /// "reply saying that I'll be there at 3": the "that" only introduces the words.
    private static func cleanedGreedy(_ merged: String) -> String {
        var text = merged.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:\n\t"))
        if isMessage(text) {
            text = RioText.replacing(#"\b(saying|say|says)\s+that\s+(?=(?:i|we|you|he|she|they)\b)"#, with: "$1 ", in: text)
        }
        return text
    }
}
