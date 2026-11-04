import Foundation

// Follow-ups and pronouns (#34): "open it again", "close that", "make it bigger", "do the same
// for Spotify", "send that to Ali too". Pure, Foundation only. The coordinator records what ran;
// the phrase parser rewrites a pronoun phrase into a closed `RioAction` over that context.
// Nothing here is persisted or logged: it lives in memory for a few minutes.

/// What Rio can see of the Mac right now, for pronouns that would quit or hide something.
struct RioFollowUpEnvironment: Equatable {
    /// The frontmost app's display name.
    let frontApp: String?
}

/// What the last commands were about.
struct RioFollowUpContext: Equatable {
    /// The most recent action that ran.
    var lastAction: RioAction?
    /// The app the last app-bearing action (open, quit, switch, hide, window) named.
    var lastApp: String?
    /// When `lastAction` ran.
    var lastActionAt: Date?
    /// The Mac as it is now; nil when unknown (then "close it" never quits anything).
    var environment: RioFollowUpEnvironment?
    /// Set after a command Rio couldn't work out (no brain, or it failed): "send that to Ali"
    /// must not forward an older answer as if it were the reply to that command.
    var isSendableSuppressed = false

    /// Text "send that to Ali" can carry: the last message sent, or the last answer.
    var sendableBody: String? {
        guard !isSendableSuppressed else { return nil }
        switch lastAction {
        case .sendMessage(_, let body)?: return body
        case .answer(let text)?: return String(text.prefix(RioFollowUpMemory.maxAnswerLength))
        default: return nil
        }
    }
}

/// The in-memory record the coordinator writes after each action and the parser reads.
final class RioFollowUpMemory: @unchecked Sendable {
    static let shared = RioFollowUpMemory()
    /// A follow-up only makes sense soon after the command it points at.
    static let lifetime: TimeInterval = 15 * 60

    static let maxAnswerLength = 500

    private let lock = NSLock()
    private var context = RioFollowUpContext()
    private var recordedAt: Date?
    private var environmentProvider: (@Sendable () -> RioFollowUpEnvironment)?

    init() {}

    /// Where snapshots read the front app from (the executor installs the live one).
    func setEnvironmentProvider(_ provider: (@Sendable () -> RioFollowUpEnvironment)?) {
        lock.lock()
        defer { lock.unlock() }
        environmentProvider = provider
    }

    func record(_ action: RioAction, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        context.lastAction = action
        context.lastActionAt = now
        context.isSendableSuppressed = false
        if let app = Self.appName(in: action) { context.lastApp = app }
        recordedAt = now
    }

    /// The command that just ran produced nothing Rio stands behind (an error line, a failed
    /// plan): nothing from before it may be forwarded as "that".
    func noteUnresolved() {
        lock.lock()
        defer { lock.unlock() }
        context.isSendableSuppressed = true
    }

    /// The context, or nil once nothing has run for `lifetime` seconds.
    func snapshot(now: Date = Date()) -> RioFollowUpContext? {
        lock.lock()
        let provider = environmentProvider
        guard let recordedAt, context.lastAction != nil, now.timeIntervalSince(recordedAt) <= Self.lifetime else {
            lock.unlock()
            return nil
        }
        var result = context
        lock.unlock()
        // Outside the lock: the provider asks the system.
        result.environment = provider?()
        return result
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        context = RioFollowUpContext()
        recordedAt = nil
    }

    private static func appName(in action: RioAction) -> String? {
        switch action {
        case .openApp(let name), .quitApp(let name), .switchToApp(let name), .hideApp(let name): return name
        case .window(let command): return command.appName
        default: return nil
        }
    }
}

enum RioFollowUpRewriter {
    /// "Close it" may quit the app only this soon after Rio opened or moved it, and only while it
    /// is still in front: a stale referent quit the owner's Chrome, every tab gone (review K45).
    static let quitReferentLifetime: TimeInterval = 30

    /// The action a pronoun phrase stands for, or nil when it isn't one (or there is nothing for
    /// the pronoun to point at). `simplified` is `RioText.simplify` of what was said. "Again" is
    /// not here: the coordinator re-runs the whole previous command (`isRepeatRequest`).
    static func rewrite(_ simplified: String, context: RioFollowUpContext?, now: Date = Date()) -> RioAction? {
        guard let context, let last = context.lastAction else { return nil }
        let text = simplified.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return appVerb(text, context, now: now)
            ?? window(text, context)
            ?? sameSearchOnSite(text, last)
            ?? sameFor(text, last, strict: true)
            ?? send(text, context)
            ?? sameFor(text, last, strict: false)
    }

