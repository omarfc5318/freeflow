import SwiftUI

// Art for the corner bear (Rio Actions): jeans details, a thobe/kurta body for the spoken looks,
// a hand-held microphone, a clenched fist, and the little effects around him (z z Z, thought
// dots, sound waves, "!", impact burst). Same flat sticker style: dark rim round every shape.
extension TeddyPalette {
    static let jeansCuff = Color(red: 0.40, green: 0.58, blue: 0.86)
    static let jeansStitch = Color(red: 0.96, green: 0.80, blue: 0.45)
    static let impact = Color(red: 1.0, green: 0.86, blue: 0.25)
    static let impactCore = Color(red: 1.0, green: 0.96, blue: 0.75)
}

extension TeddyArt {
    // MARK: Jeans

    /// Turn-up cuff and outer-seam stitching on a leg drawn as `path` (hip to ankle). The
    /// cuff is a lighter, slightly wider band with a darker fold line; the stitching is a
    /// short dashed seam down the outside of the leg.
    static func drawJeansDetail(in graphics: inout GraphicsContext, along path: Path, isLeft: Bool, isBack: Bool) {
        if !isBack {
            let outward: CGFloat = isLeft ? -2.0 : 2.0
            let seam = path.applying(CGAffineTransform(translationX: outward, y: 0)).trimmedPath(from: 0.05, to: 0.5)
            graphics.stroke(seam, with: .color(TeddyPalette.jeansStitch.opacity(0.9)),
                            style: StrokeStyle(lineWidth: 0.5, lineCap: .round, dash: [0.9, 0.8]))
        }
        let cuff = path.trimmedPath(from: 0.52, to: 0.80)
        stroke(&graphics, cuff, TeddyPalette.ink, width: 7.4 + outline * 2)
        stroke(&graphics, cuff, TeddyPalette.jeansCuff, width: 7.4)
        // Fold line along the top of the turn-up and a faint shadow under it.
        let fold = path.trimmedPath(from: 0.515, to: 0.55)
        stroke(&graphics, fold, TeddyPalette.jeansDark, width: 7.4, cap: .butt)
        let hem = path.trimmedPath(from: 0.77, to: 0.805)
        stroke(&graphics, hem, TeddyPalette.jeansDark.opacity(0.55), width: 7.4, cap: .butt)
    }

    // MARK: Spoken looks on the body

    /// A thobe (white) or kurta (cream): torso and a skirt down over the jeans, so only the
    /// sneakers show beneath the hem.
    static func drawFrontRobe(in graphics: inout GraphicsContext, look: SpokenLook) {
        let isThobe = look == .shemagh
        let cloth = isThobe ? TeddyPalette.thobe : TeddyPalette.kurta
        let shade = isThobe ? TeddyPalette.thobeShade : TeddyPalette.kurtaShade
        var robe = Path()
        robe.move(to: CGPoint(x: 20, y: 24.5))
        robe.addCurve(to: CGPoint(x: 28.6, y: 31.8), control1: CGPoint(x: 25, y: 24.5), control2: CGPoint(x: 28.6, y: 27.6))
        robe.addCurve(to: CGPoint(x: 30.2, y: 42.4), control1: CGPoint(x: 28.6, y: 35), control2: CGPoint(x: 30.2, y: 38.5))
        robe.addQuadCurve(to: CGPoint(x: 9.8, y: 42.4), control: CGPoint(x: 20, y: 44.2))
        robe.addCurve(to: CGPoint(x: 11.4, y: 31.8), control1: CGPoint(x: 9.8, y: 38.5), control2: CGPoint(x: 11.4, y: 35))
        robe.addCurve(to: CGPoint(x: 20, y: 24.5), control1: CGPoint(x: 11.4, y: 27.6), control2: CGPoint(x: 15, y: 24.5))
        robe.closeSubpath()
        fill(&graphics, robe, cloth)
        var inside = graphics
        inside.clip(to: robe)
        fill(&inside, Path(CGRect(x: 8, y: 40.2, width: 24, height: 5)), shade)
        var folds = Path()
        folds.move(to: CGPoint(x: 15.5, y: 33)); folds.addLine(to: CGPoint(x: 14.2, y: 41))
        folds.move(to: CGPoint(x: 24.5, y: 33)); folds.addLine(to: CGPoint(x: 25.8, y: 41))
        stroke(&inside, folds, shade, width: 0.6)
        graphics.stroke(robe, with: .color(TeddyPalette.ink), style: StrokeStyle(lineWidth: outline, lineJoin: .round))
    }

    // MARK: Paws and props

