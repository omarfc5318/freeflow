import SwiftUI

// MARK: - Palette

/// Flat sticker colours. Every shape gets a very dark brown rim, so the bear reads on the
/// black recording pill and on any colourful desktop.
enum TeddyPalette {
    static let ink = Color(red: 0.12, green: 0.065, blue: 0.04)
    static let fur = Color(red: 0.60, green: 0.39, blue: 0.22)
    static let tan = Color(red: 0.89, green: 0.73, blue: 0.52)
    static let blush = Color(red: 0.93, green: 0.50, blue: 0.45)
    static let tongue = Color(red: 0.94, green: 0.48, blue: 0.50)

    static let hoodie = Color(red: 0.55, green: 0.34, blue: 0.84)
    static let hoodieDark = Color(red: 0.39, green: 0.22, blue: 0.66)
    static let hoodiePocket = Color(red: 0.49, green: 0.29, blue: 0.78)
    static let cord = Color(red: 0.97, green: 0.94, blue: 0.86)
    static let jeans = Color(red: 0.25, green: 0.44, blue: 0.76)
    static let jeansDark = Color(red: 0.15, green: 0.28, blue: 0.52)
    static let sneaker = Color(red: 0.98, green: 0.98, blue: 0.98)
    static let sole = Color(red: 0.76, green: 0.78, blue: 0.82)

    static let suit = Color(red: 0.34, green: 0.35, blue: 0.40)
    static let suitDark = Color(red: 0.22, green: 0.23, blue: 0.27)
    static let suitLight = Color(red: 0.45, green: 0.46, blue: 0.51)
    static let waistcoat = Color(red: 0.17, green: 0.18, blue: 0.22)
    static let tweed = Color(red: 0.47, green: 0.43, blue: 0.38)
    static let tweedDark = Color(red: 0.33, green: 0.30, blue: 0.27)
    static let shirt = Color(red: 0.98, green: 0.97, blue: 0.94)
    static let tie = Color(red: 0.45, green: 0.11, blue: 0.16)
    static let gold = Color(red: 0.93, green: 0.74, blue: 0.24)
    static let shoe = Color(red: 0.14, green: 0.13, blue: 0.15)

    static let silver = Color(red: 0.84, green: 0.85, blue: 0.88)
    static let steel = Color(red: 0.36, green: 0.38, blue: 0.43)
    static let pencilYellow = Color(red: 0.98, green: 0.80, blue: 0.22)
    static let eraserPink = Color(red: 0.97, green: 0.60, blue: 0.68)
    static let buttonRed = Color(red: 0.90, green: 0.14, blue: 0.16)
    static let sweat = Color(red: 0.55, green: 0.80, blue: 0.97)
}

// MARK: - Artwork

/// Flat cutout drawing: brown teddy, solid colours, a dark rim around every shape, no gradients.
/// The pill bear and the full-body teddy share `drawHead`, so the face always matches.
enum TeddyArt {
    static let outline: CGFloat = 1.1

    static func isBlinking(at time: TimeInterval) -> Bool {
        time.truncatingRemainder(dividingBy: 3.6) < 0.13
    }

    // MARK: Talking bear

    /// On a 44 x 32 grid: head, outfit at head scale, and a microphone (a pencil and round
    /// glasses while editing).
    static func drawTalkingBear(
        in graphics: inout GraphicsContext,
        time: TimeInterval,
        level: CGFloat,
        mood: TalkingBearView.Mood,
        isEditing: Bool = false,
        outfit: TeddyOutfit = .hoodie
    ) {
        // Syllable flutter so a steady level still reads as speech.
        let flutter = 0.7 + 0.3 * CGFloat(abs(sin(time * 11)))
        let open = level > 0.04 ? min(1, level * 1.6) * flutter : 0
        graphics.translateBy(x: 0, y: -open * 0.9)

        let face = TeddyFace(
            mouthOpen: open,
            isBlinking: mood != .thinking && isBlinking(at: time),
            isThinking: mood == .thinking,
            glasses: isEditing
        )
        drawHead(in: &graphics, face: face, outfit: outfit, neckwear: true)
        if isEditing {
            drawPencil(in: &graphics, outfit: outfit)
        } else {
            drawMicrophone(in: &graphics, outfit: outfit)
        }

        switch mood {
        case .talking:
            drawSoundArcs(in: &graphics, time: time, strength: open)
        case .thinking:
            drawThoughtDots(in: &graphics, time: time)
        case .idle:
            break
        }
    }

