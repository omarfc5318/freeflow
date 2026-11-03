import Foundation

// Shared contract for Rio Actions. Every builder codes against these types; change them only
// with the lead's agreement (see docs/rio-actions-plan.md). Pure value types: no AppKit here,
// so the parser and its tests stay dependency-free.

/// Something Rio can do on the Mac. The set is closed on purpose: neither the local parser nor
/// the smart (LLM) resolver can ever produce anything outside it, so no request can turn into an
/// arbitrary shell command or script.
enum RioAction: Equatable, Codable {
    // Apps and the web
    case openApp(name: String)
    case quitApp(name: String)
    case switchToApp(name: String)
    case hideApp(name: String)
    case openURL(URL)
    case webSearch(query: String)

    // Mac controls
    case volume(VolumeChange)
    case media(MediaCommand)
    case lockScreen
    case screenshot(ScreenshotKind)
    case doNotDisturb(isOn: Bool)

    // Windows
    case window(WindowCommand)

    // Text and conversation mode
    /// Types `text` into the focused field (conversation mode's "Rio, type …").
    case typeText(String)
    /// Turns conversation mode off ("Rio, stop listening").
    case stopListening

    // Smart actions (resolved by the LLM in wave 2; the parser never emits these)
    /// Always asks the user to confirm before anything is sent.
    case sendMessage(to: String, body: String)
    case createReminder(title: String, due: Date?)
    case selectionTask(SelectionTask)

    // Wave 2 (contract v2). Owners in docs/rio-actions-plan.md.
    // E: context and reading
    /// Types `body` into the open conversation's compose field and sends it. Always confirmed.
    case replyInConversation(body: String)
    case readAloud(ReadTarget)
    /// An answer to a question, produced by the smart resolver; spoken and shown.
    case answer(String)
    // G: voice, timers, undo, help
    case startTimer(seconds: Int, label: String?)
    case cancelTimer
    case timerStatus
    case undoLast
    case showHelp
    // H: files, calendar, clipboard
    /// Spotlight search, open the best match.
    case openFile(query: String)
    /// Spotlight search, reveal the best match in Finder.
    case revealFile(query: String)
    case calendarAgenda(CalendarRange)
    case joinNextMeeting
    case createEvent(title: String, start: Date, durationMinutes: Int?)
    case clipboard(ClipboardCommand)
    // I: keyboard, browser, system
    case pressKeys(KeyCombo)
    case browser(BrowserCommand)
    case systemToggle(SystemSetting, isOn: Bool)
    case brightness(VolumeChange)
    case batteryStatus
    /// Always confirmed.
    case emptyTrash

    /// True for actions that reach another person or can't be undone; the coordinator must get
    /// an explicit confirmation from the user before running them.
    var requiresConfirmation: Bool {
        switch self {
        case .sendMessage, .replyInConversation, .emptyTrash: return true
        default: return false
        }
    }
}

enum ReadTarget: String, Equatable, Codable {
    /// The newest incoming message in the open conversation (Messages, WhatsApp, Slack…).
    case lastMessage
    /// The selected text in any app.
    case selection
    /// The readable text of the front browser page.
    case page
}

enum CalendarRange: String, Equatable, Codable {
    case today
    case tomorrow
    /// The next upcoming event.
    case next
}

enum ClipboardCommand: Equatable, Codable {
    /// Say/show what's on the clipboard now.
    case readCurrent
    /// Paste a recent clipboard item; `matching` is a spoken hint ("the link", "the address").
    case pasteRecent(matching: String?)
    /// Show the recent clipboard history.
    case showHistory
}

/// A keyboard shortcut. `key` must be in `KeyCombo.allowedKeys`; executors refuse anything else.
struct KeyCombo: Equatable, Codable {
    let key: String
    let command: Bool
    let shift: Bool
    let option: Bool
    let control: Bool

