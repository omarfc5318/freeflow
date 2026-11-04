import AppKit
import ApplicationServices
import Foundation

/// Finds the owner's Claude Code session (a Warp, Terminal or iTerm window whose visible text
/// shows Claude Code's UI) and acts on it. Everything read from the terminal is used for the one
/// command that asked for it and is never logged or stored.
@MainActor
final class RioClaudeCodeSession {
    static let shared = RioClaudeCodeSession()

    private struct Found {
        let candidate: RioClaudeCandidate
        let app: NSRunningApplication
        let window: AXUIElement
    }

    enum Message {
        static let needsAccessibility = "I need Accessibility permission to work with Claude Code. You can allow it in System Settings, Privacy and Security."
        static let notFound = "I couldn't find a Claude Code session in Warp, Terminal or iTerm."
        static let noPrompt = "Claude Code isn't asking for anything right now."
        static let waitingForPermission = "Claude is waiting for permission. Say approve that or deny that first."
        static let badPrompt = "I can only send plain prompts, not ones that start with a slash or an exclamation mark."
        static let couldntFocus = "I couldn't bring that terminal forward."
        static let changed = "That window changed, so I didn't press anything."
        static let standingOnly = "Claude is only offering a standing permission here, so please answer it yourself."
        static let noDeny = "I couldn't find a No option, so please answer it yourself."
        static let promptChanged = "That prompt changed, so I didn't approve it. Ask again."
        static let tooLong = "That request is too long for me to show you in full, so please approve it in the terminal yourself."
        static let notClaudePane = "The pane in front isn't Claude Code, so I didn't type anything."
    }

    /// How long a confirmed prompt may wait before the approval is refused.
    private static let confirmationLifetime: TimeInterval = 90
    private static let screenLines = 80
    private var confirmed: (fingerprint: String, date: Date)?

    // MARK: Reading

    /// The last screenful of the chosen Claude Code window, or nil when there is no session.
    func visibleScreen() -> String? {
        guard RioAX.isTrusted else { return nil }
        return pick(needingPrompt: false)?.candidate.text
    }

    /// What the confirmation panel shows for "approve that": the pending prompt itself. Remembers
    /// it, so the approval runs only against the prompt the owner saw. Nil when nothing is pending.
    func confirmationContent() -> RioConfirmationContent? {
        guard RioAX.isTrusted, let found = pick(needingPrompt: true),
              let prompt = RioClaudeScreen.permissionPrompt(in: found.candidate.text) else {
            confirmed = nil
            return nil
        }
        // Cut short, the panel can't show the whole request, so it can't be approved from here.
        guard prompt.isFullyShown else {
            confirmed = nil
            return RioConfirmationContent(
                title: "Too long to show in full. Approve it in the terminal.", detail: prompt.detail, confirmLabel: "OK"
            )
        }
        confirmed = (prompt.fingerprint, Date())
        return RioConfirmationContent(title: "Approve Claude Code's request?", detail: prompt.detail, confirmLabel: "Approve")
    }

    // MARK: Acting

    func send(_ text: String) async -> RioActionResult {
        guard RioAX.isTrusted else { return .failed(message: Message.needsAccessibility) }
        guard let prompt = RioClaudeSend.sanitise(text) else { return .failed(message: Message.badPrompt) }
        guard let found = pick(needingPrompt: false) else { return .failed(message: Message.notFound) }
        // Typing into a permission menu and pressing Return would answer it, so never do that.
        if RioClaudeScreen.permissionPrompt(in: found.candidate.text) != nil {
            return .failed(message: Message.waitingForPermission)
        }
        // Auto-accept / bypass mode: Claude Code may act without asking, so the owner confirms,
        // unless conversation mode's panel approved this very send a moment ago.
        if RioClaudeScreen.isAutoAcceptMode(found.candidate.text),
           !RioConfirmationCenter.shared.consumeRecentApproval(of: .claudeCode(.send(text))) {
            guard await RioConfirmationCenter.shared.confirm(.claudeCode(.send(prompt))) else { return .cancelled }
        }
        guard await focus(found) else { return .failed(message: Message.couldntFocus) }
        let fresh = Self.visibleText(of: found.window)
        guard RioClaudeScreen.looksLikeClaudeCode(fresh), RioClaudeScreen.permissionPrompt(in: fresh) == nil else {
            return .failed(message: Message.changed)
        }
        // The paste lands in the focused pane, so that pane itself must be Claude Code.
        guard RioClaudePaneCheck.allowsSend(
            focusedText: Self.focusedPaneText(of: found.app), windowText: fresh, paneCount: Self.paneCount(of: found.window)
        ) else {
            return .failed(message: Message.notClaudePane)
        }
        guard await RioAX.paste(prompt, into: found.app), isFrontmost(found.app), press("return") else {
            return .failed(message: Message.changed)
        }
        return .done(summary: "Sent to Claude Code")
    }

