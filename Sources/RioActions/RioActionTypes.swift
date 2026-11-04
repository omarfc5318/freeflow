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

    // Wave 3 (contract v3). Owners in docs/rio-actions-plan.md.
    // J: screen understanding and click by voice
    case describeScreen(question: String?)
    case click(label: String, ordinal: Int?)
    case fillField(label: String, text: String)
    // K: multi-step tasks
    case runTask(goal: String)
    // L: memory, email drafts, notes, math
    case remember(fact: String)
    case recall(query: String)
    case forget(query: String)
    /// Opens a compose window; never sends.
    case draftEmail(to: String?, subject: String?, body: String)
    case addNote(text: String)
    case calculate(expression: String)
    // M: live translator
    case startTranslation
    case stopTranslation
    case speakLastTranslation

    // Waves 4–5 (contract v4). Owners in docs/rio-actions-plan.md "Waves 4–5".
    // N: context and memory
    case searchHistory(query: String)
    // O: writing
    case editLastDictation(instruction: String)
    case writeForMe(instruction: String)
    case smartPaste(instruction: String)
    // P: automation
    case scheduleCommand(command: String, when: String)
    case addTrigger(command: String, trigger: String)
    case listAutomations
    case removeAutomation(name: String)
    case recordMacro(name: String)
    case stopRecordingMacro
    case runMacro(name: String)
    // Q: finding and files
    case findThing(query: String)
    /// Always confirmed (moves and renames files).
    case organizeDownloads
    case copyTextFromScreen
    // S: outside world
    case weather(place: String?)
    case news(topic: String?)
    case playMusic(query: String)
    case notionAdd(text: String, page: String?)
    case canvasDue(range: String?)
    // T: meetings and Claude Code
    case meeting(MeetingCommand)
    case claudeCode(ClaudeCodeCommand)

    /// True for actions that reach another person or can't be undone; the coordinator must get
    /// an explicit confirmation from the user before running them.
    var requiresConfirmation: Bool {
        switch self {
        case .sendMessage, .replyInConversation, .emptyTrash, .organizeDownloads: return true
        case .claudeCode(.approve): return true
        default: return false
        }
    }
}

enum MeetingCommand: String, Equatable, Codable {
    /// Start keeping a rolling few minutes of call audio (on the Mac only).
    case start
    case stop
    /// "What did they just say?"
    case whatWasSaid
    case actionItems
    case recap
}

enum ClaudeCodeCommand: Equatable, Codable {
    /// Types a prompt into the owner's Claude Code session and sends it.
    case send(String)
    /// Approves Claude Code's pending permission prompt. Always confirmed, showing the prompt.
    case approve
    case deny
    /// "What's Claude doing?"
    case status
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
    /// A blind toggle ("play/pause", "toggle playback").
    case playPause
    case next
    case previous
    /// Pause only: nothing happens when nothing is playing ("pause", "stop the music").
    case pause
    /// Play only: nothing happens when something already plays ("play", "resume").
    case play
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