    // MARK: Props held in the pill

    /// A sleeve stub reaching in to a paw at `paw`, with a cuff band just behind the paw.
    static func drawSleeveStub(
        in graphics: inout GraphicsContext,
        outfit: TeddyOutfit,
        from start: CGPoint,
        to paw: CGPoint,
        width: CGFloat = 5.2
    ) {
        var path = Path()
        path.move(to: start)
        path.addLine(to: paw)
        stroke(&graphics, path, TeddyPalette.ink, width: width + outline * 2)
        stroke(&graphics, path, outfit == .suit ? TeddyPalette.suit : TeddyPalette.hoodie, width: width)
        let dx = paw.x - start.x
        let dy = paw.y - start.y
        let length = max(0.001, (dx * dx + dy * dy).squareRoot())
        var cuff = Path()
        cuff.move(to: CGPoint(x: paw.x - dx / length * 3.6, y: paw.y - dy / length * 3.6))
        cuff.addLine(to: CGPoint(x: paw.x - dx / length * 2.0, y: paw.y - dy / length * 2.0))
        let cuffColor = outfit == .suit ? TeddyPalette.shirt : TeddyPalette.hoodieDark
        graphics.stroke(cuff, with: .color(cuffColor), style: StrokeStyle(lineWidth: width, lineCap: .butt))
    }

    static func drawMicrophone(in graphics: inout GraphicsContext, outfit: TeddyOutfit = .hoodie) {
        // Handle, outlined, running down and out from the mic head.
        var handle = Path()
        handle.move(to: CGPoint(x: 30.6, y: 26))
        handle.addLine(to: CGPoint(x: 33.8, y: 31))
        stroke(&graphics, handle, TeddyPalette.ink, width: 3.8)
        stroke(&graphics, handle, TeddyPalette.steel, width: 2.2)

        drawSleeveStub(in: &graphics, outfit: outfit, from: CGPoint(x: 35.6, y: 33.6), to: CGPoint(x: 32.2, y: 29.2))

        // Head with a cross-hatched grille.
        let head = circle(CGPoint(x: 29.3, y: 23.4), 3.4)
        fill(&graphics, head, TeddyPalette.silver)
        var grille = graphics
        grille.clip(to: head)
        var lines = Path()
        for offset in stride(from: -4.0, through: 4.0, by: 2.0) {
            lines.move(to: CGPoint(x: 25.3 + offset, y: 19.4))
            lines.addLine(to: CGPoint(x: 33.3 + offset, y: 27.4))
            lines.move(to: CGPoint(x: 33.3 + offset, y: 19.4))
            lines.addLine(to: CGPoint(x: 25.3 + offset, y: 27.4))
        }
        grille.stroke(lines, with: .color(TeddyPalette.steel), lineWidth: 0.55)
        graphics.stroke(head, with: .color(TeddyPalette.ink), lineWidth: outline)

        // Paw wrapped around the handle.
        let paw = circle(CGPoint(x: 31.9, y: 28.4), 2.4)
        sticker(&graphics, paw, TeddyPalette.fur, rim: outline * 0.9)
    }

    /// Edit mode: a pencil held in the same paw, eraser end up.
    static func drawPencil(in graphics: inout GraphicsContext, outfit: TeddyOutfit = .hoodie) {
        var pencil = graphics
        pencil.translateBy(x: 27.8, y: 31.2)
        pencil.rotate(by: .radians(-0.98))
        drawPencilShape(in: &pencil, length: 15)
        drawSleeveStub(in: &graphics, outfit: outfit, from: CGPoint(x: 35.6, y: 33.6), to: CGPoint(x: 32.2, y: 29.2))
        sticker(&graphics, circle(CGPoint(x: 31.9, y: 28.2), 2.5), TeddyPalette.fur, rim: outline * 0.9)
    }

