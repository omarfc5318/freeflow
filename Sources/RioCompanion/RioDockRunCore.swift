import CoreGraphics
import Foundation

// MARK: - Run timing

/// The bear's sprint to a Dock icon and the punch. HARD RULE (owner, 2026-11-03): sprint plus
/// punch never exceeds `RioCompanionTiming.maxRunDuration`, however far the icon is: a longer
/// distance only makes him faster. `punch` fires at `impactTime`.
struct RioDockRunPlan: Equatable {
    /// The leap and the fist, after the sprint.
    static let punchDuration: TimeInterval = 0.12
    /// Fist lands this long after the leap starts.
    static let impactOffset: TimeInterval = 0.08
    /// The jog home afterwards; it never delays the app, which has already opened.
    static let returnDuration: TimeInterval = 0.45
    static let minSprint: TimeInterval = 0.10
    /// Leaves a margin under the 0.4 s ceiling for the punch.
    static let maxSprint: TimeInterval = RioCompanionTiming.maxRunDuration - punchDuration - 0.02
    /// Points per second he can run before the clamp makes him faster still.
    static let referenceSpeed: CGFloat = 3000
    /// Fraction of the track covered by the end of the sprint; the leap covers the rest.
    static let sprintShare: CGFloat = 0.9
    static let leapPeak: CGFloat = 12

    /// Points from the bear to the icon, sanitised to 0...1e6.
    let distance: CGFloat
    let sprintDuration: TimeInterval

    var punchDuration: TimeInterval { Self.punchDuration }
    var totalDuration: TimeInterval { sprintDuration + punchDuration }
    var impactTime: TimeInterval { sprintDuration + Self.impactOffset }

    static func make(distance rawDistance: CGFloat) -> RioDockRunPlan {
        let distance: CGFloat = rawDistance.isNaN ? 0 : min(max(rawDistance, 0), 1_000_000)
        let wanted = TimeInterval(distance / referenceSpeed)
        return RioDockRunPlan(distance: distance, sprintDuration: min(max(wanted, minSprint), maxSprint))
    }

    /// How far along the track (0...1) the bear is `elapsed` seconds into the run: accelerating
    /// through the sprint, then covering the last stretch in the leap.
    func runFraction(at elapsed: TimeInterval) -> CGFloat {
        if elapsed <= 0 { return 0 }
        if elapsed < sprintDuration {
            let s = CGFloat(elapsed / sprintDuration)
            return Self.sprintShare * (0.35 * s + 0.65 * s * s)
        }
        let p = CGFloat(min(1, (elapsed - sprintDuration) / punchDuration))
        return Self.sprintShare + (1 - Self.sprintShare) * p
    }

    /// Height above the ground: zero while sprinting, an arc during the leap.
    func leapHeight(at elapsed: TimeInterval) -> CGFloat {
        guard elapsed > sprintDuration else { return 0 }
        let p = min(1, (elapsed - sprintDuration) / punchDuration)
        return Self.leapPeak * CGFloat(sin(p * Double.pi))
    }

    func hasImpacted(at elapsed: TimeInterval) -> Bool {
        elapsed >= impactTime
    }
}

// MARK: - Dock items

/// One Dock icon as read from the Dock's Accessibility tree. `frame` is in Accessibility
/// coordinates (origin top left of the primary display, y down).
struct DockItemSnapshot: Equatable {
    let title: String
    let urlString: String?
    let subrole: String?
    let frame: CGRect
}

enum DockItemMatcher {
    static let applicationSubrole = "AXApplicationDockItem"

    /// The Dock item for an app. The item's URL must equal the app's path; an item without a
    /// URL falls back to an exact (case-insensitive) title match. Never fuzzy: a wrong icon is
    /// worse than none. Folders, the Trash and separators are skipped.
    static func match(_ items: [DockItemSnapshot], appURL: URL, appName: String? = nil) -> DockItemSnapshot? {
        let candidates = items.filter { $0.subrole == nil || $0.subrole == applicationSubrole }
        let wantedPath = normalizedPath(appURL.path)
        if let byURL = candidates.first(where: { item in
            guard let urlString = item.urlString, let url = URL(string: urlString) else { return false }
            return normalizedPath(url.path) == wantedPath
        }) {
            return byURL
        }
        let names = [appName, appURL.deletingPathExtension().lastPathComponent]
            .compactMap { $0 }
            .map(fold)
            .filter { !$0.isEmpty }
        return candidates.first { item in
            item.urlString == nil && names.contains(fold(item.title))
        }
    }