    /// A fur fist with three curled fingers on the side it punches towards.
    static func drawClenchedFist(in graphics: inout GraphicsContext, at center: CGPoint, direction: CGPoint) {
        sticker(&graphics, circle(center, 3.7), TeddyPalette.fur)
        let length = max(0.001, hypot(direction.x, direction.y))
        let d = CGPoint(x: direction.x / length, y: direction.y / length)
        let n = CGPoint(x: -d.y, y: d.x)
        var curls = Path()
        for offset in [-1.7, 0, 1.7] as [CGFloat] {
            let base = CGPoint(x: center.x + d.x * 0.9 + n.x * offset, y: center.y + d.y * 0.9 + n.y * offset)
            curls.move(to: base)
            curls.addLine(to: CGPoint(x: base.x + d.x * 1.9, y: base.y + d.y * 1.9))
        }
        stroke(&graphics, curls, TeddyPalette.ink, width: 0.75)
    }

    /// The bear's microphone: silver cross-hatched head on a steel handle, tipped towards his
    /// mouth, with the paw wrapped round the handle. `paw` is where the paw sits.
    static func drawHandheldMicrophone(in graphics: inout GraphicsContext, paw: CGPoint, tilt: Double = -0.5) {
        var mic = graphics
        mic.translateBy(x: paw.x, y: paw.y)
        mic.rotate(by: .radians(tilt))
        var handle = Path()
        handle.move(to: CGPoint(x: 0, y: 3.4))
        handle.addLine(to: CGPoint(x: 0, y: -2.0))
        stroke(&mic, handle, TeddyPalette.ink, width: 3.4 + outline * 2)
        stroke(&mic, handle, TeddyPalette.steel, width: 3.0)
        let head = circle(CGPoint(x: 0, y: -5.0), 3.5)
        fill(&mic, head, TeddyPalette.silver)
        var grille = mic
        grille.clip(to: head)
        var lines = Path()
        for offset in stride(from: -4.0, through: 4.0, by: 2.0) {
            lines.move(to: CGPoint(x: -4 + offset, y: -9)); lines.addLine(to: CGPoint(x: 4 + offset, y: -1))
            lines.move(to: CGPoint(x: 4 + offset, y: -9)); lines.addLine(to: CGPoint(x: -4 + offset, y: -1))
        }
        grille.stroke(lines, with: .color(TeddyPalette.steel), lineWidth: 0.55)
        mic.stroke(head, with: .color(TeddyPalette.ink), lineWidth: outline)
        sticker(&mic, circle(.zero, 3.0), TeddyPalette.fur, rim: outline * 0.9)
    }

    // MARK: Effects (body grid; sticker-outlined so they read on any desktop)

    /// A "Z" drawn from three strokes: dark rim, white fill.
    static func drawZee(in graphics: inout GraphicsContext, at center: CGPoint, size: CGFloat, opacity: Double) {
        guard opacity > 0.02 else { return }
        var z = Path()
        z.move(to: CGPoint(x: center.x - size / 2, y: center.y - size / 2))
        z.addLine(to: CGPoint(x: center.x + size / 2, y: center.y - size / 2))
        z.addLine(to: CGPoint(x: center.x - size / 2, y: center.y + size / 2))
        z.addLine(to: CGPoint(x: center.x + size / 2, y: center.y + size / 2))
        var layer = graphics
        layer.opacity = opacity
        stroke(&layer, z, TeddyPalette.ink, width: max(1.6, size * 0.34) + outline * 1.6)
        stroke(&layer, z, .white, width: max(1.6, size * 0.34))
    }

    /// Three drifting z's rising from the sleeping bear, small to large, each fading in and out.
    static func drawSleepZees(in graphics: inout GraphicsContext, time: TimeInterval, origin: CGPoint) {
        let cycle = 4.2
        for index in 0..<3 {
            let phase = (time / cycle + Double(index) / 3).truncatingRemainder(dividingBy: 1)
            let size = 2.6 + CGFloat(phase) * 3.4
            let rise = CGFloat(phase) * 15
            let sway = CGFloat(sin(phase * 2 * .pi)) * 1.2
            let opacity = sin(phase * Double.pi)
            drawZee(in: &graphics, at: CGPoint(x: origin.x + CGFloat(phase) * 7 + sway, y: origin.y - rise), size: size, opacity: opacity)
        }
    }

