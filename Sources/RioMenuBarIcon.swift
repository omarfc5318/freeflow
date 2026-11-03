import AppKit

/// Rio's head as a one-colour template image for the menu bar, so macOS tints it for light and
/// dark menu bars like any system icon. Ears and head are filled, then the eyes and muzzle are
/// punched out and the nose filled back in.
enum RioMenuBarIcon {
    static let size = NSSize(width: 18, height: 18)

    static let templateImage: NSImage = {
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current else { return false }
            NSColor.black.setFill()

            for ear in [NSPoint(x: 4.3, y: 13.4), NSPoint(x: 13.7, y: 13.4)] {
                circle(ear, radius: 3.1).fill()
            }
            circle(NSPoint(x: 9, y: 8), radius: 7.2).fill()

            context.compositingOperation = .destinationOut
            for eye in [NSPoint(x: 6.3, y: 9.7), NSPoint(x: 11.7, y: 9.7)] {
                circle(eye, radius: 1.1).fill()
            }
            NSBezierPath(ovalIn: NSRect(x: 5.8, y: 2.9, width: 6.4, height: 4.7)).fill()

            context.compositingOperation = .sourceOver
            NSBezierPath(ovalIn: NSRect(x: 7.7, y: 5.2, width: 2.6, height: 1.8)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Rio Dictate"
        return image
    }()

    private static func circle(_ center: NSPoint, radius: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }
}