    /// A pencil lying along +x with its tip at the origin.
    static func drawPencilShape(in graphics: inout GraphicsContext, length: CGFloat) {
        let half: CGFloat = 1.45
        let rimRect = CGRect(x: -0.6, y: -half - outline, width: length + 1.2, height: half * 2 + outline * 2)
        fill(&graphics, Path(roundedRect: rimRect, cornerRadius: 1.2), TeddyPalette.ink)
        var tip = Path()
        tip.move(to: CGPoint(x: 0, y: 0))
        tip.addLine(to: CGPoint(x: 3.2, y: -half))
        tip.addLine(to: CGPoint(x: 3.2, y: half))
        tip.closeSubpath()
        fill(&graphics, tip, TeddyPalette.tan)
        var lead = Path()
        lead.move(to: CGPoint(x: 0, y: 0))
        lead.addLine(to: CGPoint(x: 1.2, y: -0.55))
        lead.addLine(to: CGPoint(x: 1.2, y: 0.55))
        lead.closeSubpath()
        fill(&graphics, lead, TeddyPalette.ink)
        fill(&graphics, Path(CGRect(x: 3.2, y: -half, width: length - 6.4, height: half * 2)), TeddyPalette.pencilYellow)
        fill(&graphics, Path(CGRect(x: 3.2, y: -0.1, width: length - 6.4, height: 0.5)), Color(red: 0.88, green: 0.62, blue: 0.1))
        fill(&graphics, Path(CGRect(x: length - 3.2, y: -half, width: 1.3, height: half * 2)), TeddyPalette.silver)
        fill(&graphics, Path(roundedRect: CGRect(x: length - 1.9, y: -half, width: 1.9, height: half * 2), cornerRadius: 0.9), TeddyPalette.eraserPink)
    }

    static func drawSoundArcs(in graphics: inout GraphicsContext, time: TimeInterval, strength: CGFloat) {
        let center = CGPoint(x: 29.3, y: 23.4)
        for index in 0..<3 {
            let ripple = 0.55 + 0.45 * sin(time * 9 - Double(index) * 1.2)
            let alpha = max(0, min(1, strength * 2.2 - CGFloat(index) * 0.35)) * CGFloat(ripple)
            guard alpha > 0.02 else { continue }
            var arc = Path()
            arc.addArc(
                center: center,
                radius: 6.5 + CGFloat(index) * 3,
                startAngle: .degrees(-58),
                endAngle: .degrees(8),
                clockwise: false
            )
            graphics.stroke(
                arc,
                with: .color(.white.opacity(Double(alpha))),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
            )
        }
    }

    static func drawThoughtDots(in graphics: inout GraphicsContext, time: TimeInterval) {
        let dots: [(CGPoint, CGFloat)] = [
            (CGPoint(x: 31, y: 10.5), 1.2), (CGPoint(x: 35.2, y: 7.5), 1.6), (CGPoint(x: 40, y: 4.5), 2.1),
        ]
        for (index, dot) in dots.enumerated() {
            let pulse = 0.35 + 0.65 * max(0, sin(time * 5 - Double(index) * 0.9))
            fill(&graphics, circle(dot.0, dot.1), .white.opacity(pulse))
        }
    }

    // MARK: Helpers

    static func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    static func fill(_ graphics: inout GraphicsContext, _ path: Path, _ color: Color) {
        graphics.fill(path, with: .color(color))
    }

    static func stroke(_ graphics: inout GraphicsContext, _ path: Path, _ color: Color, width: CGFloat, cap: CGLineCap = .round) {
        graphics.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: cap, lineJoin: .round))
    }

    /// Fill plus the dark rim, the basic "sticker" shape.
    static func sticker(_ graphics: inout GraphicsContext, _ path: Path, _ color: Color, rim: CGFloat = outline) {
        graphics.fill(path, with: .color(color))
        graphics.stroke(path, with: .color(TeddyPalette.ink), style: StrokeStyle(lineWidth: rim, lineJoin: .round))
    }
}