    /// For the coordinator: "do the same for Slack" after "open Chrome" becomes the words
    /// "open Slack", so the parser resolves the name exactly as if it had been said (the known-site
    /// fallback included) instead of a sure `openApp` of an app that may not exist.
    static func commandText(_ simplified: String, context: RioFollowUpContext?) -> String? {
        guard let last = context?.lastAction else { return nil }
        let text = simplified.trimmingCharacters(in: .whitespaces)
        let verb: String
        switch last {
        // A site opened by name ("open Slack" became app.slack.com) is still "open".
        case .openApp, .openURL: verb = "open"
        case .switchToApp: verb = "switch to"
        case .quitApp: verb = "quit"
        case .hideApp: verb = "hide"
        default: return nil
        }
        guard let target = sameForTarget(text, strict: true) ?? sameForTarget(text, strict: false) else { return nil }
        return "\(verb) \(target)"
    }

    /// "Do the same for Slack" (or "send that to WhatsApp") after a text: Rio only texts over
    /// iMessage, so he says so here instead of handing it to the brain, and the body never goes
    /// to the model. Nil for anything else (iMessage itself and contacts included).
    static func messagingAppReply(_ simplified: String, context: RioFollowUpContext?) -> String? {
        guard case .sendMessage? = context?.lastAction else { return nil }
        let text = simplified.trimmingCharacters(in: .whitespaces)
        let sendPattern = #"^(?:also\s+)?(?:send|forward|text|message|share|post)\s+(?:it|that|this|the\s+same(?:\s+message|\s+thing)?)\s+(?:to|on|in)\s+(.+)$"#
        guard let target = sameForTarget(text, strict: true) ?? sameForTarget(text, strict: false)
            ?? RioText.firstMatch(sendPattern, in: text)?[1].flatMap(cleanTarget) else { return nil }
        guard let app = otherMessagingAppNames[messagingAppKey(target)] else { return nil }
        return "I can only text over iMessage. I can open \(app) for you."
    }

    /// Messaging apps other than iMessage, by their spoken name.
    private static let otherMessagingAppNames: [String: String] = [
        "slack": "Slack", "whatsapp": "WhatsApp", "whats app": "WhatsApp", "telegram": "Telegram", "discord": "Discord",
        "signal": "Signal", "teams": "Microsoft Teams", "microsoft teams": "Microsoft Teams", "messenger": "Messenger",
        "mail": "Mail", "email": "Mail", "gmail": "Gmail", "outlook": "Outlook",
    ]