    func answer(approve: Bool) async -> RioActionResult {
        guard RioAX.isTrusted else { return .failed(message: Message.needsAccessibility) }
        guard let found = pick(needingPrompt: true),
              let prompt = RioClaudeScreen.permissionPrompt(in: found.candidate.text) else {
            return .failed(message: Message.noPrompt)
        }
        guard let key = approve ? prompt.approveKey : prompt.denyKey else {
            return .failed(message: approve ? Message.standingOnly : Message.noDeny)
        }
        if approve {
            guard prompt.isFullyShown else {
                confirmed = nil
                return .failed(message: Message.tooLong)
            }
            // Fails closed: without the owner's confirmation of this exact prompt, nothing is pressed.
            let ok = confirmed.map {
                $0.fingerprint == prompt.fingerprint && Date().timeIntervalSince($0.date) < Self.confirmationLifetime
            } ?? false
            confirmed = nil
            guard ok else { return .failed(message: Message.promptChanged) }
        }
        guard await focus(found) else { return .failed(message: Message.couldntFocus) }
        let fresh = Self.visibleText(of: found.window)
        guard RioClaudeScreen.permissionPrompt(in: fresh)?.fingerprint == prompt.fingerprint, isFrontmost(found.app) else {
            return .failed(message: Message.changed)
        }
        guard press(key) else { return .failed(message: Message.changed) }
        if prompt.options.isEmpty {
            // A y/n prompt may want Return after the letter; an extra Return in the input box is harmless.
            try? await Task.sleep(nanoseconds: 150_000_000)
            if isFrontmost(found.app) { _ = press("return") }
        }
        return .done(summary: approve ? "Approved" : "Denied")
    }

    // MARK: Windows

    private func pick(needingPrompt: Bool) -> Found? {
        let found = sessions()
        guard let candidate = RioClaudeSessionPicker.pick(found.map(\.candidate), needingPrompt: needingPrompt) else { return nil }
        return found.first { $0.candidate.id == candidate.id }
    }

    private func sessions() -> [Found] {
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var result = [Found]()
        var nextID = 0
        for app in NSWorkspace.shared.runningApplications {
            guard let bundle = app.bundleIdentifier, RioClaudeSessionPicker.terminalBundleIDs.contains(bundle) else { continue }
            let element = RioAX.appElement(app)
            guard let windows = RioAX.value(element, kAXWindowsAttribute as String) as? [AXUIElement] else { continue }
            let focused = RioAX.element(element, kAXFocusedWindowAttribute as String)
            for window in windows {
                let candidate = RioClaudeCandidate(
                    id: nextID,
                    text: Self.visibleText(of: window),
                    isFrontmostApp: app.processIdentifier == frontPID,
                    isFocusedWindow: focused.map { CFEqual($0, window) } ?? false
                )
                nextID += 1
                result.append(Found(candidate: candidate, app: app, window: window))
            }
        }
        return result
    }

    /// The text Accessibility shows for a terminal window: its text areas (never password
    /// fields), last screenful only.
    private static func visibleText(of window: AXUIElement) -> String {
        var parts = [String]()
        var budget = 300
        func walk(_ element: AXUIElement, depth: Int) {
            guard budget > 0, depth < 10 else { return }
            budget -= 1
            let role = RioAX.role(element)
            if role == "AXTextArea" || role == "AXStaticText" || role == "AXTextField",
               RioAX.string(element, kAXSubroleAttribute as String) != "AXSecureTextField",
               let value = RioAX.string(element, kAXValueAttribute as String), !value.isEmpty {
                parts.append(value)
            }
            if role == "AXTextArea" { return }
            for child in RioAX.children(element) { walk(child, depth: depth + 1) }
        }
        walk(window, depth: 0)
        return parts.joined(separator: "\n").components(separatedBy: .newlines).suffix(screenLines).joined(separator: "\n")
    }

    /// The focused element's own text (the pane that will receive the paste), last screenful only.
    private static func focusedPaneText(of app: NSRunningApplication) -> String? {
        guard let element = RioAX.focusedElement(of: app),
              RioAX.string(element, kAXSubroleAttribute as String) != "AXSecureTextField",
              let value = RioAX.string(element, kAXValueAttribute as String) else { return nil }
        return value.components(separatedBy: .newlines).suffix(screenLines).joined(separator: "\n")
    }

    /// How many terminal text areas (panes) the window holds.
    private static func paneCount(of window: AXUIElement) -> Int {
        var count = 0
        var budget = 300
        func walk(_ element: AXUIElement, depth: Int) {
            guard budget > 0, depth < 10 else { return }
            budget -= 1
            if RioAX.role(element) == "AXTextArea" {
                count += 1
                return
            }
            for child in RioAX.children(element) { walk(child, depth: depth + 1) }
        }
        walk(window, depth: 0)
        return count
    }

    private func focus(_ found: Found) async -> Bool {
        let app = found.app
        if app.isHidden { app.unhide() }
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        AXUIElementPerformAction(found.window, kAXRaiseAction as CFString)
        for _ in 0..<20 {
            if isFrontmost(app) {
                try? await Task.sleep(nanoseconds: 150_000_000)
                return isFrontmost(app)
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    private func isFrontmost(_ app: NSRunningApplication) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    private func press(_ key: String) -> Bool {
        RioKeyboard.post(KeyCombo(key: key, command: false, shift: false, option: false, control: false))
    }
}
