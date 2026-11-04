import Foundation

// Understanding-first routing (owner design change, 2026-11-03: "You shouldn't hard-code
// commands. It should hear what I say, understand it, and then go and do it."). The local parser
// acts alone only when it is sure; everything else goes to the smart resolver with a little
// context about the Mac, which may plan several closed-set steps, and a failed step is fed back
// for a new plan. Pure value types and rules, Foundation only.

/// What the local parser made of a transcript, and how sure it is.
struct RioParseAnalysis: Equatable {
    let parse: RioActionParse
    /// False when an `.actions` parse rests on a guess: an app or window target that does not
    /// resolve to an installed app ("open another Chrome window" read as an app called "another
    /// Chrome window"). The coordinator then asks the resolver first and keeps this parse as the
    /// offline fallback. Always true for `.empty`; meaningless for `.unknown`.
    let isConfident: Bool
    /// The command as the resolver should see it (name and trailing filler removed).
    let resolverText: String
}

/// Facts about the Mac the resolver may use to understand a command. Built on the Mac from the
/// front app, its focused window title (never for a window Rio must not read), the running and
/// installed app names, and the previous command. Never logged or stored.
struct RioSmartContext: Equatable {
    var frontApp: String?
    var frontWindowTitle: String?
    var runningApps: [String] = []
    var installedApps: [String] = []
    /// The owner's previous command (their own words), while it is recent.
    var previousCommand: String?
    /// What that command did, as short step descriptions (`RioSmartPlanText`).
    var previousActions: [String] = []
    /// Rio's own state the model needs to read a short command ("Rio is recording a macro", so
    /// "I'm done" means stop recording). Fixed Rio strings, never user content.
    var activity: [String] = []
}

/// Fixed lines for `RioSmartContext.activity`.
enum RioSmartActivity {
    static let recordingMacro = "Rio is recording a macro (stop, I'm done or stop recording ends it)"
}

enum RioSmartContextLimits {
    static let maxRunningApps = 30
    static let maxInstalledApps = 150
    /// Installed apps sent with one command: only names the command could mean.
    static let maxRelevantInstalledApps = 12
    static let maxActivityLines = 3
    static let maxNameCharacters = 60
    /// The window title is untrusted page text, so it is kept short.
    static let maxTitleCharacters = 80
    static let maxCommandCharacters = 200
    static let maxPreviousActions = 6
    static let maxStepCharacters = 120
    /// How long the previous command stays useful context (the follow-up memory's lifetime).
    static let previousCommandLifetime: TimeInterval = RioFollowUpMemory.lifetime
}

/// A failed step, fed back to the resolver so it can plan around it.
struct RioSmartAttempt: Equatable {
    /// Steps of the last plan that already ran (they are not run again).
    let completed: [String]
    let failedStep: String
    /// Rio's own user-facing failure message ("I couldn't find an app called ...").
    let failure: String
    /// 1 for the first re-plan.
    let round: Int
}

struct RioSmartRequest: Equatable {
    let command: String
    var context: RioSmartContext
    var attempt: RioSmartAttempt?
    /// The language the owner spoke the command in (it reaches Rio translated to English), so a
    /// spoken answer comes back in that language. Read from what the translator last recorded.
    var spokenLanguage: RioSpokenLanguage

    init(
        command: String, context: RioSmartContext, attempt: RioSmartAttempt? = nil,
        spokenLanguage: RioSpokenLanguage? = nil
    ) {
        self.command = command
        self.context = context
        self.attempt = attempt
        self.spokenLanguage = spokenLanguage ?? RioSpokenLanguageMemory.shared.language(forCommand: command, now: Date())
    }
}

enum RioSmartResolution: Equatable {
    /// A validated plan (possibly a single `.answer`); empty means "not something Rio can do".
    case actions([RioAction])
    /// The brain can't be asked right now (off, offline, no key, unreachable, too slow).
    /// The message is user-facing and spoken.
    case unavailable(String)
    /// The resolver itself failed.
    case failed(String)
}