    private static func normalizedPath(_ path: String) -> String {
        var trimmed = (path as NSString).standardizingPath
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.lowercased()
    }

    private static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// The user's Dock settings that decide whether the bear can reach an icon at all.
struct DockPreferences: Equatable {
    /// "bottom", "left" or "right"; nil when never set (macOS then defaults to the bottom).
    let orientation: String?
    let autohide: Bool

    var allowsRun: Bool {
        !autohide && (orientation ?? "bottom") == "bottom"
    }
}

struct DockRunTarget: Equatable {
    /// Icon centre, in screen (Cocoa) x.
    let centerX: CGFloat
    /// The icon in Cocoa coordinates (origin bottom left of the primary display).
    let iconRect: CGRect
}

enum DockRunGeometry {
    /// Converts an Accessibility icon frame into Cocoa space. Nil unless the icon is on the
    /// primary display (where the bear lives) and in its bottom third, i.e. a bottom Dock.
    static func target(iconFrameAX frame: CGRect, primaryScreen: CGRect) -> DockRunTarget? {
        guard frame.width > 1, frame.height > 1, !frame.isNull, !frame.isInfinite else { return nil }
        let cocoa = CGRect(
            x: frame.minX,
            y: primaryScreen.minY + primaryScreen.height - frame.maxY,
            width: frame.width,
            height: frame.height
        )
        guard primaryScreen.contains(CGPoint(x: cocoa.midX, y: cocoa.midY)) else { return nil }
        guard cocoa.midY - primaryScreen.minY <= primaryScreen.height * 0.35 else { return nil }
        return DockRunTarget(centerX: cocoa.midX, iconRect: cocoa)
    }
}

/// The Dock's icons as last read. Reading the Dock's Accessibility tree can take a moment, so
/// it happens in the background and a run only ever uses this cache, never waiting on the Dock.
struct DockSnapshot: Equatable {
    static let timeToLive: TimeInterval = 60

    let items: [DockItemSnapshot]
    let takenAt: TimeInterval

    func isFresh(at now: TimeInterval) -> Bool {
        now >= takenAt && now - takenAt <= Self.timeToLive
    }
}

// MARK: - Corner layout

enum RioCompanionLayout {
    static let edgeInset: CGFloat = 14
    static let groundInset: CGFloat = 4

    /// Bottom-left corner of the bear's standing spot, in Cocoa screen coordinates: inset from
    /// the left edge (past a left-side Dock) and just above the bottom edge.
    static func anchor(screenFrame: CGRect, visibleFrame: CGRect) -> CGPoint {
        CGPoint(x: visibleFrame.minX + edgeInset, y: screenFrame.minY + groundInset)
    }
}

/// The owner's own Dock clicks (2026-11-03: "If I am clicking any apps on my taskbar, he will
/// run to that taskbar"). The click opens the app exactly as macOS always does; the bear only
/// runs over and punches the icon while it opens, so he never adds delay.
enum DockClickHitTest {
    /// A press and release this close together is a click, not a drag rearranging icons.
    static let maxClickTravel: CGFloat = 6

    /// The application icon under `point` (AX coordinates, top-left origin), never a folder,
    /// stack, the Trash or a separator.
    static func appItem(atAX point: CGPoint, items: [DockItemSnapshot]) -> DockItemSnapshot? {
        items.first { $0.subrole == DockItemMatcher.applicationSubrole && $0.frame.contains(point) && $0.urlString != nil }
    }

    static func isClick(down: CGPoint, up: CGPoint) -> Bool {
        hypot(up.x - down.x, up.y - down.y) <= maxClickTravel
    }

    /// AppKit global coordinates (bottom-left origin of the primary screen) to AX (top-left).
    static func axPoint(fromAppKit point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}
