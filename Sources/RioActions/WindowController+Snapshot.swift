import AppKit
import ApplicationServices
import Foundation

/// A window's place before Rio moved it, so undo can put it back. Holds the live Accessibility
/// element, so it only works while that window still exists.
struct RioWindowSnapshot {
    let appName: String
    fileprivate let window: AXUIElement
    /// Position and size in Accessibility coordinates (top-left origin on the main display).
    fileprivate let frame: CGRect
    fileprivate let wasMinimized: Bool
}

/// Reads and restores a window frame. Kept apart from `WindowController`'s private helpers on
/// purpose; it shares only the pure `WindowAppNameResolver`.
extension WindowController {
    private static let snapshotTimeout: Float = 1.5

    /// The frame of the window `command` is about to move, or nil when it can't be read (no
    /// Accessibility permission, app not running, no window).
    func captureSnapshot(for command: WindowCommand) -> RioWindowSnapshot? {
        guard AXIsProcessTrusted(), let app = snapshotApp(named: command.appName) else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, Self.snapshotTimeout)
        guard let window = snapshotWindow(of: appElement),
              let position = RioWindowSnapshotAX.point(window, kAXPositionAttribute),
              let size = RioWindowSnapshotAX.size(window, kAXSizeAttribute) else { return nil }
        return RioWindowSnapshot(
            appName: app.localizedName ?? command.appName ?? "that app",
            window: window,
            frame: CGRect(origin: position, size: size),
            wasMinimized: RioWindowSnapshotAX.bool(window, kAXMinimizedAttribute) ?? false
        )
    }

    /// Puts the window back where it was, un-minimizing or re-minimizing as needed.
    func restore(_ snapshot: RioWindowSnapshot) -> RioActionResult {
        guard AXIsProcessTrusted() else {
            return .failed(message: "Rio needs Accessibility permission to move windows")
        }
        AXUIElementSetMessagingTimeout(snapshot.window, Self.snapshotTimeout)
        guard RioWindowSnapshotAX.point(snapshot.window, kAXPositionAttribute) != nil else {
            return .failed(message: "That \(snapshot.appName) window is gone")
        }
        if snapshot.wasMinimized {
            _ = AXUIElementSetAttributeValue(snapshot.window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            return .done(summary: "Put the \(snapshot.appName) window back")
        }
        if RioWindowSnapshotAX.bool(snapshot.window, kAXMinimizedAttribute) == true {
            _ = AXUIElementSetAttributeValue(snapshot.window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        // Same order as moving: position, size, position again, because apps clamp a resize
        // against the screen the window starts on.
        let placed = RioWindowSnapshotAX.setPoint(snapshot.frame.origin, snapshot.window)
        _ = RioWindowSnapshotAX.setSize(snapshot.frame.size, snapshot.window)
        _ = RioWindowSnapshotAX.setPoint(snapshot.frame.origin, snapshot.window)
        _ = AXUIElementPerformAction(snapshot.window, kAXRaiseAction as CFString)
        return placed
            ? .done(summary: "Put the \(snapshot.appName) window back")
            : .failed(message: "I couldn't move the \(snapshot.appName) window back")
    }

    // MARK: Finding the app and window

    private func snapshotApp(named spoken: String?) -> NSRunningApplication? {
        guard let spoken, !spoken.trimmingCharacters(in: .whitespaces).isEmpty else {
            // The same app `apply` will move, so undo puts back the window that really moved.
            return Self.recentTarget() ?? NSWorkspace.shared.frontmostApplication
        }
        let candidates = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.localizedName != nil
        }
        let names = candidates.map { $0.localizedName ?? "" }
        guard let index = WindowAppNameResolver.bestMatchIndex(for: spoken, in: names) else { return nil }
        return candidates[index]
    }

    private func snapshotWindow(of app: AXUIElement) -> AXUIElement? {
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let window = RioWindowSnapshotAX.element(app, attribute) { return window }
        }
        guard let value = RioWindowSnapshotAX.copy(app, kAXWindowsAttribute), CFGetTypeID(value) == CFArrayGetTypeID() else {
            return nil
        }
        let windows = unsafeBitCast(value, to: CFArray.self)
        for index in 0..<CFArrayGetCount(windows) {
            guard let raw = CFArrayGetValueAtIndex(windows, index) else { continue }
            let element = unsafeBitCast(raw, to: AXUIElement.self)
            if RioWindowSnapshotAX.bool(element, kAXMinimizedAttribute) != true { return element }
        }
        return nil
    }
}

/// Minimal Accessibility attribute helpers for the snapshot code.
private enum RioWindowSnapshotAX {
    static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXValue.self)
    }

    static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var point = CGPoint.zero
        guard let value = axValue(element, attribute), AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var size = CGSize.zero
        guard let value = axValue(element, attribute), AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    static func setPoint(_ point: CGPoint, _ window: AXUIElement) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }

    static func setSize(_ size: CGSize, _ window: AXUIElement) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success
    }
}
