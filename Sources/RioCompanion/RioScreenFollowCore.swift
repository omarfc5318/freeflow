import CoreGraphics
import Foundation

// Pure logic for the corner bear following the owner to the screen they are working on.

/// A display: a stable id (the CGDirectDisplayID) and its frame in Cocoa space (origin at the
/// bottom left of the primary display, y up).
struct RioScreenInfo: Equatable {
    let id: Int
    let frame: CGRect
}

/// One row of `CGWindowListCopyWindowInfo`, reduced to what the choice needs. The list is
/// ordered front to back. `bounds` is in CG space (origin top left of the primary display, y
/// down). No window titles are ever read.
struct RioWindowEntry: Equatable {
    let pid: Int32
    let layer: Int
    let alpha: Double
    let bounds: CGRect
}

enum RioScreenFollow {
    /// The fade-out, move and fade-in together stay under 0.25 s.
    static let poofDuration: TimeInterval = 0.2
    /// The safety poll between activation notifications (and only with several displays).
    static let pollInterval: TimeInterval = 1.0
}

enum RioScreenChoice {
    /// Smallest side of a window that counts as a real, normal window (skips tiny helpers).
    static let minimumWindowSide: CGFloat = 50

    /// The frontmost normal window of `pid`: layer 0, visible, not tiny.
    static func frontmostWindowBounds(in entries: [RioWindowEntry], pid: Int32) -> CGRect? {
        entries.first { entry in
            entry.pid == pid && entry.layer == 0 && entry.alpha > 0
                && entry.bounds.width >= minimumWindowSide && entry.bounds.height >= minimumWindowSide
        }?.bounds
    }

    /// The display with the largest share of the window; with no usable window, the display
    /// under the mouse. `windowBounds` is in CG space, `mouse` in Cocoa space.
    static func screenID(windowBounds: CGRect?, mouse: CGPoint, screens: [RioScreenInfo], primaryHeight: CGFloat) -> Int? {
        if let bounds = windowBounds, bounds.width > 0, bounds.height > 0, !bounds.isNull, !bounds.isInfinite {
            let cocoa = CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            var best: (id: Int, area: CGFloat)?
            for screen in screens {
                let overlap = screen.frame.intersection(cocoa)
                guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
                let area = overlap.width * overlap.height
                if best == nil || area > best!.area { best = (screen.id, area) }
            }
            if let best { return best.id }
        }
        return screens.first { $0.frame.contains(mouse) }?.id
    }

    /// The display that carries the Dock. The Dock locator only reads icons on the primary
    /// display (the first screen), so that is the only one where a run can happen.
    static func dockScreenID(screens: [RioScreenInfo]) -> Int? { screens.first?.id }

    /// The bear may sprint to a Dock icon only from the Dock's screen. A bear not yet placed
    /// stands on the primary screen.
    static func canRunDockRun(bearScreen: Int?, screens: [RioScreenInfo]) -> Bool {
        guard let dock = dockScreenID(screens: screens) else { return false }
        return bearScreen == nil || bearScreen == dock
    }
}

/// Decides when the bear actually moves: a new screen must hold for `holdTime` before he
/// goes, and nothing moves while he is busy.
struct RioScreenFollowDebounce {
    static let holdTime: TimeInterval = 1.5

    private(set) var current: Int?
    private var pending: Int?
    private var pendingSince: TimeInterval = 0

    init(current: Int? = nil) { self.current = current }

    /// Returns the screen to move to now, or nil to stay. `now` is any monotonic clock.
    @discardableResult
    mutating func observe(target: Int?, now: TimeInterval, isBlocked: Bool) -> Int? {
        guard let target else {
            pending = nil
            return nil
        }
        guard let current else {
            guard !isBlocked else { return nil }
            self.current = target
            return target
        }
        if target == current {
            pending = nil
            return nil
        }
        if pending != target {
            pending = target
            pendingSince = now
            return nil
        }
        guard !isBlocked, now - pendingSince >= Self.holdTime else { return nil }
        pending = nil
        self.current = target
        return target
    }
}