    static let allowedKeys: Set<String> = Set("abcdefghijklmnopqrstuvwxyz0123456789".map(String.init))
        .union(["return", "escape", "tab", "space", "delete", "forwarddelete", "up", "down", "left", "right",
                "home", "end", "pageup", "pagedown", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9",
                "f10", "f11", "f12", "comma", "period", "slash", "semicolon", "quote", "leftbracket",
                "rightbracket", "minus", "equal", "backtick", "backslash"])
}

enum BrowserCommand: String, Equatable, Codable {
    case newTab, closeTab, reopenTab, nextTab, previousTab, back, forward, reload
    case scrollDown, scrollUp, scrollToTop, scrollToBottom, find
}

enum SystemSetting: String, Equatable, Codable {
    case wifi, bluetooth, darkMode, nightShift
}

enum VolumeChange: Equatable, Codable {
    case up
    case down
    /// 0...100; parsers clamp.
    case set(Int)
    case mute
    case unmute
}

enum MediaCommand: String, Equatable, Codable {
    case playPause
    case next
    case previous
}

enum ScreenshotKind: String, Equatable, Codable {
    /// Whole screen, saved to the Desktop.
    case fullScreen
    /// Interactive selection (crosshair), saved to the Desktop.
    case selection
    /// Frontmost window, saved to the Desktop.
    case window
}

enum WindowPlacement: String, Equatable, Codable, CaseIterable {
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case maximize
    case center
    case minimize
    /// Moves the window to the next display, keeping its relative frame.
    case nextScreen
}

struct WindowCommand: Equatable, Codable {
    /// Spoken app name, resolved by the executor; nil means the frontmost app's focused window.
    let appName: String?
    let placement: WindowPlacement
}

enum SelectionTask: Equatable, Codable {
    case summarize
    case explain
    /// Target language as spoken ("Arabic", "French").
    case translate(language: String)
    /// Rewrites the selection in place (grammar and clarity), like Edit Mode.
    case improve
}

/// What the parser made of a transcript.
enum RioActionParse: Equatable {
    /// One or more actions to run in order ("put Chrome on the left and Warp on the right").
    case actions([RioAction])
    /// Not understood locally; the text (with "Rio" stripped) goes to the smart resolver.
    case unknown(String)
    /// Nothing but the name or filler ("Rio", "uh"); do nothing, no shrug.
    case empty
}

/// The outcome the pill and history show.
enum RioActionResult: Equatable {
    /// `summary` is short and user-facing: "Opened Google Chrome".
    case done(summary: String)
    /// `message` is user-facing: "I couldn't find an app called Crome".
    case failed(message: String)
    /// The user declined a confirmation or it timed out.
    case cancelled
}

/// An app installed on this Mac, as the parser sees it.
struct InstalledApp: Equatable, Hashable {
    /// Display name without ".app": "Google Chrome".
    let name: String
    let bundleIdentifier: String?
    let url: URL
}

// MARK: Rio companion (the corner bear)

/// What the corner bear shows for Rio Actions. AppState publishes it as `rioActionPhase`;
/// the companion view only observes it.
enum RioActionPhase: Equatable {
    /// Asleep in the corner (or nothing to show).
    case idle
    /// Action key is down or conversation mode heard "Rio": awake and alert, listening.
    case listening
    /// Transcribing / resolving / running: "Opening Google Chrome".
    case working(String)
    case succeeded(String)
    case failed(String)
}

/// The corner bear's Dock run. HARD RULE (owner, 2026-11-03): the bear must never add delay.
/// The executor starts launching the app in the background (not activated) BEFORE calling
/// this, the bear's sprint plus punch is capped at `maxRunDuration`, and `punch` activates the
/// app. If the bear is hidden, disabled, mid-trick, the Dock is hidden or on a side, or the app
/// has no Dock icon, return false at once without calling `punch`; the executor then activates
/// the app normally.
@MainActor protocol RioCompanionDirecting: AnyObject {
    func runAndPunchDockIcon(
        appURL: URL,
        bundleIdentifier: String?,
        punch: @escaping @MainActor () -> Void
    ) async -> Bool
}

enum RioCompanionTiming {
    /// Sprint from the corner plus the punch, end to end.
    static let maxRunDuration: TimeInterval = 0.4
}
