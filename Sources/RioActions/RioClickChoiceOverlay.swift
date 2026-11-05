import AppKit

/// The numbered badges Rio puts on matching controls when "click Send" fits more than one. Each
/// badge is a tiny click-through panel, hidden from screenshots like the bear, gone after a few
/// seconds or as soon as the user picks.
@MainActor
final class RioClickChoiceOverlay {
    static let shared = RioClickChoiceOverlay()

    private static let visibleSeconds: TimeInterval = 12
    private static let badgeSize: CGFloat = 26
    private var panels: [NSPanel] = []
    private var hideTimer: Timer?

    func show(frames: [CGRect]) {
        hide()
        // Accessibility frames have a top-left origin on the primary display; AppKit's is bottom-left.
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        for (offset, frame) in frames.enumerated() {
            let size = Self.badgeSize
            let origin = NSPoint(x: frame.minX - 4, y: primaryHeight - frame.minY - size + 4)
            let panel = NSPanel(
                contentRect: NSRect(origin: origin, size: NSSize(width: size, height: size)),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .statusBar
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.sharingType = RioCompanionPrivacy.sharingType
            panel.contentView = BadgeView(number: offset + 1, frame: NSRect(x: 0, y: 0, width: size, height: size))
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        hideTimer = RioMainTimer.schedule(interval: Self.visibleSeconds, repeats: false) { [weak self] in
            self?.hide()
        }
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }

    private final class BadgeView: NSView {
        private let number: Int

        init(number: Int, frame: NSRect) {
            self.number = number
            super.init(frame: frame)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { nil }

        override func draw(_ dirtyRect: NSRect) {
            let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            NSColor(calibratedRed: 0.96, green: 0.70, blue: 0.24, alpha: 1).setFill()
            circle.fill()
            NSColor(calibratedWhite: 0.12, alpha: 1).setStroke()
            circle.lineWidth = 2
            circle.stroke()
            let text = "\(number)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .heavy),
                .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1),
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
        }
    }
}
