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
}

enum RioSmartContextLimits {
    static let maxRunningApps = 30
    static let maxInstalledApps = 150
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

    init(command: String, context: RioSmartContext, attempt: RioSmartAttempt? = nil) {
        self.command = command
        self.context = context
        self.attempt = attempt
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
/// through the local parser and keeps its existing rules.
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
