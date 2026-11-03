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

    /// True for actions that reach another person or can't be undone; the executor must get
    /// an explicit confirmation from the user before running them.
    var requiresConfirmation: Bool {
        if case .sendMessage = self { return true }
        return false
    }
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
