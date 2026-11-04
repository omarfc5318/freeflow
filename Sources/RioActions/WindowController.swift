import AppKit
import ApplicationServices
import Foundation

/// Places another app's window with the Accessibility API. Rio already holds Accessibility
/// permission for pasting; this never prompts (it only checks `AXIsProcessTrusted`).
/// Frame math lives in the pure `WindowGeometry`; this type only reads and writes AX values.
@MainActor final class WindowController: WindowControlling {
    /// Longest an unresponsive app may block the main thread per AX call.
    private static let messagingTimeout: Float = 1.5

    init() {}

    func apply(_ command: WindowCommand) -> RioActionResult {
        guard AXIsProcessTrusted() else {
            return .failed(message: "Rio needs Accessibility permission to move windows")
        }
        let app: NSRunningApplication
        switch resolveApp(named: command.appName) {
        case .success(let resolved): app = resolved
        case .failure(let failure): return .failed(message: failure.message)
        }
        let appName = app.localizedName ?? command.appName ?? "that app"
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeout)
        guard let window = windowElement(of: appElement) else {
            return .failed(message: "\(appName) has no window to move")
        }
        if boolAttribute(window, "AXFullScreen") == true {
            return .failed(message: "\(appName) is in full screen")
        }
        if command.placement == .minimize {
            return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
                ? .done(summary: WindowGeometry.summary(for: .minimize, appName: appName))
                : .failed(message: "I couldn't minimize \(appName)")
        }
        if boolAttribute(window, kAXMinimizedAttribute) == true {
            _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        let result = place(window, placement: command.placement, appName: appName)
        // The window Rio just arranged stays the target of the next "this window".
        if case .done = result {
            RioRecentWindowTarget.shared.note(processIdentifier: app.processIdentifier, name: appName)
        }
        return result
    }

    // MARK: Placement

    private func place(_ window: AXUIElement, placement: WindowPlacement, appName: String) -> RioActionResult {
        let displays = NSScreen.screens
        guard let primary = displays.first else { return .failed(message: "I couldn't find a screen") }
        let screens = displays.map { ScreenInfo(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        let primaryHeight = primary.frame.height

        guard let position = pointAttribute(window, kAXPositionAttribute),
              let size = sizeAttribute(window, kAXSizeAttribute)
        else { return .failed(message: "I couldn't read \(appName)'s window") }
        let current = WindowGeometry.appKitRect(
            fromAX: CGRect(origin: position, size: size), primaryScreenHeight: primaryHeight
        )
        if placement == .nextScreen, screens.count < 2 {
            return .failed(message: "There's only one screen")
        }
        guard let target = WindowGeometry.targetFrame(for: placement, window: current, screens: screens) else {
            return .failed(message: "I couldn't place \(appName)'s window")
        }
        let axTarget = WindowGeometry.axRect(fromAppKit: target, primaryScreenHeight: primaryHeight)

        // Many apps clamp a resize against the screen the window is on when it starts, so set
        // position, then size, then position again.
        let sizeChanges = axTarget.size != size
        if sizeChanges, !isSettable(window, kAXSizeAttribute) {
            return .failed(message: "\(appName)'s window can't be resized")
        }
        guard setPosition(axTarget.origin, on: window) else {
            return .failed(message: "I couldn't move \(appName)'s window")
        }
        if sizeChanges {
            guard setSize(axTarget.size, on: window) else {
                return .failed(message: "\(appName)'s window can't be resized")
            }
            _ = setPosition(axTarget.origin, on: window)
        }
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        return .done(summary: WindowGeometry.summary(for: placement, appName: appName))
    }

    // MARK: Finding the app and window

    private struct AppLookupFailure: Error { let message: String }

    private func resolveApp(named spoken: String?) -> Result<NSRunningApplication, AppLookupFailure> {
        guard let spoken, !spoken.trimmingCharacters(in: .whitespaces).isEmpty else {
            if let recent = Self.recentTarget() { return .success(recent) }
            guard let front = NSWorkspace.shared.frontmostApplication else {
                return .failure(AppLookupFailure(message: "I couldn't tell which app to move"))
            }
            return .success(front)
        }
        let candidates = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.localizedName != nil
        }
        let names = candidates.map { $0.localizedName ?? "" }
        guard let index = WindowAppNameResolver.bestMatchIndex(for: spoken, in: names) else {
            return .failure(AppLookupFailure(message: "I couldn't find \(spoken) running"))
        }
        return .success(candidates[index])
    }

    /// The app Rio opened, switched to or arranged in the last few seconds, while it still runs
    /// visibly (`RioRecentWindowTarget`). Shared with the undo snapshot so both see one window.
    static func recentTarget(now: Date = Date()) -> NSRunningApplication? {
        guard let entry = RioRecentWindowTarget.shared.current(now: now, isUsable: { pid in
            guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
            return !app.isTerminated && !app.isHidden && app.activationPolicy == .regular
        }) else { return nil }
        return NSRunningApplication(processIdentifier: entry.processIdentifier)
    }

    private func windowElement(of app: AXUIElement) -> AXUIElement? {
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let window = elementAttribute(app, attribute) { return window }
        }
        guard let value = copyAttribute(app, kAXWindowsAttribute), CFGetTypeID(value) == CFArrayGetTypeID() else {
            return nil
        }
        let windows = unsafeBitCast(value, to: CFArray.self)
        for index in 0..<CFArrayGetCount(windows) {
            guard let raw = CFArrayGetValueAtIndex(windows, index) else { continue }
            let element = unsafeBitCast(raw, to: AXUIElement.self)
            if boolAttribute(element, kAXMinimizedAttribute) != true { return element }
        }
        return nil
    }

    // MARK: AX attribute helpers

    private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copyAttribute(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let value = copyAttribute(element, attribute), CFGetTypeID(value) == CFBooleanGetTypeID() else {
            return nil
        }
        return CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
    }

    private func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        guard let value = copyAttribute(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXValue.self)
    }

    private func pointAttribute(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var point = CGPoint.zero
        guard let value = axValue(element, attribute), AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeAttribute(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var size = CGSize.zero
        guard let value = axValue(element, attribute), AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    private func setPosition(_ point: CGPoint, on window: AXUIElement) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }

    private func setSize(_ size: CGSize, on window: AXUIElement) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success
    }
}
