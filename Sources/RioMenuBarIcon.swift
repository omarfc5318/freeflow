import AppKit

/// Rio's head as a one-colour template image for the menu bar, so macOS tints it for light and
/// dark menu bars like any system icon. Ears and head are filled, then the eyes and muzzle are
/// punched out and the nose filled back in. While conversation mode is on he pricks his ears and
/// small sound waves show either side; during a call the waves give way to a pause sign.
enum RioMenuBarIcon {
    static let size = NSSize(width: 18, height: 18)
    /// Wider so the waves (or the pause sign) fit beside the head.
    static let wideSize = NSSize(width: 26, height: 18)

    static let templateImage: NSImage = make(size: size, description: "Rio Dictate") { _ in
        drawHead(center: NSPoint(x: 9, y: 8), earLift: 0)
    }

    /// Conversation mode is listening.
    static let listeningTemplateImage: NSImage = make(size: wideSize, description: "Rio Dictate, conversation mode listening") { _ in
        let center = NSPoint(x: 13, y: 7.6)
        drawHead(center: center, earLift: 1.1)
        NSColor.black.setStroke()
        for side in [-1.0, 1.0] as [CGFloat] {
            let arc = NSBezierPath()
            let start: CGFloat = side < 0 ? 152 : -28
            arc.appendArc(withCenter: center, radius: 10.6, startAngle: start, endAngle: start + 56)
            arc.lineWidth = 1.5
            arc.lineCapStyle = .round
            arc.stroke()
        }
    }

    /// Conversation mode is on but waiting out a call.
    static let pausedTemplateImage: NSImage = make(size: wideSize, description: "Rio Dictate, conversation mode paused for a call") { context in
        drawHead(center: NSPoint(x: 9, y: 8), earLift: 0)
        context.compositingOperation = .sourceOver
        NSColor.black.setFill()
        for x in [19.4, 22.6] as [CGFloat] {
            NSBezierPath(roundedRect: NSRect(x: x, y: 3.5, width: 2.2, height: 8.5), xRadius: 1.1, yRadius: 1.1).fill()
        }
    }

    private static func make(size: NSSize, description: String, draw: @escaping (NSGraphicsContext) -> Void) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current else { return false }
            draw(context)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }

    /// The head on the 18-point grid, centred on `center` (the default icon uses 9, 8).
    private static func drawHead(center: NSPoint, earLift: CGFloat) {
        guard let context = NSGraphicsContext.current else { return }
        let dx = center.x - 9
        let dy = center.y - 8
        func at(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x + dx, y: y + dy) }
        context.compositingOperation = .sourceOver
        NSColor.black.setFill()

        for (ear, spread) in [(at(4.3, 13.4), -earLift * 0.3), (at(13.7, 13.4), earLift * 0.3)] {
            circle(NSPoint(x: ear.x + spread, y: ear.y + earLift), radius: 3.1).fill()
        }
        circle(center, radius: 7.2).fill()

        context.compositingOperation = .destinationOut
        for eye in [at(6.3, 9.7), at(11.7, 9.7)] {
            circle(eye, radius: 1.1).fill()
        }
        NSBezierPath(ovalIn: NSRect(x: 5.8 + dx, y: 2.9 + dy, width: 6.4, height: 4.7)).fill()

        context.compositingOperation = .sourceOver
        NSBezierPath(ovalIn: NSRect(x: 7.7 + dx, y: 5.2 + dy, width: 2.6, height: 1.8)).fill()
    }

    private static func circle(_ center: NSPoint, radius: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }
}
