import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// What the recorder reads from Accessibility at the moment of a click or key press. These are
/// plain synchronous calls with no state, so they run inside the event monitor before the screen
/// has a chance to change.
enum RioMacroProbe {
    static func click(at point: CGPoint) -> (label: String?, isSecure: Bool) {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element) == .success,
              var current = element else { return (nil, false) }
        var hops = 0
        while hops < 3 {
            let role = text(current, kAXRoleAttribute)
            let subrole = text(current, kAXSubroleAttribute)
            if role == "AXSecureTextField" || subrole == "AXSecureTextField" { return (nil, true) }
            if let label = text(current, kAXTitleAttribute) ?? text(current, kAXDescriptionAttribute)
                ?? (role == "AXTextField" ? nil : shortValue(current)) { return (label, false) }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = unsafeBitCast(parent, to: AXUIElement.self)
            hops += 1
        }
        return (nil, false)
    }

    /// True while a password field has focus or the system has secure keyboard input switched on.
    static func isSecureInputActive() -> Bool {
        if IsSecureEventInputEnabled() { return true }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let field = unsafeBitCast(focused, to: AXUIElement.self)
        return text(field, kAXSubroleAttribute) == "AXSecureTextField" || text(field, kAXRoleAttribute) == "AXSecureTextField"
    }

    private static func text(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func shortValue(_ element: AXUIElement) -> String? {
        guard let value = text(element, kAXValueAttribute), value.count <= 40 else { return nil }
        return value
    }
}

/// "Watch me": records app switches, labelled clicks, allow-listed key combos and typed text as
/// closed-set `RioAction`s. Secure fields, secure keyboard input, password managers and system
/// password prompts record nothing (`RioMacroMapper`). Needs Accessibility; the key monitor also
/// needs Input Monitoring. Nothing recorded leaves the Mac. Publishes `isRecording` for the bear badge.
@MainActor
final class RioMacroRecorder: ObservableObject {
    static let shared = RioMacroRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var stepCount = 0
    /// False once a recording that ran too long stopped listening; the steps wait for "stop".
    @Published private(set) var isCapturing = false
    private(set) var name = ""
    private var actions: [RioAction] = []
    private var monitor: Any?
    private var appObserver: NSObjectProtocol?
    private var autoStopTask: Task<Void, Never>?
    /// Called when a recording stops listening on its own after `RioMacroMapper.maxRecordingSeconds`
    /// (for a spoken reminder to say "stop recording").
    var onAutoStop: (@MainActor (_ name: String, _ steps: Int) -> Void)?

    nonisolated private static let ownBundleID = Bundle.main.bundleIdentifier
    nonisolated private static let keyNames: [UInt16: String] = {
        var table: [UInt16: String] = [:]
        for key in KeyCombo.allowedKeys { if let code = RioKeyCodes.code(for: key) { table[code] = key } }
        return table
    }()

    /// False when already recording.
    func start(name: String) -> Bool {
        guard !isRecording else { return false }
        self.name = name
        actions = []
        stepCount = 0
        isRecording = true
        isCapturing = true
        RioMacroRecordingState.isRecording = true
        let limit = UInt64(RioMacroMapper.maxRecordingSeconds * 1_000_000_000)
        autoStopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: limit)
            guard !Task.isCancelled, let self, self.isCapturing else { return }
            self.endCapture()
            self.onAutoStop?(self.name, self.actions.count)
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .keyDown]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let front = NSWorkspace.shared.frontmostApplication
            let bundleID = front?.bundleIdentifier
            if bundleID == Self.ownBundleID { return }
            let kind: RioMacroEvent.Kind
            var secure = false
            if event.type == .leftMouseDown {
                let point = NSEvent.mouseLocation
                let height = NSScreen.screens.first?.frame.height ?? 0
                let probe = RioMacroProbe.click(at: CGPoint(x: point.x, y: height - point.y))
                kind = .click(label: probe.label)
                secure = probe.isSecure
            } else {
                let flags = event.modifierFlags
                let name = Self.keyNames[event.keyCode]
                let combo = name.map {
                    KeyCombo(key: $0, command: flags.contains(.command), shift: flags.contains(.shift),
                             option: flags.contains(.option), control: flags.contains(.control))
                }
                kind = .key(combo: combo, typed: event.characters)
                secure = RioMacroProbe.isSecureInputActive()
            }
            let recorded = RioMacroEvent(kind: kind, bundleID: bundleID, isSecureContext: secure)
            Task { @MainActor in self?.record(recorded) }
        }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Self.ownBundleID, let appName = app.localizedName else { return }
            let recorded = RioMacroEvent(kind: .appSwitch(name: appName), bundleID: app.bundleIdentifier, isSecureContext: false)
            Task { @MainActor in self?.record(recorded) }
        }
        return true
    }

    /// Ends the recording and returns what was seen (compacted). Empty when nothing was recorded.
    func stop() -> (name: String, steps: [RioAction]) {
        let result = (name: name, steps: RioMacroMapper.compact(actions))
        autoStopTask?.cancel()
        autoStopTask = nil
        endCapture()
        actions = []
        stepCount = 0
        isRecording = false
        RioMacroRecordingState.isRecording = false
        return result
    }

    /// Stops listening to keys, clicks and app switches; the steps so far are kept.
    private func endCapture() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        appObserver = nil
        isCapturing = false
    }

    private func record(_ event: RioMacroEvent) {
        guard isRecording, isCapturing, let action = RioMacroMapper.action(for: event) else { return }
        actions = RioMacroMapper.compact(actions + [action])
        stepCount = actions.count
    }
}