/// Gathers `RioSmartContext` on the Mac (AppKit and Accessibility live in the app target).
@MainActor protocol RioSmartContextProviding: AnyObject {
    func currentContext() async -> RioSmartContext
}

/// An executor that can wait for an app it just activated to really be in front, so a key press
/// planned after "switch to Chrome" lands in Chrome and not in the app that was there before.
@MainActor protocol RioFocusSettling: AnyObject {
    func settleFocus() async
}

enum RioSmartRouting {
    /// Re-plans after a failed step, on top of the first plan.
    static let maxReplans = 2

    /// Steps that act on whatever app is in front, so they must wait for an app switch to land.
    static func actsOnFrontApp(_ action: RioAction) -> Bool {
        switch action {
        case .pressKeys, .browser, .click, .fillField, .typeText, .describeScreen, .readAloud, .selectionTask,
             .copyTextFromScreen, .runTask:
            return true
        case .window(let command):
            return command.appName == nil
        default:
            return false
        }
    }

    /// A step the brain planned (not the owner's own words) that presses something which may send,
    /// buy, submit, delete or empty the Trash, or fills a private field: it asks first.
    /// A planned click or fill judged on the element it really resolves to (the executor presses
    /// whatever the matcher makes of the label): unresolved, non-exact, risky or private targets,
    /// and card-like values, all ask first.
    static func resolvedPlannedStepNeedsConfirmation(_ action: RioAction, _ resolution: RioTaskTargetResolution) -> Bool {
        switch action {
        case .click, .fillField: break
        default: return false
        }
        guard case .resolved(let candidates, let isExact) = resolution else { return true }
        if !isExact { return true }
        if candidates.contains(where: { $0.texts.contains(where: { RioTaskSafety.isRiskyText($0) || RioTaskSafety.isSensitiveLabel($0) }) }) {
            return true
        }
        if case .fillField(_, let text) = action, RioTaskSafety.containsSensitiveValue(text) { return true }
        return false
    }

    static func isClickOrFill(_ action: RioAction) -> Bool {
        switch action {
        case .click, .fillField: return true
        default: return false
        }
    }

    static func plannedStepNeedsConfirmation(_ action: RioAction) -> Bool {
        switch action {
        case .click(let label, _):
            return RioTaskSafety.isRiskyText(label) || RioText.matches(#"\bempty\b"#, label)
        case .fillField(let label, _):
            return RioTaskSafety.isSensitiveLabel(label) || RioTaskSafety.isRiskyText(label)
        default:
            return false
        }
    }

    static func focusesApp(_ action: RioAction) -> Bool {
        switch action {
        case .openApp, .switchToApp: return true
        default: return false
        }
    }
}

/// Short, plain descriptions of steps for the resolver's context and re-plan notes. Message
/// bodies and typed text are never repeated (the step's kind is enough to re-plan).
enum RioSmartPlanText {
    static func describe(_ action: RioAction) -> String {
        let text: String
        switch action {
        case .openApp(let name): text = "openApp \(name)"
        case .quitApp(let name): text = "quitApp \(name)"
        case .switchToApp(let name): text = "switchToApp \(name)"
        case .hideApp(let name): text = "hideApp \(name)"
        case .openURL(let url): text = "openURL \(url.host ?? "link")"
        case .webSearch: text = "webSearch"
        case .pressKeys(let combo): text = "pressKeys \(RioKeyCombos.describe(combo))"
        case .browser(let command): text = "browser \(command.rawValue)"
        case .window(let command): text = "window \(command.placement.rawValue)" + (command.appName.map { " \($0)" } ?? "")
        case .click(let label, let ordinal): text = "click \(label)" + (ordinal.map { " #\($0)" } ?? "")
        case .fillField(let label, _): text = "fillField \(label)"
        case .openFile(let query): text = "openFile \(query)"
        case .revealFile(let query): text = "revealFile \(query)"
        case .volume: text = "volume"
        case .media(let command): text = "media \(command.rawValue)"
        case .answer: text = "answer"
        case .runTask: text = "runTask"
        case .describeScreen: text = "describeScreen"
        case .recordMacro: text = "recordMacro (now recording)"
        case .stopRecordingMacro: text = "stopRecordingMacro"
        case .scheduleCommand: text = "scheduleCommand"
        case .addTrigger: text = "addTrigger"
        case .claudeCode(let command):
            switch command {
            case .send: text = "claudeCode send"
            case .approve: text = "claudeCode approve"
            case .deny: text = "claudeCode deny"
            case .status: text = "claudeCode status"
            }
        default: text = RioActionText.working(for: action)
        }
        return RioSmartContextText.line(text, max: RioSmartContextLimits.maxStepCharacters)
    }
}

/// Context text the model sees: one line, no control characters, no prompt fence markers.
enum RioSmartContextText {
    /// Upper-case fence words only, so a window called "Command Center" keeps its name.
    private static let fenceWords = #"(?-i:<<<|>>>|\b(?:COMMAND|CONTEXT|ATTEMPT|UNTRUSTED)\b)"#

