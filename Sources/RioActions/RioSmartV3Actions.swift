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
            // Only maths the local calculator can really answer runs as calculate. A conversion it
            // can't do ("100 USD to QAR": currencies change, so there is no rate table) is looked
            // up instead of dropped. Other maths it can't do ("7 choose 3" beyond its reach) is
            // never a web search (round 3): the model's own worked answer is spoken when it gave
            // one, else the step is dropped and the resolver asks again.
            guard let expression = RioSmartResponseParser.text(object["expression"], max: maxQueryCharacters) else { return nil }
            if RioCalculator.evaluate(expression, now: now, timeZone: timeZone) != nil { return .calculate(expression: expression) }
            if isLookupWorthy(expression) { return .webSearch(query: expression) }
            return RioSmartResponseParser.answerText(object).map {
                RioAction.answer(RioSmartText.limitSentences($0, maxSentences: 2, maxCharacters: RioSmartText.maxAnswerCharacters))
            }
        case "startTranslation": return .startTranslation
        case "stopTranslation": return .stopTranslation
        case "speakLastTranslation": return .speakLastTranslation
        default: return RioSmartV45Actions.action(kind: kind, object: object, now: now, timeZone: timeZone)
        }
    }

    /// A calculation worth a web search when the calculator can't answer it: plain words with a
    /// number in them ("100 USD to QAR", "50 euros to dollars"), or a rate question. Nothing
    /// shell-like, and never a bare fragment like "2 +" or a command like "open Chrome".
    static func isLookupWorthy(_ expression: String) -> Bool {
        guard RioSmartResponseParser.name(expression, max: maxQueryCharacters) != nil else { return false }
        return RioText.matches(currencyOrRate, expression)
    }

    /// Money and rates: they change, so they are looked up. Plain maths never is (round 3).
    private static let currencyOrRate =
        #"\b(?:usd|qar|eur|gbp|aed|sar|kwd|bhd|omr|jpy|cny|inr|pkr|egp|cad|aud|chf|mxn|dollars?|bucks|euros?|riyals?|rials?|dirhams?|pounds?\s+sterling|sterling|rupees?|yen|yuan|lira|liras|dinars?|francs?|pesos?|bitcoins?|btc|ethereum|eth|crypto|exchange\s+rate|rate\s+of|stocks?|shares?|price|prices|gold|silver|oil)\b|\bin\s+pounds\b|[$\u20AC\u00A3]"#

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

/// Deterministic checks on a validated plan against the owner's own words, for mistakes a model
/// makes that look right on the confirm panel. Pure.
enum RioSmartPlanGuards {
    static let micAnswer = "I can't control your mic, camera or screen sharing yet, so use the meeting's own button."
    static let cutAnswer = "I did the first six things you asked. Say the rest again?"
    static let clippedAnswer = "That was a long one, so I may have missed something in the middle."

    static func otherAppAnswer(_ app: String) -> String {
        "I can only send texts over iMessage, so I opened \(app)."
    }

    /// Chat apps Rio cannot send through (sendMessage is iMessage or SMS only), as spoken.
    private static let chatApps: [(pattern: String, name: String)] = [
        ("whats\\s?app", "WhatsApp"), ("slack", "Slack"), ("telegram", "Telegram"), ("discord", "Discord"),
        ("(?:microsoft\\s+)?teams", "Microsoft Teams"), ("signal", "Signal"),
    ]

    static func apply(_ actions: [RioAction], command: String) -> [RioAction] {
        guard !isTakenBack(command) else { return [] }
        var plan = messagingAppGuard(actions, command: command)
        plan = micGuard(plan, command: command)
        plan = openURLGuard(plan, command: command)
        plan = quitGuard(plan, command: command)
        plan = tabKeyGuard(plan, command: command)
        plan = commandTabGuard(plan)
        return plan
    }

    // MARK: Round 3 guards