    /// Thought dots rising to the upper right, pulsing in turn.
    static func drawBubbleDots(in graphics: inout GraphicsContext, time: TimeInterval, origin: CGPoint) {
        let dots: [(CGPoint, CGFloat)] = [
            (CGPoint(x: origin.x, y: origin.y), 1.3),
            (CGPoint(x: origin.x + 3.6, y: origin.y - 3.4), 1.8),
            (CGPoint(x: origin.x + 8.2, y: origin.y - 7.0), 2.5),
        ]
        for (index, dot) in dots.enumerated() {
            let pulse = 0.55 + 0.45 * max(0, sin(time * 6 - Double(index) * 0.9))
            sticker(&graphics, circle(dot.0, dot.1 * CGFloat(0.8 + 0.2 * pulse)), .white.opacity(0.5 + 0.5 * pulse), rim: 0.8)
        }
    }

    /// Sound arcs from the mic, as the bear talks. `strength` is the mouth level 0...1.
    static func drawMicWaves(in graphics: inout GraphicsContext, time: TimeInterval, origin: CGPoint, strength: CGFloat) {
        for index in 0..<3 {
            let ripple = 0.55 + 0.45 * sin(time * 9 - Double(index) * 1.2)
            let alpha = max(0, min(1, strength * 2.2 - CGFloat(index) * 0.3)) * CGFloat(ripple)
            guard alpha > 0.03 else { continue }
            var arc = Path()
            arc.addArc(center: origin, radius: 5 + CGFloat(index) * 2.8, startAngle: .degrees(-70), endAngle: .degrees(-5), clockwise: false)
            graphics.stroke(arc, with: .color(TeddyPalette.ink.opacity(Double(alpha))), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
            graphics.stroke(arc, with: .color(.white.opacity(Double(alpha))), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
    }

    /// Small arcs either side of the head: "I'm listening".
    static func drawListenWaves(in graphics: inout GraphicsContext, time: TimeInterval, center: CGPoint) {
        for index in 0..<2 {
            let pulse = 0.5 + 0.5 * sin(time * 8 - Double(index) * 1.4)
            for side in [-1.0, 1.0] as [CGFloat] {
                var arc = Path()
                let radius = 12.6 + CGFloat(index) * 3.0
                arc.addArc(
                    center: center, radius: radius,
                    startAngle: .degrees(side < 0 ? 150 : -30), endAngle: .degrees(side < 0 ? 210 : 30), clockwise: false
                )
                graphics.stroke(arc, with: .color(TeddyPalette.ink.opacity(0.4 + 0.6 * pulse)), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                graphics.stroke(arc, with: .color(.white.opacity(0.4 + 0.6 * pulse)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            }
        }
    }

    /// A bold yellow "!" that pops above the head when the action key wakes him.
    static func drawExclaim(in graphics: inout GraphicsContext, at center: CGPoint, pop: CGFloat) {
        var mark = graphics
        mark.translateBy(x: center.x, y: center.y)
        mark.scaleBy(x: pop, y: pop)
        var stem = Path()
        stem.move(to: CGPoint(x: 0, y: -4.2)); stem.addLine(to: CGPoint(x: 0, y: 0.6))
        stroke(&mark, stem, TeddyPalette.ink, width: 3.4 + outline * 1.6)
        stroke(&mark, stem, TeddyPalette.impact, width: 3.4)
        sticker(&mark, circle(CGPoint(x: 0, y: 3.4), 1.5), TeddyPalette.impact, rim: 0.9)
    }

    /// A comic impact star at `center`, growing and fading with `progress` 0...1.
    static func drawImpactBurst(in graphics: inout GraphicsContext, at center: CGPoint, radius: CGFloat, progress: Double) {
        let fade = max(0, 1 - progress)
        guard fade > 0.01 else { return }
        let r = radius * CGFloat(0.55 + 0.7 * progress)
        var star = Path()
        let points = 9
        for index in 0..<(points * 2) {
            let angle = Double(index) / Double(points * 2) * 2 * .pi
            let rr = index.isMultiple(of: 2) ? r : r * 0.5
            let p = CGPoint(x: center.x + CGFloat(cos(angle)) * rr, y: center.y + CGFloat(sin(angle)) * rr)
            if index == 0 { star.move(to: p) } else { star.addLine(to: p) }
        }
        star.closeSubpath()
        var layer = graphics
        layer.opacity = fade
        layer.stroke(star, with: .color(TeddyPalette.ink), style: StrokeStyle(lineWidth: 2.4, lineJoin: .round))
        layer.fill(star, with: .color(TeddyPalette.impact))
        layer.fill(circle(center, r * 0.38), with: .color(TeddyPalette.impactCore))
    }
}

// MARK: - Held props and headwear (corner bear)

extension TeddyPalette {
    static let nightcap = Color(red: 0.24, green: 0.30, blue: 0.62)
    static let nightcapLight = Color(red: 0.40, green: 0.48, blue: 0.80)
    static let mug = Color(red: 0.98, green: 0.96, blue: 0.90)
    static let coffee = Color(red: 0.36, green: 0.20, blue: 0.11)
    static let alarmRed = Color(red: 0.90, green: 0.25, blue: 0.27)
}

extension TeddyArt {
    static func drawHeldProp(
        _ prop: TeddyBodyPose.Prop, in graphics: inout GraphicsContext, paw: CGPoint, time: TimeInterval
    ) {
        switch prop {
        case .none: break
        case .microphone: drawHandheldMicrophone(in: &graphics, paw: paw)
        case .coffeeMug: drawCoffeeMug(in: &graphics, paw: paw, time: time)
        case let .alarmClock(text, shaking): drawAlarmClock(in: &graphics, paw: paw, text: text, shaking: shaking, time: time)
        case .helpSign: drawHelpSign(in: &graphics, paw: paw)
        }
    }

    /// A tiny mug with steam, held in the paw.
    static func drawCoffeeMug(in graphics: inout GraphicsContext, paw: CGPoint, time: TimeInterval) {
        var g = graphics
        g.translateBy(x: paw.x, y: paw.y - 3.6)
        var handle = Path()
        handle.addArc(center: CGPoint(x: 3.6, y: 0.4), radius: 2.0, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        stroke(&g, handle, TeddyPalette.ink, width: 1.9 + outline * 1.6)
        stroke(&g, handle, TeddyPalette.mug, width: 1.9)
        let cup = Path(roundedRect: CGRect(x: -3.4, y: -3.0, width: 7, height: 6.4), cornerRadius: 1.6)
        sticker(&g, cup, TeddyPalette.mug)
        fill(&g, Path(ellipseIn: CGRect(x: -2.8, y: -3.2, width: 5.8, height: 1.7)), TeddyPalette.coffee)
        for index in 0..<2 {
            let phase = time * 1.6 + Double(index) * 0.5
            let sway = CGFloat(sin(phase * 3)) * 0.8
            var steam = Path()
            let x = CGFloat(index) * 2.6 - 1.3
            steam.move(to: CGPoint(x: x, y: -4.2))
            steam.addQuadCurve(to: CGPoint(x: x, y: -8.4), control: CGPoint(x: x + sway, y: -6.3))
            var layer = g
            layer.opacity = 0.55 + 0.4 * sin(phase * 2)
            stroke(&layer, steam, .white, width: 0.9)
        }
        sticker(&g, circle(CGPoint(x: -0.4, y: 3.6), 2.7), TeddyPalette.fur, rim: outline * 0.9)
    }

    /// A round alarm clock with two bells, showing `text`; it shakes while ringing.
    static func drawAlarmClock(
        in graphics: inout GraphicsContext, paw: CGPoint, text: String, shaking: Bool, time: TimeInterval
    ) {
        var g = graphics
        g.translateBy(x: paw.x, y: paw.y - 6.2)
        if shaking {
            g.rotate(by: .radians(sin(time * 46) * 0.2))
            g.translateBy(x: CGFloat(sin(time * 61)) * 0.5, y: 0)
        }
        for side in [-1.0, 1.0] as [CGFloat] {
            sticker(&g, circle(CGPoint(x: side * 4.6, y: -6.2), 1.8), TeddyPalette.gold, rim: 0.8)
        }
        sticker(&g, circle(.zero, 7.4), TeddyPalette.alarmRed)
        sticker(&g, circle(.zero, 5.9), .white, rim: 0.7)
        let digits = Text(text)
            .font(.system(size: 3.5, weight: .heavy, design: .rounded))
            .foregroundColor(TeddyPalette.ink)
        g.draw(digits, at: CGPoint(x: 0, y: 0.2), anchor: .center)
        if shaking {
            for side in [-1.0, 1.0] as [CGFloat] {
                var ring = Path()
                ring.move(to: CGPoint(x: side * 9.0, y: -2)); ring.addLine(to: CGPoint(x: side * 11.2, y: -3.4))
                ring.move(to: CGPoint(x: side * 9.4, y: 1)); ring.addLine(to: CGPoint(x: side * 11.8, y: 1))
                stroke(&g, ring, TeddyPalette.ink, width: 1.9)
                stroke(&g, ring, .white, width: 0.8)
            }
        }
        sticker(&g, circle(CGPoint(x: 0, y: 7.4), 2.7), TeddyPalette.fur, rim: outline * 0.9)
    }

    /// A little sign on a stick with a "?" on it, held up by the paw.
    static func drawHelpSign(in graphics: inout GraphicsContext, paw: CGPoint) {
        var g = graphics
        g.translateBy(x: paw.x, y: paw.y)
        var stick = Path()
        stick.move(to: CGPoint(x: 0, y: 2)); stick.addLine(to: CGPoint(x: 0, y: -8))
        stroke(&g, stick, TeddyPalette.ink, width: 2.2 + outline * 1.6)
        stroke(&g, stick, TeddyPalette.tan, width: 2.2)
        let board = Path(roundedRect: CGRect(x: -6.5, y: -19, width: 13, height: 11.5), cornerRadius: 2.2)
        sticker(&g, board, .white, rim: 1.2)
        drawQuestionMark(in: &g, at: CGPoint(x: 0, y: -13.4), scale: 1.25)
        sticker(&g, circle(CGPoint(x: 0, y: 0.4), 2.9), TeddyPalette.fur, rim: outline * 0.9)
    }

    /// A slumped nightcap with a pom-pom, on the bear's head (head grid).
    /// Over-ear headphones on the head grid (centre 16, 18.5): a charcoal band arching over the
    /// top between the ears, and a yellow cushion cup over each side of the face.
    static func drawHeadphones(in graphics: inout GraphicsContext) {
        let band = Color(red: 0.20, green: 0.22, blue: 0.28)
        var arch = Path()
        arch.move(to: CGPoint(x: 3.4, y: 19.5))
        arch.addCurve(to: CGPoint(x: 28.6, y: 19.5), control1: CGPoint(x: 1.4, y: -1.6), control2: CGPoint(x: 30.6, y: -1.6))
        stroke(&graphics, arch, TeddyPalette.ink, width: 2.4 + outline * 2)
        stroke(&graphics, arch, band, width: 2.4)
        // A thin highlight along the top of the band.
        let shine = arch.trimmedPath(from: 0.3, to: 0.5)
        stroke(&graphics, shine, Color.white.opacity(0.35), width: 0.5)
        for x in [3.0, 29.0] as [CGFloat] {
            let cup = Path(roundedRect: CGRect(x: x - 2.6, y: 14.4, width: 5.2, height: 9.6), cornerRadius: 2.6)
            sticker(&graphics, cup, TeddyPalette.impact, rim: outline)
            // The darker speaker pad on the face side of each cup.
            let pad = Path(roundedRect: CGRect(x: x - 1.5 + (x < 16 ? 1.3 : -1.3), y: 16.2, width: 3, height: 6), cornerRadius: 1.5)
            fill(&graphics, pad, band)
        }
    }

    static func drawNightcap(in graphics: inout GraphicsContext) {
        var cap = Path()
        cap.move(to: CGPoint(x: 5.6, y: 12.4))
        cap.addCurve(to: CGPoint(x: 26.4, y: 12.4), control1: CGPoint(x: 6, y: 2.2), control2: CGPoint(x: 24, y: 1.6))
        cap.addQuadCurve(to: CGPoint(x: 5.6, y: 12.4), control: CGPoint(x: 16, y: 15.4))
        cap.closeSubpath()
        // Droop to the side.
        var tail = Path()
        tail.move(to: CGPoint(x: 20, y: 6.2))
        tail.addQuadCurve(to: CGPoint(x: 31.5, y: 15.5), control: CGPoint(x: 31, y: 5))
        tail.addLine(to: CGPoint(x: 27.4, y: 11.6))
        tail.addQuadCurve(to: CGPoint(x: 20, y: 6.2), control: CGPoint(x: 24.5, y: 6.4))
        tail.closeSubpath()
        sticker(&graphics, tail, TeddyPalette.nightcap)
        sticker(&graphics, cap, TeddyPalette.nightcap)
        var band = Path()
        band.move(to: CGPoint(x: 5.9, y: 11.6))
        band.addQuadCurve(to: CGPoint(x: 26.1, y: 11.6), control: CGPoint(x: 16, y: 14.4))
        graphics.stroke(band, with: .color(TeddyPalette.nightcapLight), style: StrokeStyle(lineWidth: 2.0, lineCap: .round))
        for spot in [CGPoint(x: 12, y: 7.2), CGPoint(x: 17.5, y: 5.6), CGPoint(x: 22.5, y: 8.6)] {
            fill(&graphics, circle(spot, 0.7), TeddyPalette.impactCore)
        }
        sticker(&graphics, circle(CGPoint(x: 31.8, y: 16.4), 1.9), .white, rim: 0.8)
    }
}
