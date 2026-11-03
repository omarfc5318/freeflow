import CoreGraphics
import Foundation

/// One display. Both rects are in AppKit coordinates (origin at the bottom-left of the main
/// display, y up). `visibleFrame` already excludes the menu bar and the Dock.
struct ScreenInfo: Equatable {
    let frame: CGRect
    let visibleFrame: CGRect
}

/// Pure window-placement math. No AppKit and no Accessibility calls, so it can be tested on
/// synthetic displays. Everything is computed in AppKit coordinates; the Accessibility API
/// uses a top-left origin on the main display, so convert at the edges with `axRect` and
/// `appKitRect`.
enum WindowGeometry {
    // MARK: Coordinate conversion

    /// AX (origin top-left of the main display, y down) to AppKit (origin bottom-left, y up).
    /// The flip is its own inverse, so `axRect` is the same formula.
    static func appKitRect(fromAX rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        flipped(rect, primaryScreenHeight: primaryScreenHeight)
    }

    static func axRect(fromAppKit rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        flipped(rect, primaryScreenHeight: primaryScreenHeight)
    }

    private static func flipped(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryScreenHeight - (rect.origin.y + rect.height),
            width: rect.width,
            height: rect.height
        )
    }

    // MARK: Screens

    /// The display a window mostly sits on: largest overlap, else the nearest display.
    static func screenIndex(containing window: CGRect, in screens: [ScreenInfo]) -> Int? {
        guard !screens.isEmpty else { return nil }
        var best: (index: Int, area: CGFloat)?
        for (index, screen) in screens.enumerated() {
            let overlap = window.intersection(screen.frame)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > (best?.area ?? 0) { best = (index, area) }
        }
        if let best { return best.index }
        let center = CGPoint(x: window.midX, y: window.midY)
        return screens.indices.min { distance(from: center, to: screens[$0].frame) < distance(from: center, to: screens[$1].frame) }
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Displays left to right, ties broken bottom to top, then by original index.
    static func orderedScreenIndices(_ screens: [ScreenInfo]) -> [Int] {
        screens.indices.sorted { a, b in
            let fa = screens[a].frame, fb = screens[b].frame
            if fa.minX != fb.minX { return fa.minX < fb.minX }
            if fa.minY != fb.minY { return fa.minY < fb.minY }
            return a < b
        }
    }

    /// The display after `index` in `orderedScreenIndices`, wrapping around; nil with fewer
    /// than two displays.
    static func nextScreenIndex(after index: Int, in screens: [ScreenInfo]) -> Int? {
        guard screens.count > 1 else { return nil }
        let order = orderedScreenIndices(screens)
        guard let position = order.firstIndex(of: index) else { return nil }
        return order[(position + 1) % order.count]
    }

    // MARK: Frames

    /// Where `window` should go for `placement`, in AppKit coordinates. Nil when there is
    /// nothing to set: minimize has no frame, and nextScreen needs a second display.
    static func targetFrame(for placement: WindowPlacement, window: CGRect, screens: [ScreenInfo]) -> CGRect? {
        guard let index = screenIndex(containing: window, in: screens) else { return nil }
        let visible = screens[index].visibleFrame
        switch placement {
        case .leftHalf:
            let width = (visible.width / 2).rounded(.down)
            return CGRect(x: visible.minX, y: visible.minY, width: width, height: visible.height)
        case .rightHalf:
            let left = (visible.width / 2).rounded(.down)
            return CGRect(x: visible.minX + left, y: visible.minY, width: visible.width - left, height: visible.height)
        case .bottomHalf:
            let height = (visible.height / 2).rounded(.down)
            return CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: height)
        case .topHalf:
            let bottom = (visible.height / 2).rounded(.down)
            return CGRect(x: visible.minX, y: visible.minY + bottom, width: visible.width, height: visible.height - bottom)
        case .maximize:
            return visible
        case .center:
            let width = min(window.width, visible.width)
            let height = min(window.height, visible.height)
            return CGRect(
                x: visible.minX + ((visible.width - width) / 2).rounded(.down),
                y: visible.minY + ((visible.height - height) / 2).rounded(.down),
                width: width,
                height: height
            )
        case .minimize:
            return nil
        case .nextScreen:
            guard let next = nextScreenIndex(after: index, in: screens) else { return nil }
            return relativeFrame(of: window, from: visible, to: screens[next].visibleFrame)
        }
    }

    /// Same relative position and size on another display's visible area, clamped inside it.
    private static func relativeFrame(of window: CGRect, from source: CGRect, to destination: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return destination }
        let width = min((window.width / source.width * destination.width).rounded(), destination.width)
        let height = min((window.height / source.height * destination.height).rounded(), destination.height)
        let rawX = destination.minX + ((window.minX - source.minX) / source.width * destination.width).rounded()
        let rawY = destination.minY + ((window.minY - source.minY) / source.height * destination.height).rounded()
        let x = min(max(rawX, destination.minX), destination.maxX - width)
        let y = min(max(rawY, destination.minY), destination.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: Wording

    /// Short, user-facing line for the pill and history.
    static func summary(for placement: WindowPlacement, appName: String) -> String {
        switch placement {
        case .leftHalf: return "Moved \(appName) to the left"
        case .rightHalf: return "Moved \(appName) to the right"
        case .topHalf: return "Moved \(appName) to the top"
        case .bottomHalf: return "Moved \(appName) to the bottom"
        case .maximize: return "Maximized \(appName)"
        case .center: return "Centered \(appName)"
        case .minimize: return "Minimized \(appName)"
        case .nextScreen: return "Moved \(appName) to the other screen"
        }
    }
}
