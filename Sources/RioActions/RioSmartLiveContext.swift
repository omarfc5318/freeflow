import AppKit
import ApplicationServices
import Foundation

/// Reads `RioSmartContext` on the Mac for the smart resolver: the front app and its focused
/// window title, running and installed app names. Nothing is logged or stored. Rio's own windows
/// are never described, and the title of a window Rio must not read (password managers,
/// permission prompts, privacy panes) is never sent (`RioSmartContextPolicy`).
@MainActor
final class RioSmartLiveContext: RioSmartContextProviding {
    func currentContext() async -> RioSmartContext {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }
            .compactMap(\.localizedName)
        var context = RioSmartContext(
            runningApps: running,
            installedApps: RioSmartContextPolicy.installedNames(RioInstalledApps.shared.cachedApps ?? [])
        )
        guard let front = RioAX.frontmostApp() else { return context }
        context.frontApp = front.localizedName
        context.frontWindowTitle = focusedWindowTitle(of: front)
        return context
    }

    private func focusedWindowTitle(of app: NSRunningApplication) -> String? {
        // The cheap check first: apps Rio never reads get no Accessibility call at all.
        guard RioAX.isTrusted, RioSmartContextPolicy.mayReadTitle(bundleID: app.bundleIdentifier) else { return nil }
        let element = RioAX.appElement(app)
        AXUIElementSetMessagingTimeout(element, 0.3)
        guard let window = RioAX.element(element, kAXFocusedWindowAttribute as String),
              let title = RioAX.string(window, kAXTitleAttribute as String) else { return nil }
        return RioSmartContextPolicy.shareableTitle(bundleID: app.bundleIdentifier, title: title)
    }
}
