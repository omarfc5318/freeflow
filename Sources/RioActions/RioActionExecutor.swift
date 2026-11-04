import AppKit
import Foundation

/// Runs a `RioAction`. The action set is closed, so nothing here can run an arbitrary command:
/// URLs are re-checked as http/https, AppleScript comes from `RioVolume`, and the only
/// processes are the two fixed tools in `MacControls.FixedTool`.
@MainActor
final class RioActionExecutor {
    private let windowController: WindowControlling
    private let companion: RioCompanionDirecting?
    private let typeText: @MainActor (String) async -> Bool
    private let handlers: [RioActionHandling]
    private var cachedApps: [InstalledApp]?
    /// The app the last open/switch brought forward, for `settleFocus()`.
    private var lastFocusedApp: InstalledApp?

    init(
        windowController: WindowControlling,
        companion: RioCompanionDirecting?,
        typeText: @escaping @MainActor (String) async -> Bool,
        handlers: [RioActionHandling] = []
    ) {
        self.windowController = windowController
        self.companion = companion
        self.typeText = typeText
        self.handlers = handlers
        // "Close it" may only quit the app that is really in front (RioFollowUpRewriter).
        RioFollowUpMemory.shared.setEnvironmentProvider {
            RioFollowUpEnvironment(frontApp: NSWorkspace.shared.frontmostApplication?.localizedName)
        }
    }

    func execute(_ action: RioAction) async -> RioActionResult {
        switch action {
        case .openApp(let name):
            return await launchAndFocus(spoken: name, verb: "Opened")
        case .switchToApp(let name):
            return await launchAndFocus(spoken: name, verb: "Switched to")
        case .quitApp(let name):
            return quit(spoken: name)
        case .hideApp(let name):
            return hide(spoken: name)
        case .openURL(let url):
            return open(url)
        case .webSearch(let query):
            guard let url = RioWebURLs.googleSearchURL(query: query) else {
                return .failed(message: "I didn't catch what to search for")
            }
            let result = open(url)
            if case .done = result { return .done(summary: "Searching for \(query)") }
            return result
        case .volume(let change):
            return changeVolume(change)
        case .media(let command):
            // "Pause" when nothing plays must not start music, and "play" while music plays
            // must not pause it: check first where Rio can (RioMediaPlan).
            let state = RioMediaPlan.needsState(command) ? MacControls.playbackState() : .unknown
            let decision = RioMediaPlan.decide(command, state: state)
            if decision.pressesKey { MacControls.pressMediaKey(command) }
            return .done(summary: decision.summary)
        case .lockScreen:
            MacControls.lockScreen()
            return .done(summary: "Locked the screen")
        case .screenshot(let kind):
            return await takeScreenshot(kind)
        case .doNotDisturb(let isOn):
            return await setDoNotDisturb(isOn)
        case .window(let command):
            return windowController.apply(command)
        case .typeText(let text):
            return await typeText(text)
                ? .done(summary: "Typed it")
                : .failed(message: "I couldn't type that here")
        case .stopListening:
            // The coordinator turns conversation mode off when it sees this action.
            return .done(summary: "Stopped listening")
        default:
            // Smart and wave 2 actions belong to the handlers (docs/rio-actions-plan.md).
            for handler in handlers {
                if let result = await handler.handle(action, executor: self) { return result }
            }
            return .failed(message: "I can't do that one yet")
        }
    }

    // MARK: Apps

    private func installedApps(rescan: Bool = false) -> [InstalledApp] {
        if rescan || cachedApps == nil { cachedApps = InstalledAppCatalog.scan() }
        return cachedApps ?? []
    }

