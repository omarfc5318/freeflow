import Foundation

// Follow-ups and pronouns (#34): "open it again", "close that", "make it bigger", "do the same
// for Spotify", "send that to Ali too". Pure, Foundation only. The coordinator records what ran;
// the phrase parser rewrites a pronoun phrase into a closed `RioAction` over that context.
// Nothing here is persisted or logged: it lives in memory for a few minutes.

/// What the last commands were about.
struct RioFollowUpContext: Equatable {
    /// The most recent action that ran.
    var lastAction: RioAction?
    /// The app the last app-bearing action (open, quit, switch, hide, window) named.
    var lastApp: String?

    /// Text "send that to Ali" can carry: the last message sent, or the last answer.
    var sendableBody: String? {
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

    init() {}

    func record(_ action: RioAction, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        context.lastAction = action
        if let app = Self.appName(in: action) { context.lastApp = app }
        recordedAt = now
    }

    /// The context, or nil once nothing has run for `lifetime` seconds.
    func snapshot(now: Date = Date()) -> RioFollowUpContext? {
        lock.lock()
        defer { lock.unlock() }
        guard let recordedAt, context.lastAction != nil, now.timeIntervalSince(recordedAt) <= Self.lifetime else { return nil }
        return context
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
    /// The action a pronoun phrase stands for, or nil when it isn't one (or there is nothing for
    /// the pronoun to point at). `simplified` is `RioText.simplify` of what was said.
    static func rewrite(_ simplified: String, context: RioFollowUpContext?) -> RioAction? {
        guard let context, let last = context.lastAction else { return nil }
        let text = simplified.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return appVerb(text, context)
            ?? window(text, context)
            ?? sameFor(text, last)
            ?? send(text, context)
            ?? repeatLast(text, last)
    }

    private static let pronoun = #"(?:it|that|this|that one|this one|that app|the app|the same app)"#
    private static let notATarget: Set<String> = [
        "it", "that", "this", "them", "him", "her", "me", "us", "you", "now", "today", "later", "again", "tomorrow", "too", "one",
    ]

    // MARK: Open / close it

    private static func appVerb(_ text: String, _ context: RioFollowUpContext) -> RioAction? {
        let pattern = #"^(open|launch|start|reopen|bring up|close|quit|exit|hide|switch to|go back to|go to)\s+"# + pronoun + #"(?:\s+again)?(?:\s+please)?$"#
        guard let verb = RioText.firstMatch(pattern, in: text)?[1]?.lowercased(), let app = context.lastApp else { return nil }
        switch verb {
        case "open", "launch", "start", "reopen", "bring up": return .openApp(name: app)
        case "close", "quit", "exit": return .quitApp(name: app)
        case "hide": return .hideApp(name: app)
        default: return .switchToApp(name: app)
        }
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

    private static func sameFor(_ text: String, _ last: RioAction) -> RioAction? {
        let patterns = [
            #"^(?:(?:do|run|repeat)\s+)?(?:the\s+)?same(?:\s+thing)?\s+(?:for|with|on|to)\s+(.+)$"#,
            #"^(?:do|run|repeat)\s+(?:that|it|this)\s+(?:for|with|on|to)\s+(.+)$"#,
        ]
        for pattern in patterns {
            guard let raw = RioText.firstMatch(pattern, in: text)?[1], let target = cleanTarget(raw) else { continue }
            return substitute(target, into: last)
        }
        return nil
    }

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
        case .sendMessage(_, let body): return .sendMessage(to: target, body: body)
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

    // MARK: Again

    private static func repeatLast(_ text: String, _ last: RioAction) -> RioAction? {
        let again = #"^(?:(?:do|run|try|say|repeat|redo)\s+)?(?:(?:it|that|this|the\s+same(?:\s+thing)?|same)\s*)?(?:again|one\s+more\s+time|once\s+more)(?:\s+please)?$"#
        let redo = #"^(?:repeat|redo)\s+(?:it|that|this|the\s+last\s+(?:one|command))$"#
        guard RioText.matches(again, text) || RioText.matches(redo, text) else { return nil }
        switch last {
        case .undoLast, .typeText, .stopListening: return nil
        default: return last
        }
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
