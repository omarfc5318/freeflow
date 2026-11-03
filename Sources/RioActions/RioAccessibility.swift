import AppKit
import ApplicationServices

/// Small Accessibility and pasteboard helpers for the context actions. Everything read through
/// here is used for the one command that asked for it and is never logged or stored.
@MainActor
enum RioAX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func appElement(_ app: NSRunningApplication) -> AXUIElement {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.6)
        return element
    }

    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let raw = value(element, attribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        (value(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }

    static func role(_ element: AXUIElement) -> String? {
        string(element, kAXRoleAttribute as String)
    }

    /// The app Rio should act on: the frontmost one, unless that is Rio itself.
    static func frontmostApp() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return app
    }

    static func focusedElement(of app: NSRunningApplication) -> AXUIElement? {
        element(appElement(app), kAXFocusedUIElementAttribute as String)
    }

    // MARK: Selection

    /// The selected text of the focused element, or nil when nothing is selected.
    static func axSelectedText(in app: NSRunningApplication) -> String? {
        guard let focused = focusedElement(of: app),
              let text = string(focused, kAXSelectedTextAttribute as String),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// Accessibility first; if the app doesn't expose its selection, a Command-C round trip
    /// with the user's clipboard restored afterwards.
    static func selectedText(in app: NSRunningApplication) async -> String? {
        if let text = axSelectedText(in: app) { return text }
        return await copiedSelection(from: app)
    }

    private static func copiedSelection(from app: NSRunningApplication) async -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = RioPasteboardSnapshot.capture(pasteboard)
        let before = pasteboard.changeCount
        postKey(keyCode: 8, flags: .maskCommand, to: app.processIdentifier)
        var copied: String?
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if pasteboard.changeCount != before {
                copied = pasteboard.string(forType: .string)
                break
            }
        }
        snapshot.restore(to: pasteboard)
        guard let copied, !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return copied
    }

    // MARK: Typing

    /// Pastes `text` into `app`'s focused field (replacing a selection), then puts the user's
    /// clipboard back. Returns false if the app is no longer frontmost.
    static func paste(_ text: String, into app: NSRunningApplication) async -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
        let pasteboard = NSPasteboard.general
        let snapshot = RioPasteboardSnapshot.capture(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Keep clipboard managers from recording the text.
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        postKey(keyCode: 9, flags: .maskCommand, to: app.processIdentifier)
        try? await Task.sleep(nanoseconds: 350_000_000)
        snapshot.restore(to: pasteboard)
        return true
    }

    static func pressSend(_ key: RioSendKey, in app: NSRunningApplication) {
        switch key {
        case .returnKey: postKey(keyCode: 36, flags: [], to: app.processIdentifier)
        case .commandShiftD: postKey(keyCode: 2, flags: [.maskCommand, .maskShift], to: app.processIdentifier)
        }
    }

    private static func postKey(keyCode: CGKeyCode, flags: CGEventFlags, to pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown)
            event?.flags = flags
            event?.postToPid(pid)
        }
    }
}

/// A copy of everything on the pasteboard so it can be put back after Rio borrows it.
struct RioPasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    @MainActor static func capture(_ pasteboard: NSPasteboard) -> RioPasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item -> [NSPasteboard.PasteboardType: Data] in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        }
        return RioPasteboardSnapshot(items: items)
    }

    @MainActor func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