    private func runningApps() -> [InstalledApp] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let url = app.bundleURL,
                  let name = app.localizedName else { return nil }
            return InstalledApp(name: name, bundleIdentifier: app.bundleIdentifier, url: url)
        }
    }

    private func resolveInstalled(_ spoken: String) -> InstalledApp? {
        if let app = AppNameMatcher.bestMatch(for: spoken, in: installedApps()) { return app }
        // A just-installed app: look once more before giving up.
        return AppNameMatcher.bestMatch(for: spoken, in: installedApps(rescan: true))
    }

    private func runningApplication(for app: InstalledApp) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { running in
            if let id = app.bundleIdentifier, running.bundleIdentifier == id { return true }
            return running.bundleURL == app.url
        }
    }

    /// HARD RULE (owner): the launch starts first, in the background and not activated; the bear
    /// is asked second; `punch` (or an immediate fallback) activates. Nothing ever waits on the bear
    /// before the launch has started.
    private func launchAndFocus(spoken: String, verb: String) async -> RioActionResult {
        guard let app = resolveInstalled(spoken) else {
            return .failed(message: "I couldn't find an app called \(spoken)")
        }
        let launch = LaunchState(bundleIdentifier: app.bundleIdentifier, url: app.url)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: app.url, configuration: configuration) { running, error in
            let pid = running?.processIdentifier
            let message = error?.localizedDescription
            Task { @MainActor in launch.finish(processIdentifier: pid, errorMessage: message) }
        }

        var punched = false
        let punch: @MainActor () -> Void = {
            punched = true
            launch.requestActivation()
        }
        let handled = await companion?.runAndPunchDockIcon(
            appURL: app.url, bundleIdentifier: app.bundleIdentifier, punch: punch
        ) ?? false
        if !handled || !punched { launch.requestActivation() }

        await launch.waitUntilFinished()
        if let message = launch.errorMessage {
            return .failed(message: "I couldn't open \(app.name): \(message)")
        }
        lastFocusedApp = app
        // An unnamed window command right after this means this app's window (F29/F30).
        if let running = runningApplication(for: app) {
            RioRecentWindowTarget.shared.note(processIdentifier: running.processIdentifier, name: app.name)
        }
        return .done(summary: "\(verb) \(app.name)")
    }

    private func quit(spoken: String) -> RioActionResult {
        guard let match = AppNameMatcher.bestMatch(for: spoken, in: runningApps())
            ?? AppNameMatcher.bestMatch(for: spoken, in: installedApps()) else {
            return .failed(message: "I couldn't find an app called \(spoken)")
        }
        guard let running = runningApplication(for: match) else {
            return .done(summary: "\(match.name) wasn't running")
        }
        if running.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return .failed(message: "I won't quit myself")
        }
        // terminate() asks the app to quit; it can still offer to save. Never forceTerminate().
        return running.terminate()
            ? .done(summary: "Quit \(match.name)")
            : .failed(message: "\(match.name) wouldn't quit")
    }

    private func hide(spoken: String) -> RioActionResult {
        guard let match = AppNameMatcher.bestMatch(for: spoken, in: runningApps())
            ?? AppNameMatcher.bestMatch(for: spoken, in: installedApps()) else {
            return .failed(message: "I couldn't find an app called \(spoken)")
        }
        guard let running = runningApplication(for: match) else {
            return .done(summary: "\(match.name) isn't running")
        }
        return running.hide()
            ? .done(summary: "Hid \(match.name)")
            : .failed(message: "I couldn't hide \(match.name)")
    }

    // MARK: Web

    private func open(_ url: URL) -> RioActionResult {
        guard RioWebURLs.isSafeWebURL(url) else {
            return .failed(message: "I only open web links")
        }
        return NSWorkspace.shared.open(url)
            ? .done(summary: "Opened \(url.host ?? "the link")")
            : .failed(message: "I couldn't open that link")
    }

    // MARK: Mac controls

    private func changeVolume(_ change: VolumeChange) -> RioActionResult {
        switch change {
        case .mute:
            return MacControls.setMuted(true) ? .done(summary: "Muted") : .failed(message: "I couldn't change the volume")
        case .unmute:
            return MacControls.setMuted(false) ? .done(summary: "Unmuted") : .failed(message: "I couldn't change the volume")
        case .up, .down, .set:
            var current = 0
            if case .set = change {} else {
                guard let level = MacControls.currentVolume() else {
                    return .failed(message: "I couldn't read the volume")
                }
                current = level
            }
            guard let target = RioVolume.level(after: change, from: current) else {
                return .failed(message: "I couldn't change the volume")
            }
            guard MacControls.setVolume(target) else { return .failed(message: "I couldn't change the volume") }
            if target > 0 { MacControls.setMuted(false) }
            return .done(summary: "Volume \(target) percent")
        }
    }

    private func takeScreenshot(_ kind: ScreenshotKind) async -> RioActionResult {
        let path = RioScreenshot.outputPath(now: Date(), desktop: MacControls.desktopURL)
        let arguments = RioScreenshot.arguments(
            kind: kind, outputPath: path, windowID: kind == .window ? MacControls.frontmostWindowID() : nil
        )
        guard await MacControls.run(.screencapture, arguments: arguments) != nil else {
            return .failed(message: "I couldn't take a screenshot")
        }
        if FileManager.default.fileExists(atPath: path) {
            return .done(summary: "Saved a screenshot to the Desktop")
        }
        // screencapture exits without a file when the selection is cancelled or permission is missing.
        return kind == .fullScreen || kind == .window
            ? .failed(message: "I couldn't take a screenshot. Check Screen Recording permission")
            : .cancelled
    }

    /// Best effort: run the user's own "Rio Focus On/Off" Shortcut.
    private func setDoNotDisturb(_ isOn: Bool) async -> RioActionResult {
        let name = RioShortcuts.name(isOn: isOn)
        let missing = RioActionResult.failed(
            message: "Create a Shortcut named \"\(name)\" that turns Focus \(isOn ? "on" : "off"), then ask again"
        )
        guard let list = await MacControls.run(.shortcuts, arguments: RioShortcuts.listArguments),
              list.status == 0, RioShortcuts.listContains(list.output, isOn: isOn) else { return missing }
        guard let run = await MacControls.run(.shortcuts, arguments: RioShortcuts.runArguments(isOn: isOn)),
              run.status == 0 else {
            return .failed(message: "The \"\(name)\" Shortcut didn't run")
        }
        return .done(summary: "Do Not Disturb \(isOn ? "on" : "off")")
    }
}