    private static func messagingAppKey(_ target: String) -> String {
        target.lowercased().replacingOccurrences(of: #"^(?:on|in|via|through)\s+"#, with: "", options: .regularExpression)
    }

    /// "Again", "try that again", "do it one more time", "repeat the last command".
    static func isRepeatRequest(_ simplified: String) -> Bool {
        let text = simplified.trimmingCharacters(in: .whitespaces)
        let again = #"^(?:(?:do|run|try|say|repeat|redo)\s+)?(?:(?:it|that|this|the\s+same(?:\s+thing)?|same)\s*)?(?:again|one\s+more\s+time|once\s+more)(?:\s+please)?$"#
        let redo = #"^(?:repeat|redo)\s+(?:it|that|this|the\s+last\s+(?:one|command))$"#
        return RioText.matches(again, text) || RioText.matches(redo, text)
    }

    /// Never repeated by "again": undo (it would reach further back), typing and turning the
    /// mic off.
    static func isRepeatable(_ actions: [RioAction]) -> Bool {
        !actions.contains { action in
            switch action {
            case .undoLast, .typeText, .stopListening: return true
            // Each Claude Code send or approval is decided on its own, never replayed.
            case .claudeCode(.send), .claudeCode(.approve): return true
            default: return false
            }
        }
    }

    private static let notATarget: Set<String> = [
        "it", "that", "this", "them", "him", "her", "me", "us", "you", "now", "today", "later", "again", "tomorrow", "too", "one",
    ]

    // MARK: Open / close it

    private static let closeWindowCombo = KeyCombo(key: "w", command: true, shift: false, option: false, control: false)

    private static func appVerb(_ text: String, _ context: RioFollowUpContext, now: Date) -> RioAction? {
        let pattern = #"^(open|launch|start|reopen|bring up|close|quit|exit|hide|switch to|go back to|go to)\s+(it|that|this|that one|this one|that app|the app|the same app)(?:\s+again)?(?:\s+please)?$"#
        guard let groups = RioText.firstMatch(pattern, in: text), let verb = groups[1]?.lowercased() else { return nil }
        let pronoun = groups[2]?.lowercased() ?? ""
        switch verb {
        case "open", "launch", "start", "reopen", "bring up":
            return context.lastApp.map { .openApp(name: $0) }
        case "close", "quit", "exit", "hide":
            if let app = freshFrontApp(context, now: now) {
                return verb == "hide" ? .hideApp(name: app) : .quitApp(name: app)
            }
            // "Close this" with nothing fresh to point at closes the front window or tab.
            if verb == "close", ["it", "that", "this", "that one", "this one"].contains(pronoun) {
                return .pressKeys(closeWindowCombo)
            }
            return nil
        default:
            return context.lastApp.map { .switchToApp(name: $0) }
        }
    }

    /// The app "close it" may quit: the last action put it in front a moment ago, and it still is.
    private static func freshFrontApp(_ context: RioFollowUpContext, now: Date) -> String? {
        guard let app = context.lastApp, let last = context.lastAction, let at = context.lastActionAt,
              now.timeIntervalSince(at) <= quitReferentLifetime,
              let front = context.environment?.frontApp else { return nil }
        switch last {
        case .openApp, .switchToApp: break
        case .window(let command) where command.appName != nil: break
        default: return nil
        }
        return WindowAppNameResolver.bestMatchIndex(for: app, in: [front]) != nil ? app : nil
    }

    // MARK: Make it bigger

    /// Only the phrasing the window parser doesn't already own ("put it on the left" and "move it to
    /// the next screen" keep acting on the front window, as before).
    private static func window(_ text: String, _ context: RioFollowUpContext) -> RioAction? {
        guard RioText.matches(#"^make\s+(?:it|that|this)\s+(?:bigger|larger|full\s?screen|maximi[sz]ed)$"#, text) else { return nil }
        let hasWindow: Bool
        if case .window? = context.lastAction { hasWindow = true } else { hasWindow = false }
        guard context.lastApp != nil || hasWindow else { return nil }
        return .window(WindowCommand(appName: context.lastApp, placement: .maximize))
    }

    // MARK: Do the same for X

    private static let strictSamePatterns = [
        #"^(?:(?:do|run|repeat)\s+)?(?:the\s+)?same(?:\s+thing)?\s+(?:for|with|on|to)\s+(.+)$"#,
        #"^(?:do|run|repeat)\s+(?:that|it|this)\s+(?:for|with|on|to)\s+(.+)$"#,
    ]
    /// "And now Warp", "and Warp too": only a short name, never a new command.
    private static let looseSamePatterns = [
        #"^and\s+now\s+(.+?)(?:\s+(?:too|as\s+well))?$"#,
        #"^and\s+(.+?)\s+(?:too|as\s+well)$"#,
    ]
    private static let commandWords: Set<String> = [
        "open", "close", "quit", "send", "text", "message", "play", "set", "start", "stop", "make", "put", "move", "do",
        "turn", "search", "call", "show", "hide", "switch", "go", "take", "tell", "write", "type", "read", "remind", "add",
        "find", "the", "a", "an", "my", "i", "is", "it", "that", "this", "what", "how", "can", "please", "thank", "thanks",
        "love", "nice", "good", "great", "okay", "ok", "yes", "no", "same", "and", "volume", "mute", "unmute", "pause",
        "skip", "next", "lock", "screenshot", "brightness", "wifi", "bluetooth", "dark", "timer", "undo", "minimize",
        "maximize", "new", "scroll", "press", "click", "fill", "remember", "forget",
    ]

    private static func sameForTarget(_ text: String, strict: Bool) -> String? {
        for pattern in strict ? strictSamePatterns : looseSamePatterns {
            guard let raw = RioText.firstMatch(pattern, in: text)?[1], let target = cleanTarget(raw) else { continue }
            if !strict {
                let words = target.split(separator: " ")
                guard words.count <= 3, let first = words.first, !commandWords.contains(first.lowercased()) else { continue }
            }
            return target
        }
        return nil
    }

    /// "Do the same on YouTube" after "search for cats": the same query on that site. Only a site
    /// after "on" or "in" keeps the query; "do the same for dogs" still replaces it.
    private static func sameSearchOnSite(_ text: String, _ last: RioAction) -> RioAction? {
        guard case .webSearch(let query) = last else { return nil }
        let patterns = [
            #"^(?:(?:do|run|repeat)\s+)?(?:the\s+)?same(?:\s+thing)?\s+(?:on|in)\s+(.+)$"#,
            #"^(?:do|run|repeat|search)\s+(?:that|it|this)\s+(?:on|in)\s+(.+)$"#,
        ]
        for pattern in patterns {
            guard let raw = RioText.firstMatch(pattern, in: text)?[1], let site = cleanTarget(raw) else { continue }
            return siteSearch(query: query, site: site)
        }
        return nil
    }

    private static func siteSearch(query: String, site: String) -> RioAction? {
        var compact = RioText.compact(site)
        if compact.hasSuffix("com"), compact.count > 3 { compact = String(compact.dropLast(3)) }
        let builders: [String: (String) -> URL?] = [
            "youtube": RioWebURLs.youtubeSearchURL(query:), "amazon": RioWebURLs.amazonSearchURL(query:),
            "github": RioWebURLs.githubSearchURL(query:), "stackoverflow": RioWebURLs.stackOverflowSearchURL(query:),
            "netflix": RioWebURLs.netflixSearchURL(query:),
        ]
        if let build = builders[compact] { return build(query).map(RioAction.openURL) }
        if compact == "google" { return .webSearch(query: query) }
        guard let host = RioWebURLs.knownSite(compactName: compact)?.host else { return nil }
        return .webSearch(query: "\(query) site:\(RioWebHostRules.bareHost(host))")
    }

    private static func sameFor(_ text: String, _ last: RioAction, strict: Bool) -> RioAction? {
        guard let target = sameForTarget(text, strict: strict) else { return nil }
        return substitute(target, into: last)
    }

    /// Apps that carry messages: "do the same for Slack" after a text means post it there, not a
    /// contact called Slack, so it goes to the brain instead.
    private static let messagingApps: Set<String> = [
        "slack", "whatsapp", "whats app", "telegram", "discord", "messages", "imessage", "signal", "teams",
        "microsoft teams", "messenger", "mail", "email", "gmail", "outlook",
    ]

    private static func substitute(_ target: String, into last: RioAction) -> RioAction? {
        switch last {
        case .openApp: return .openApp(name: target)
        case .quitApp: return .quitApp(name: target)
        case .switchToApp: return .switchToApp(name: target)
        case .hideApp: return .hideApp(name: target)
        case .window(let command): return .window(WindowCommand(appName: target, placement: command.placement))
        case .webSearch: return .webSearch(query: target)
        case .openFile: return .openFile(query: target)
        case .revealFile: return .revealFile(query: target)
        case .sendMessage(_, let body):
            let name = target.lowercased().replacingOccurrences(of: #"^(?:on|in|via|through)\s+"#, with: "", options: .regularExpression)
            return messagingApps.contains(name) ? nil : .sendMessage(to: target, body: body)
        case .weather: return .weather(place: target)
        default: return nil
        }
    }

    // MARK: Send that to Ali

    private static func send(_ text: String, _ context: RioFollowUpContext) -> RioAction? {
        let pattern = #"^(?:also\s+)?(?:send|forward|text|message|share)\s+(?:it|that|this|the\s+same(?:\s+message|\s+thing)?)\s+to\s+(.+)$"#
        guard let raw = RioText.firstMatch(pattern, in: text)?[1], let recipient = cleanTarget(raw),
              let body = context.sendableBody else { return nil }
        return .sendMessage(to: recipient, body: body)
    }

    // MARK: Shared

    /// A spoken name without trailing filler; nil for pronouns and empty or silly values.
    private static func cleanTarget(_ raw: String) -> String? {
        var words = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        let filler: Set<String> = ["too", "as", "well", "also", "please", "now"]
        while let tail = words.last, filler.contains(tail.lowercased()) { words.removeLast() }
        let name = words.joined(separator: " ")
        guard !name.isEmpty, name.count <= 40, !notATarget.contains(name.lowercased()) else { return nil }
        return name
    }
}