    /// "quit Xcode, no, don't", "open Chrome... hold on", "empty the trash. No!": a take-back after a
    /// break cancels the command before it (finding 38b). Words after "saying" or ":" are a message.
    static func isTakenBack(_ command: String) -> Bool {
        let lowered = command.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        guard instructionPart(lowered) == lowered else { return false }
        let filler = #"(?:(?:oh|oops|um+|uh+|wait|actually|no|nah|nope|sorry)[\s,.!]+)*"#
        let takeBack = #"(?:no+|nope|nah|don'?t|do\s+not|hold\s+on|never\s?mind|stop|cancel(?:\s+(?:that|it))?|scratch\s+that|forget\s+(?:it|that)|wait|oops)"#
        return RioText.matches(#"\S.*?(?:[,.!?;:\u2026-]|\.\.\.)\s*"# + filler + takeBack + #"(?:\s+(?:that|it|rio))?[\s.!?]*$"#, lowered)
    }

    static let tabAnswer = "I can only jump to tabs 1 to 8 or the last one."

    /// Command-9 is the LAST tab, never "tab 9" or "tab 12": it stays only when the owner said last
    /// or final; for a tab number it becomes a plain answer (finding 43).
    static func tabKeyGuard(_ actions: [RioAction], command: String) -> [RioAction] {
        let nine = KeyCombo(key: "9", command: true, shift: false, option: false, control: false)
        guard actions.contains(.pressKeys(nine)), !RioText.matches(#"\b(?:last|final|rightmost|end)\b"#, command) else { return actions }
        let saysTab = RioText.matches(#"\btabs?\b"#, command)
        var answered = false
        return actions.compactMap { action in
            guard action == .pressKeys(nine) else { return action }
            guard saysTab, !answered else { return nil }
            answered = true
            return .answer(tabAnswer)
        }
    }

    /// Focus settling follows only switchToApp and openApp, so after a planned Command-Tab nothing
    /// that acts on the front app may follow: it would land in whatever app was there before,
    /// perhaps a terminal (finding 84).
    static func commandTabGuard(_ actions: [RioAction]) -> [RioAction] {
        let commandTab = KeyCombo(key: "tab", command: true, shift: false, option: false, control: false)
        guard let index = actions.firstIndex(of: .pressKeys(commandTab)) else { return actions }
        return Array(actions[...index]) + actions[(index + 1)...].filter { !RioSmartRouting.actsOnFrontApp($0) }
    }

    static let terminalQuitAnswer = "I won't quit a terminal you didn't name. To stop what's running, say \"press control c\"."

    /// quitApp or hideApp of an app the owner never named (finding 21): never a terminal (that ends
    /// every session in it) nor anything for "kill the dev server"; "close it" is Command-W.
    static func quitGuard(_ actions: [RioAction], command: String) -> [RioAction] {
        let closeWindow = KeyCombo(key: "w", command: true, shift: false, option: false, control: false)
        let aboutProcess = RioText.matches(#"\b(?:dev\s+server|server|process(?:es)?|script|localhost|port\s+\d+|npm|node|python|the\s+build)\b"#, command)
        let saysClose = RioText.matches(#"\b(?:close|shut)\b"#, command)
        var answered = false
        var result: [RioAction] = []
        for action in actions {
            let name: String
            switch action {
            case .quitApp(let app), .hideApp(let app): name = app
            default:
                result.append(action)
                continue
            }
            if namesApp(name, in: command) {
                result.append(action)
            } else if RioTaskSafety.isTerminal(appName: name) || aboutProcess {
                if !answered { result.append(.answer(terminalQuitAnswer)) }
                answered = true
            } else if case .quitApp = action, saysClose {
                result.append(.pressKeys(closeWindow))
            } else {
                result.append(action)
            }
        }
        return result
    }

    /// Whether the owner's words name `app` ("quit Warp", "close both chromes", "quit iterm").
    static func namesApp(_ app: String, in command: String) -> Bool {
        if !RioSmartContextPolicy.relevantApps([app], command: command).isEmpty { return true }
        let compactApp = RioText.compact(app).filter(\.isLetter)
        return compactApp.count >= 3 && RioText.compact(command).contains(compactApp)
    }

    /// A planned openURL is kept only for a site the owner named or a well-known site, and only
    /// with path, query and fragment words the owner said; anything else a hostile window title
    /// could have written is cut to the site's home page or dropped (finding 81).
    static func openURLGuard(_ actions: [RioAction], command: String) -> [RioAction] {
        actions.compactMap { action in
            guard case .openURL(let url) = action else { return action }
            return vettedURL(url, command: command).map(RioAction.openURL)
        }
    }

    static func vettedURL(_ url: URL, command: String) -> URL? {
        guard let host = url.host?.lowercased(), let scheme = url.scheme?.lowercased() else { return nil }
        let commandWords = Set(words(command))
        let site = registrableDomain(host)
        guard siteIsNamed(site, commandWords: commandWords, command: command) || isKnownSite(site) else { return nil }
        // One of Rio's own built-in addresses (Gmail's inbox link) carries nothing the model wrote.
        if RioWebURLs.isBuiltInSiteURL(url) { return url }
        // Security review: every host label beyond the site must be a word the owner said
        // ("docs" in "open google docs"); otherwise the link goes to the site itself, so a
        // hostile page can't hide data in a subdomain.
        let bare = RioWebHostRules.bareHost(host)
        let extra = bare == site ? [] : bare.dropLast(site.count + 1).split(separator: ".").map(String.init)
        let saidHost = extra.allSatisfy({ commandWords.contains($0) }) || namedKnownHosts(command).contains(bare)
        let www = host.hasPrefix("www.")
        let keptHost = saidHost ? host : (www ? "www." + site : site)
        // Path, query and fragment: every token (single letters too) must be a whole word the
        // owner said, or the link is cut to the home page.
        let rest = [url.path, url.query, url.fragment].compactMap { $0 }.joined(separator: " ")
        let restTokens = tokens(rest.removingPercentEncoding ?? rest)
        if saidHost, restTokens.allSatisfy({ commandWords.contains($0) }) { return url }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = keptHost
        origin.port = url.port
        origin.path = "/"
        if restTokens.allSatisfy({ commandWords.contains($0) }), let path = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            origin.path = path.path.isEmpty ? "/" : path.path
            origin.query = path.query
            origin.fragment = path.fragment
        }
        return origin.url
    }

    /// Lowercased runs of letters and digits, any length (so the owner's "r" in "r slash swift" counts).
    private static func words(_ text: String) -> [String] {
        tokens(text)
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Hosts of Rio's built-in sites the owner named by their spoken name ("gmail" -> mail.google.com).
    private static func namedKnownHosts(_ command: String) -> Set<String> {
        let spoken = tokens(command)
        var hosts = Set<String>()
        for start in spoken.indices {
            for end in start..<min(spoken.count, start + 3) {
                if let host = RioWebURLs.knownSite(compactName: spoken[start...end].joined())?.host {
                    hosts.insert(RioWebHostRules.bareHost(host))
                }
            }
        }
        return hosts
    }

    /// Words that are commands, not site names ("open" never names open.example).
    private static let commandVocabulary: Set<String> = [
        "open", "go", "goto", "show", "find", "search", "look", "new", "tab", "window", "page", "site", "website",
        "link", "my", "the", "me", "to", "on", "in", "up", "get", "play", "watch", "read", "start", "take", "bring",
        "launch", "visit", "check", "pull", "load", "a", "an", "and", "please", "rio",
    ]

    /// "mail.google.com" -> "google.com"; "bbc.co.uk" -> "bbc.co.uk".
    /// Shared hosting customers are separate sites (alice.github.io is not github.io).
    static func registrableDomain(_ host: String) -> String {
        RioWebHostRules.registrableDomain(RioWebHostRules.bareHost(host))
    }

    /// The owner said the site: its name ("vercel"), its domain, or a known site's spoken name
    /// ("twitter" for x.com).
    private static func siteIsNamed(_ site: String, commandWords: Set<String>, command: String) -> Bool {
        guard let name = site.split(separator: ".").first.map(String.init) else { return false }
        if !commandVocabulary.contains(name), commandWords.contains(name) { return true }
        if RioText.compact(command).contains(RioText.compact(site)) { return true }
        let spoken = command.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        for start in spoken.indices {
            for end in start..<min(spoken.count, start + 3) {
                let compact = spoken[start...end].joined()
                if let known = RioWebURLs.knownSite(compactName: compact)?.host, registrableDomain(known.lowercased()) == site { return true }
            }
        }
        return false
    }

    /// One of Rio's well-known sites (google.com, github.com, ...), by its main name.
    private static func isKnownSite(_ site: String) -> Bool {
        guard let name = site.split(separator: ".").first.map(String.init),
              let known = RioWebURLs.knownSite(compactName: name)?.host else { return false }
        return registrableDomain(known.lowercased()) == site
    }

    /// The command words, not the message: "text mom saying check WhatsApp" names no app.
    private static func instructionPart(_ command: String) -> String {
        let lowered = command.lowercased()
        guard let range = lowered.range(of: #"\b(?:saying|that says|to say|and say|telling (?:him|her|them)|:)"#, options: .regularExpression) else {
            return lowered
        }
        return String(lowered[..<range.lowerBound])
    }

    /// The chat app the owner asked to message through ("message Ali on WhatsApp", "slack Ahmed
    /// ...", "send Ahmed a slack"), or nil. Teams and Signal count only after on/over/via/in/a.
    static func namedChatApp(_ command: String) -> String? {
        let words = instructionPart(command)
        for app in chatApps {
            let loose = app.name == "Microsoft Teams" || app.name == "Signal"
            let pattern = loose
                ? #"\b(?:on|over|via|through|in|using|a|an)\s+"# + app.pattern + #"\b"#
                : #"\b"# + app.pattern + #"\b"#
            if RioText.matches(pattern, words) { return app.name }
        }
        return nil
    }

    /// A sendMessage the owner meant for WhatsApp, Slack and the like would go out over iMessage
    /// to whoever matches in Contacts: it becomes "switch to that app" plus a plain answer.
    static func messagingAppGuard(_ actions: [RioAction], command: String) -> [RioAction] {
        guard actions.contains(where: { if case .sendMessage = $0 { return true } else { return false } }),
              let app = namedChatApp(command) else { return actions }
        var result: [RioAction] = []
        var answered = false
        for action in actions {
            guard case .sendMessage = action else {
                result.append(action)
                continue
            }
            guard !answered else { continue }
            answered = true
            let switches = result.contains { step in
                switch step {
                case .switchToApp(let name), .openApp(let name): return name.lowercased() == app.lowercased()
                default: return false
                }
            }
            if !switches { result.append(.switchToApp(name: app)) }
            result.append(.answer(otherAppAnswer(app)))
        }
        return result
    }

    static func mentionsMicOrCamera(_ command: String) -> Bool {
        RioText.matches(
            #"\b(?:mic|mike|microphone|camera|webcam|my\s+video|screen\s?shar(?:e|ing)|share\s+(?:my|the)\s+screen|leave\s+the\s+(?:meeting|call)|(?:un)?mute\s+(?:me|myself))\b"#,
            command
        )
    }

    /// "mute my mic" planned as volume mute would mute the speakers while the owner thinks the
    /// call can't hear them: any volume step for a mic or camera request becomes a plain answer,
    /// unless the owner also asked about the volume or sound.
    static func micGuard(_ actions: [RioAction], command: String) -> [RioAction] {
        guard mentionsMicOrCamera(command),
              !RioText.matches(#"\b(?:volume|sound|speakers?|audio|louder|quieter)\b"#, command),
              actions.contains(where: { if case .volume = $0 { return true } else { return false } }) else { return actions }
        var result: [RioAction] = []
        var answered = false
        for action in actions {
            guard case .volume = action else {
                result.append(action)
                continue
            }
            if !answered { result.append(.answer(micAnswer)) }
            answered = true
        }
        return result
    }

    /// Says when the plan or the command was cut, so nothing is dropped silently.
    static func notices(planWasCut: Bool, commandWasClipped: Bool) -> [RioAction] {
        var notes: [RioAction] = []
        if planWasCut { notes.append(.answer(cutAnswer)) }
        if commandWasClipped { notes.append(.answer(clippedAnswer)) }
        return notes
    }
}