/// Tracks one app launch so activation can be requested before or after it finishes.
@MainActor
private final class LaunchState {
    private let bundleIdentifier: String?
    private let url: URL
    private var processIdentifier: pid_t?
    private var activateWhenReady = false
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var errorMessage: String?

    init(bundleIdentifier: String?, url: URL) {
        self.bundleIdentifier = bundleIdentifier
        self.url = url
    }

    func requestActivation() {
        if let app = currentApplication() {
            activate(app)
        } else {
            activateWhenReady = true
        }
    }

    func finish(processIdentifier: pid_t?, errorMessage: String?) {
        self.processIdentifier = processIdentifier
        self.errorMessage = errorMessage
        finished = true
        if activateWhenReady, let app = currentApplication() {
            activate(app)
        }
        activateWhenReady = false
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }

    func waitUntilFinished() async {
        if finished { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func currentApplication() -> NSRunningApplication? {
        if let pid = processIdentifier, let app = NSRunningApplication(processIdentifier: pid) { return app }
        return NSWorkspace.shared.runningApplications.first {
            if let id = bundleIdentifier, $0.bundleIdentifier == id { return true }
            return $0.bundleURL == url
        }
    }

    private func activate(_ app: NSRunningApplication) {
        if app.isHidden { app.unhide() }
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }
}

// MARK: Front app

extension RioActionExecutor: RioFrontAppReporting {
    /// The app in front now, for conversation mode's terminal check (name and bundle ID only).
    func frontmostApp() -> RioFrontApp {
        let app = NSWorkspace.shared.frontmostApplication
        return RioFrontApp(name: app?.localizedName, bundleID: app?.bundleIdentifier)
    }
}

// MARK: Focus settling

extension RioActionExecutor: RioFocusSettling {
    private static let settleTimeout: TimeInterval = 1.2
    private static let settlePollNanoseconds: UInt64 = 50_000_000

    /// Waits (briefly) until the app the last open/switch activated is really frontmost, so a
    /// following key press or click lands in it. Returns at once when it already is.
    func settleFocus() async {
        guard let app = lastFocusedApp else { return }
        let deadline = Date().addingTimeInterval(Self.settleTimeout)
        while Date() < deadline {
            if let front = NSWorkspace.shared.frontmostApplication {
                if let id = app.bundleIdentifier, front.bundleIdentifier == id { return }
                if front.bundleURL == app.url { return }
            }
            try? await Task.sleep(nanoseconds: Self.settlePollNanoseconds)
        }
    }
}
