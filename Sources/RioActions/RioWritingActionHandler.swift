import AppKit
import ApplicationServices
import Foundation

/// Where the writing actions read their switch. On by default, but nothing is sent until the
/// owner dictates one of the writing commands.
enum RioWritingSettings {
    static let enabledKey = "rio_writing_enabled"
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
}

/// What only AppState knows: the last dictation and how to replace it. Installed by
/// `AppState.installRioWritingHost()`; until then edit-last says it can't find a dictation.
@MainActor final class RioWritingHost {
    static let shared = RioWritingHost()
    var lastDictation: () -> RioWritingLastDictation? = { nil }
    var replaceLast: (_ expecting: String, _ with: String) async -> RioWritingReplaceOutcome = { _, _ in .unreadable }
    /// Builder N's style profile, once wired: a short description of how the owner writes.
    var styleHint: () -> String? = { nil }
}

/// Runs "make that more formal", "write for me ..." and "paste it translated". Returns nil for
/// every action that isn't its own.
@MainActor final class RioWritingActionHandler: RioActionHandling, RioWritingPlatform {
    static let shared = RioWritingActionHandler()

    private let llm: RioSmartLLMCompleting
    private let host: RioWritingHost

    init(
        llm: RioSmartLLMCompleting = RioSmartLLMClient(config: { RioSmartSettings.llmConfig() }),
        host: RioWritingHost? = nil
    ) {
        self.llm = llm
        self.host = host ?? RioWritingHost.shared
    }

    func handle(_ action: RioAction, executor: RioActionExecuting) async -> RioActionResult? {
        let flow = RioWritingFlow(platform: self, llm: llm)
        switch action {
        case .editLastDictation(let instruction): return await flow.editLast(instruction: instruction)
        case .writeForMe(let instruction): return await flow.writeForMe(instruction: instruction)
        case .smartPaste(let instruction): return await flow.smartPaste(instruction: instruction)
        default: return nil
        }
    }

    // MARK: RioWritingPlatform

    var isEnabled: Bool { RioWritingSettings.isEnabled }
    var isOnline: Bool { NetworkMonitor.shared.isOnline }
    var hasAccessibility: Bool { RioAX.isTrusted }
    var styleHint: String? { host.styleHint() }

    func lastDictation() -> RioWritingLastDictation? { host.lastDictation() }

    func replaceLastDictation(expecting original: String, with text: String) async -> RioWritingReplaceOutcome {
        await host.replaceLast(original, text)
    }

    /// Fails closed: with no app identity, no readable focused element or no readable role,
    /// there is no target (Rio can't rule out a password field it can't see).
    func focusedTarget() -> RioWritingTarget? {
        guard let app = RioAX.frontmostApp(), app.bundleIdentifier != nil,
              let focused = RioAX.focusedElement(of: app), let role = RioAX.role(focused) else { return nil }
        let subrole = RioAX.string(focused, kAXSubroleAttribute as String)
        let isSecure = role == "AXSecureTextField" || subrole == "AXSecureTextField"
        let isSingleLine = role == "AXTextField" || role == "AXComboBox" || subrole == "AXSearchField"
        return RioWritingTarget(
            bundleIdentifier: app.bundleIdentifier, appName: app.localizedName,
            isSingleLine: isSingleLine, isSecure: isSecure
        )
    }

    func type(_ text: String, into target: RioWritingTarget) async -> Bool {
        guard let app = RioAX.frontmostApp(), app.bundleIdentifier == target.bundleIdentifier else { return false }
        return await RioAX.paste(text, into: app)
    }

    func clipboardText() -> String? { NSPasteboard.general.string(forType: .string) }

    func captureClipboard() -> Any { RioPasteboardSnapshot.capture(NSPasteboard.general) }

    func setClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Keep clipboard managers from recording the transformed text.
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    }

    func sendPaste(into target: RioWritingTarget) async -> Bool {
        guard let app = RioAX.frontmostApp(), app.bundleIdentifier == target.bundleIdentifier else { return false }
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: isDown)
            event?.flags = .maskCommand
            event?.postToPid(app.processIdentifier)
        }
        return true
    }

    func settle() async { try? await Task.sleep(nanoseconds: 350_000_000) }

    func restoreClipboard(_ snapshot: Any) {
        (snapshot as? RioPasteboardSnapshot)?.restore(to: NSPasteboard.general)
    }
}
