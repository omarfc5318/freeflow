import AppKit
import ApplicationServices

/// Finds an app's icon in the Dock through the Dock's Accessibility tree (`com.apple.dock` →
/// AXList → AXDockItem). The tree is read in the background and cached: a run only ever uses
/// the cache, so it can never wait on the Dock. Read-only; needs the Accessibility permission
/// Rio already has, and asks for nothing (no prompt) when it is missing.
@MainActor
final class RioDockLocator {
    private var snapshot: DockSnapshot?
    private var preferences = DockPreferences(orientation: nil, autohide: false)
    private var isRefreshing = false

    /// Re-reads the Dock's settings and icons in the background.
    func refresh() {
        preferences = Self.readPreferences()
        guard preferences.allowsRun, !isRefreshing else { return }
        isRefreshing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = Self.readItems()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isRefreshing = false
                    self.snapshot = items.isEmpty ? nil : DockSnapshot(items: items, takenAt: RioCompanionClock.now)
                }
            }
        }
    }

    /// The application icon the owner just clicked (AX coordinates), from the last snapshot even
    /// if it is a little old: icons only move when the Dock changes, which triggers a refresh.
    func clickedAppURL(atAX point: CGPoint) -> URL? {
        preferences = Self.readPreferences()
        guard preferences.allowsRun, let snapshot,
              let item = DockClickHitTest.appItem(atAX: point, items: snapshot.items),
              let string = item.urlString else { return nil }
        return URL(string: string)
    }

    /// The icon for `appURL`, from the cache only; nil when the Dock can't be run to.
    /// `allowStale` is for the owner's own Dock clicks, where the icon was just hit-tested.
    func target(for appURL: URL, primaryScreen: CGRect, allowStale: Bool = false) -> DockRunTarget? {
        preferences = Self.readPreferences()
        guard preferences.allowsRun, let snapshot, allowStale || snapshot.isFresh(at: RioCompanionClock.now),
              let item = DockItemMatcher.match(snapshot.items, appURL: appURL) else { return nil }
        return DockRunGeometry.target(iconFrameAX: item.frame, primaryScreen: primaryScreen)
    }

    private static func readPreferences() -> DockPreferences {
        let defaults = UserDefaults(suiteName: "com.apple.dock")
        return DockPreferences(
            orientation: defaults?.string(forKey: "orientation"),
            autohide: defaults?.bool(forKey: "autohide") ?? false
        )
    }

    // MARK: Accessibility (background thread)

    nonisolated private static func readItems() -> [DockItemSnapshot] {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [] }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.3)
        guard let lists = attribute(root, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        var items: [DockItemSnapshot] = []
        for list in lists where (attribute(list, kAXRoleAttribute) as? String) == kAXListRole as String {
            guard let children = attribute(list, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for child in children {
                guard let frame = frame(of: child) else { continue }
                let url = attribute(child, "AXURL")
                let urlString = (url as? URL)?.absoluteString ?? (url as? NSURL)?.absoluteString
                items.append(DockItemSnapshot(
                    title: (attribute(child, kAXTitleAttribute) as? String) ?? "",
                    urlString: urlString,
                    subrole: attribute(child, kAXSubroleAttribute) as? String,
                    frame: frame
                ))
            }
        }
        return items
    }

    nonisolated private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    nonisolated private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}

enum RioCompanionClock {
    static var now: TimeInterval { Date().timeIntervalSinceReferenceDate }
}