    static func line(_ text: String, max: Int) -> String {
        let scalars = text.unicodeScalars.map { scalar -> Character in
            scalar.properties.generalCategory == .control || scalar == "\u{2028}" || scalar == "\u{2029}" ? " " : Character(scalar)
        }
        var cleaned = RioText.collapseWhitespace(String(scalars))
        cleaned = RioText.collapseWhitespace(RioText.replacing(fenceWords, with: " ", in: cleaned))
        guard cleaned.count > max else { return cleaned }
        return String(cleaned.prefix(max)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    /// Names, cleaned, empty ones dropped, duplicates removed, at most `limit` of them.
    static func names(_ names: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names {
            let cleaned = line(name.replacingOccurrences(of: ",", with: " "), max: RioSmartContextLimits.maxNameCharacters)
            let key = cleaned.lowercased()
            guard !cleaned.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(cleaned)
            if result.count == limit { break }
        }
        return result
    }
}

/// Which key presses the resolver may plan (security review, 2026-11-03): a small ALLOWLIST of
/// navigation combos, nothing else. Nothing that types, submits, deletes, selects-all, pastes or
/// quits: no Return, Space, Delete, Command-Q, Command-A, Command-V, and no letter or digit
/// without Command. Anything else the model plans is dropped. The owner's own "press ..." goes
/// through the local parser and keeps its existing rules. Round 2 added four more navigation-only
/// combos (they open or switch, never type, submit, delete, paste or quit): Command-Shift-N (new
/// private window), Command-Shift-R (hard reload), Command-Shift-P (command palette) and one
/// Command-Tab press (back to the previous app).
enum RioSmartKeyPolicy {
    static let modifierNames: Set<String> = ["command", "shift", "option", "control"]

    private static func combo(_ key: String, command: Bool = false, shift: Bool = false, control: Bool = false) -> KeyCombo {
        KeyCombo(key: key, command: command, shift: shift, option: false, control: control)
    }

    static let allowed: [KeyCombo] = {
        var list: [KeyCombo] = [
            combo("n", command: true), combo("t", command: true), combo("t", command: true, shift: true),
            combo("w", command: true), combo("leftbracket", command: true), combo("rightbracket", command: true),
            combo("r", command: true), combo("f", command: true),
            combo("equal", command: true), combo("minus", command: true), combo("0", command: true),
            combo("tab", control: true), combo("tab", shift: true, control: true), combo("backtick", command: true),
            combo("escape"),
            combo("n", command: true, shift: true), combo("r", command: true, shift: true),
            combo("p", command: true, shift: true), combo("tab", command: true),
        ]
        list += (1...9).map { combo(String($0), command: true) }
        list += ["up", "down", "left", "right", "pageup", "pagedown", "home", "end"].map { combo($0) }
        return list
    }()

    static func isAllowed(_ combo: KeyCombo) -> Bool {
        RioKeyCombos.isAllowed(combo) && allowed.contains(combo)
    }
}

/// What of the Mac's state may go into `RioSmartContext`. Pure, so it is tested.
enum RioSmartContextPolicy {
    /// Apps whose windows Rio never reads (password managers, permission prompts).
    static func mayReadTitle(bundleID: String?) -> Bool {
        !RioClickSafety.isBlockedApp(bundleID: bundleID) && !RioClickSafety.isSensitiveCaptureApp(bundleID: bundleID)
    }

    /// The focused window's title, or nil when it must not be sent (a blocked app, a privacy or
    /// permissions pane, or a title that looks like it carries a code or card number).
    static func shareableTitle(bundleID: String?, title: String?) -> String? {
        guard mayReadTitle(bundleID: bundleID), !RioClickSafety.isBlockedWindow(bundleID: bundleID, title: title),
              let title, !RioTaskSafety.containsSensitiveValue(title) else { return nil }
        let line = RioSmartContextText.line(title, max: RioSmartContextLimits.maxTitleCharacters)
        return line.isEmpty ? nil : line
    }

    /// The window title is untrusted (a web page sets it): it goes to the model only when the
    /// command is about the window, tab or page in front ("close this tab", "summarise the page").
    static func commandRefersToWindow(_ command: String) -> Bool {
        RioText.matches(#"\b(?:this|that|the|current|front|my)\s+(?:\w+\s+)?(?:window|tab|page|site|website|document)\b"#, command)
            || RioText.matches(#"\b(?:in|on)\s+here\b"#, command)
    }

    /// Command words too common to pick out an app ("open", "window").
    private static let commonWords: Set<String> = [
        "open", "close", "quit", "launch", "start", "switch", "show", "hide", "please", "with", "that", "this",
        "what", "where", "when", "make", "then", "tell", "from", "into", "have", "there", "your", "just", "like",
        "want", "need", "could", "would", "should", "about", "again", "window", "windows", "screen", "full",
    ]

    /// The installed apps a command could mean, at most `maxRelevantInstalledApps`: a name that
    /// is whole words of the command with the spaces dropped ("text edit" is TextEdit), or one with a
    /// whole word the command says ("chrome" is Google Chrome; "chromes" still is, a command word
    /// that starts with a 4+ letter word of the name). Never a piece of a word: "whatsapp" is not
    /// Apps, "free" is not Freeform. Everything else stays on the Mac.
    static func relevantApps(_ names: [String], command: String) -> [String] {
        let allWords = command.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        // Runs of whole command words with the spaces dropped ("text edit" is "textedit").
        var spans: Set<String> = []
        for start in allWords.indices {
            for end in start..<min(allWords.count, start + 4) { spans.insert(allWords[start...end].joined()) }
        }
        let words = allWords.filter { $0.count >= 4 && !commonWords.contains($0) }
        var result: [String] = []
        for name in RioSmartContextText.names(names, limit: 1_000) {
            let app = name.lowercased().filter { $0.isLetter || $0.isNumber }
            guard app.count >= 3 else { continue }
            let tokens = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            let saysAWord = words.contains { word in
                tokens.contains { token in token == word || (token.count >= 4 && word.hasPrefix(token)) }
            }
            guard spans.contains(app) || saysAWord else { continue }
            result.append(name)
            if result.count == RioSmartContextLimits.maxRelevantInstalledApps { break }
        }
        return result
    }

    /// Installed app names for the prompt: apps in the Applications folders before system
    /// utilities, alphabetical, at most `maxInstalledApps`.
    static func installedNames(_ apps: [InstalledApp]) -> [String] {
        let sorted = apps.sorted { lhs, rhs in
            let lhsSystem = lhs.url.path.hasPrefix("/System/")
            let rhsSystem = rhs.url.path.hasPrefix("/System/")
            if lhsSystem != rhsSystem { return !lhsSystem }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return RioSmartContextText.names(sorted.map(\.name), limit: RioSmartContextLimits.maxInstalledApps)
    }
}

/// "Rio, how far is the moon": a question about the world, not about this Mac or the owner. It
/// goes to the brain without the Mac's context (no front app, window title or app lists): the
/// request is smaller, so the spoken answer comes back sooner, and less leaves the Mac. Anything
/// that points at the screen, an app, the owner's things or a previous step keeps the context.
enum RioQuestionShape {
    private static let leads: Set<String> = [
        "what", "whats", "who", "whos", "whose", "whom", "why", "when", "where", "which", "how", "hows",
        "is", "are", "was", "were", "does", "did", "define",
        // Asks for an explanation or a worked answer, said as an order ("explain the pigeonhole
        // principle", "solve x squared minus 5x plus 6 equals 0").
        "explain", "solve", "integrate", "differentiate", "derive", "simplify", "convert", "calculate", "translate",
    ]
    /// Leads that are a whole question in two words ("define entropy", "explain recursion").
    private static let shortLeads: Set<String> = ["define", "explain", "solve", "integrate", "differentiate", "derive", "simplify"]
    /// Spoken lead-ins dropped before looking at the question.
    private static let lead = #"^(?:(?:answer\s+(?:this|that|me)(?:\s+question)?|quick\s+question|tell\s+me|do\s+you\s+know)[\s:,]+)+"#
    /// Small talk with Rio himself ("how are you", "tell me a joke"): no Mac needed to answer.
    private static let smallTalk = #"^(?:(?:hey|hi|so|rio|okay|ok)\s+)*(?:how\s+are\s+you(?:\s+doing)?|whats\s+up|what\s+is\s+up|how\s+is\s+it\s+going|hows\s+it\s+going|who\s+are\s+you|what\s+are\s+you|whats\s+your\s+name|what\s+is\s+your\s+name|how\s+old\s+are\s+you|where\s+are\s+you\s+from|tell\s+me\s+(?:a|another)\s+(?:joke|riddle|fun\s+fact|story)|(?:say\s+)?(?:a|another)\s+joke)(?:\s+(?:today|tonight|rio|buddy|teddy|bear|man|then|please))*$"#
    /// Words that tie the question to this Mac, the owner or what just happened.
    private static let local: Set<String> = [
        "i", "im", "ive", "id", "me", "my", "mine", "myself", "we", "us", "our", "you", "your",
        "this", "that", "these", "those", "it", "its", "here", "there", "again", "same", "last", "previous",
        "screen", "window", "windows", "tab", "tabs", "page", "app", "apps", "button", "menu", "file", "files",
        "folder", "desktop", "downloads", "document", "clipboard", "selection", "selected", "cursor",
        "playing", "song", "music", "volume", "brightness", "battery", "wifi", "bluetooth", "mac", "laptop",
        "computer", "email", "emails", "message", "messages", "text", "texts", "calendar", "meeting", "meetings",
        "timer", "reminder", "reminders", "chrome", "safari", "spotify", "slack", "zoom", "warp",
        "finder", "claude", "notion", "canvas",
        // Something on the screen ("what's the answer to question 3", "is this proof right").
        "problem", "problems", "question", "questions", "exercise", "exercises", "proof", "pdf", "slide", "slides",
        // The Mac's own state, which the model cannot know ("how much ram is free", "is docker running").
        "ram", "memory", "storage", "disk", "cpu", "docker", "server", "servers", "port", "process", "processes",
        "build", "terminal", "localhost", "muted", "charging", "plugged", "connected", "recording", "installed",
        "saved", "synced", "downloaded",
        // The owner's own facts ("what's the staging url").
        "url", "password", "staging",
    ]
    /// Messages and the owner's school day: always about the owner, never the world.
    private static let personal: Set<String> = [
        "reply", "replied", "texted", "messaged", "emailed", "dm", "dms", "voicemail", "inbox", "class", "classes",
        "homework", "assignment", "assignments", "due", "schedule", "agenda",
    ]
    /// What people said: about the owner's messages when a name is in the question ("what did Ali
    /// say"); "who said ..." with no name stays a world question.
    private static let speech: Set<String> = [
        "say", "said", "says", "saying", "tell", "told", "ask", "asked", "wrote", "write", "send", "sent", "want", "wants", "mean", "meant",
    ]
    /// A how-to about the world ("how do I reverse a linked list", "how do you say thank you in
    /// Spanish"): its "I" or "you" is anyone, not the owner or Rio.
    private static let howTo = #"^how\s+(?:do|can|should|would|could|does|did)\s+(?:i|you|we|one|people)\b|^how\s+to\b"#
    private static let numberWords: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
    ]
    /// Times that are about the world, not the previous step ("who won the game last night").
    private static let lastTimes: Set<String> = ["night", "week", "weekend", "month", "year", "season", "time", "game", "match"]
    /// Words before "note" that make it the owner's note, not a convertible note.
    private static let ownedNote: Set<String> = ["my", "the", "this", "that", "these", "those", "new", "apple", "rio", "last", "latest"]
    private static let minimumWords = 3

    static func isGeneralQuestion(_ text: String) -> Bool {
        let lowered = text.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
        let trimmed = lowered.trimmingCharacters(in: .whitespaces)
        let all = trimmed.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if RioText.matches(smallTalk, all.joined(separator: " ")) { return true }
        let question = RioText.replacing(lead, with: "", in: trimmed)
        let words = question.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard let first = words.first, leads.contains(first),
              words.count >= minimumWords || (words.count >= 2 && shortLeads.contains(first)) else {
            return false
        }
        if RioText.matches(smallTalk, words.joined(separator: " ")) { return true }
        let isHowTo = RioText.matches(howTo, words.joined(separator: " "))
        for (index, word) in words.enumerated() where isLocal(word, at: index, in: words, isHowTo: isHowTo) {
            return false
        }
        if isHowTo { return true }
        return !(words.contains(where: speech.contains) && namesSomeone(text))
    }

    /// Whether `word` ties the question to the owner, with the uses that do not taken out:
    /// a how-to's "I" or "you", "is it", "last night", "e to the i pi", "a convertible note".
    private static func isLocal(_ word: String, at index: Int, in words: [String], isHowTo: Bool) -> Bool {
        let before = index > 0 ? words[index - 1] : ""
        let after = index + 1 < words.count ? words[index + 1] : ""
        if personal.contains(word) { return true }
        switch word {
        case "i", "you", "we":
            if isHowTo, index == 2 { return false }
            if word == "you", before == "thank" { return false }
            if word == "i", after == "pi" || after == "times" { return false }
        case "it":
            if ["is", "was", "will", "isnt", "wasnt"].contains(before) { return false }
        case "last":
            if lastTimes.contains(after) { return false }
        case "note", "notes":
            return ownedNote.contains(before) || after == "app"
        case "number":
            return Int(after) != nil || numberWords.contains(after)
        default:
            break
        }
        return local.contains(word)
    }

    /// A capitalised word after the first ("Ali", "Ali's"), other than "I".
    private static func namesSomeone(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "\u{2019}" }).dropFirst()
        return words.contains { word in
            guard let first = word.first, first.isUppercase else { return false }
            let bare = word.split(whereSeparator: { $0 == "'" || $0 == "\u{2019}" }).first.map(String.init) ?? String(word)
            return bare != "I"
        }
    }
}
