import CoreGraphics

/// Where a Rio side panel (the help sheet) goes on the home screen: right of the corner bear,
/// on the bottom edge, and always wholly inside the screen's visible frame (finding 75). A panel
/// taller or wider than the screen is cut to fit rather than pushed off the top. Pure geometry.
enum RioPanelPlacement {
    /// `leftInset` is the room left for the bear from the visible frame's left edge.
    static func frame(size: CGSize, visible: CGRect, leftInset: CGFloat, margin: CGFloat) -> CGRect {
        let fitted = fittedSize(size, visible: visible, margin: margin)
        let x = min(visible.minX + leftInset, visible.maxX - fitted.width - margin)
        return CGRect(origin: CGPoint(x: max(x, visible.minX + margin), y: visible.minY + margin), size: fitted)
    }

    /// `frame` moved (and if need be shrunk) so every edge is inside `visible`.
    static func clamped(_ frame: CGRect, to visible: CGRect, margin: CGFloat) -> CGRect {
        let fitted = fittedSize(frame.size, visible: visible, margin: margin)
        let x = min(max(frame.minX, visible.minX + margin), visible.maxX - fitted.width - margin)
        let y = min(max(frame.minY, visible.minY + margin), visible.maxY - fitted.height - margin)
        return CGRect(origin: CGPoint(x: max(x, visible.minX), y: max(y, visible.minY)), size: fitted)
    }

    private static func fittedSize(_ size: CGSize, visible: CGRect, margin: CGFloat) -> CGSize {
        CGSize(
            width: max(0, min(size.width, visible.width - 2 * margin)),
            height: max(0, min(size.height, visible.height - 2 * margin))
        )
    }
}
