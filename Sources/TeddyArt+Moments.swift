import SwiftUI

// The pill bear for the short moments between dictations. 36 x 32 grid; the right edge
// overlaps the white text card next to it, so props and paws live around x = 28...36.
extension TeddyArt {
    static func drawMomentBear(
        in graphics: inout GraphicsContext,
        time: TimeInterval,
        moment: TeddyMoment,
        outfit: TeddyOutfit = .hoodie
    ) {
        switch moment {
        case .learned, .alreadyKnown:
            drawBearHoldingCard(in: &graphics, time: time, outfit: outfit)
        case .didntCatchThat:
            drawShrug(in: &graphics, time: time, outfit: outfit)
        case .undone:
            drawOops(in: &graphics, time: time, outfit: outfit)
        case .sent:
            drawSmash(in: &graphics, time: time, outfit: outfit)
        case .milestone:
            drawCelebration(in: &graphics, time: time, outfit: outfit)
        }
    }

    /// The "learned" pose: a paw resting on the card.
    static func drawBearHoldingCard(in graphics: inout GraphicsContext, time: TimeInterval, outfit: TeddyOutfit = .hoodie) {
        // A small proud bounce.
        graphics.translateBy(x: 0, y: -CGFloat(abs(sin(time * 4))) * 0.8)
        let face = TeddyFace(mouthOpen: 0.3, isBlinking: isBlinking(at: time))
        drawHead(in: &graphics, face: face, outfit: outfit, neckwear: true)
        drawSleeveStub(in: &graphics, outfit: outfit, from: CGPoint(x: 32.4, y: 34), to: CGPoint(x: 31.5, y: 26.4), width: 5.4)
        let paw = circle(CGPoint(x: 31.5, y: 24.5), 3.3)
        sticker(&graphics, paw, TeddyPalette.fur)
        var toes = Path()
        for x in [30.2, 32.8] as [CGFloat] {
            toes.move(to: CGPoint(x: x, y: 21.8))
            toes.addLine(to: CGPoint(x: x, y: 23.3))
        }
        stroke(&graphics, toes, TeddyPalette.ink, width: 0.7)
    }

    // MARK: Shrug

    /// Both paws up, palms up, brows raised and a small "?".
    private static func drawShrug(in graphics: inout GraphicsContext, time: TimeInterval, outfit: TeddyOutfit) {
        let hover = CGFloat(sin(time * 5)) * 0.45
        let face = TeddyFace(isBlinking: isBlinking(at: time), mouth: .flat, raisedBrows: true)
        var head = graphics
        head.translateBy(x: 0, y: hover * 0.4)
        drawHead(in: &head, face: face, outfit: outfit, neckwear: true)
        drawSleeveStub(in: &graphics, outfit: outfit, from: CGPoint(x: 7.4, y: 34.5), to: CGPoint(x: 4.4, y: 25.8 + hover), width: 5.2)
        drawSleeveStub(in: &graphics, outfit: outfit, from: CGPoint(x: 28.6, y: 34.5), to: CGPoint(x: 31.6, y: 25.8 + hover), width: 5.2)
        drawPalm(in: &graphics, at: CGPoint(x: 4.4, y: 25.8 + hover))
        drawPalm(in: &graphics, at: CGPoint(x: 31.6, y: 25.8 + hover))
        drawQuestionMark(in: &graphics, at: CGPoint(x: 31.6 + CGFloat(sin(time * 3)) * 0.4, y: 9.2), scale: 1.25)
    }

    /// A paw seen palm-on: fur ring, tan pad and three toe bumps.
    private static func drawPalm(in graphics: inout GraphicsContext, at center: CGPoint) {
        sticker(&graphics, circle(center, 3.2), TeddyPalette.fur)
        fill(&graphics, Path(ellipseIn: CGRect(x: center.x - 1.7, y: center.y - 0.2, width: 3.4, height: 2.6)), TeddyPalette.tan)
        for dx in [-1.7, 0, 1.7] as [CGFloat] {
            fill(&graphics, circle(CGPoint(x: center.x + dx, y: center.y - (dx == 0 ? 1.7 : 1.3)), 0.75), TeddyPalette.tan)
        }
    }

    static func drawQuestionMark(in graphics: inout GraphicsContext, at center: CGPoint, scale: CGFloat) {
        var mark = graphics
        mark.translateBy(x: center.x, y: center.y)
        mark.scaleBy(x: scale, y: scale)
        var hook = Path()
        hook.move(to: CGPoint(x: -1.8, y: -1.6))
        hook.addCurve(to: CGPoint(x: 0, y: -3.5), control1: CGPoint(x: -1.8, y: -2.8), control2: CGPoint(x: -1, y: -3.5))
        hook.addCurve(to: CGPoint(x: 1.8, y: -1.8), control1: CGPoint(x: 1, y: -3.5), control2: CGPoint(x: 1.8, y: -2.8))
        hook.addCurve(to: CGPoint(x: 0, y: 0.5), control1: CGPoint(x: 1.8, y: -0.6), control2: CGPoint(x: 0, y: -0.5))
        hook.addLine(to: CGPoint(x: 0, y: 1.2))
        let gold = Color(red: 1.0, green: 0.82, blue: 0.25)
        stroke(&mark, hook, TeddyPalette.ink, width: 2.8)
        fill(&mark, circle(CGPoint(x: 0, y: 3.1), 1.15), TeddyPalette.ink)
        stroke(&mark, hook, gold, width: 1.5)
        fill(&mark, circle(CGPoint(x: 0, y: 3.1), 0.7), gold)
    }

    // MARK: Oops

    /// Wide eyes, a small round mouth and a sweat drop, rubbing the text out with an eraser.
    private static func drawOops(in graphics: inout GraphicsContext, time: TimeInterval, outfit: TeddyOutfit) {
        let rub = CGFloat(sin(time * 12))
        let face = TeddyFace(eyes: .wide, mouth: .oh)
        var head = graphics
        head.translateBy(x: rub * 0.15, y: 0)
        drawHead(in: &head, face: face, outfit: outfit, neckwear: true)
        drawSweatDrop(in: &graphics, at: CGPoint(x: 24.8, y: 14.6 + CGFloat(abs(sin(time * 3))) * 0.5))

        drawSleeveStub(in: &graphics, outfit: outfit, from: CGPoint(x: 29.6, y: 34), to: CGPoint(x: 31.0, y: 27.6), width: 5.2)
        var eraser = graphics
        eraser.translateBy(x: 32.2 + rub * 1.0, y: 23.6)
        eraser.rotate(by: .radians(-0.22))
        let body = Path(roundedRect: CGRect(x: -3.6, y: -2.3, width: 7.2, height: 4.6), cornerRadius: 0.9)
        sticker(&eraser, body, TeddyPalette.eraserPink)
        var band = eraser
        band.clip(to: body)
        fill(&band, Path(CGRect(x: -1.2, y: -2.5, width: 2.8, height: 5.0)), Color(red: 0.27, green: 0.46, blue: 0.88))
        fill(&band, Path(CGRect(x: -0.1, y: -2.5, width: 0.5, height: 5.0)), .white)
        // Crumbs.
        for (index, spot) in [CGPoint(x: 28.4, y: 27.2), CGPoint(x: 34.6, y: 27.6), CGPoint(x: 29.6, y: 19.4)].enumerated() {
            let drift = CGFloat(index) * 0.7 + CGFloat(abs(rub)) * 0.5
            fill(&graphics, circle(CGPoint(x: spot.x, y: spot.y + drift), 0.6), TeddyPalette.eraserPink)
        }
        sticker(&graphics, circle(CGPoint(x: 31.2, y: 26.9), 2.8), TeddyPalette.fur, rim: outline * 0.9)
    }

    static func drawSweatDrop(in graphics: inout GraphicsContext, at center: CGPoint) {
        var drop = Path()
        drop.move(to: CGPoint(x: center.x, y: center.y - 2.2))
        drop.addQuadCurve(to: CGPoint(x: center.x, y: center.y + 1.9), control: CGPoint(x: center.x - 2.1, y: center.y + 0.6))
        drop.addQuadCurve(to: CGPoint(x: center.x, y: center.y - 2.2), control: CGPoint(x: center.x + 2.1, y: center.y + 0.6))
        sticker(&graphics, drop, TeddyPalette.sweat, rim: 0.7)
        fill(&graphics, circle(CGPoint(x: center.x - 0.4, y: center.y + 0.5), 0.3), .white)
    }

    // MARK: Sent

    /// A paw smashing a big red button, with impact lines.
    private static func drawSmash(in graphics: inout GraphicsContext, time: TimeInterval, outfit: TeddyOutfit) {
        let press = min(1, CGFloat(abs(sin(time * 7))) * 1.4)
        let face = TeddyFace(isBlinking: isBlinking(at: time), eyes: .happy, mouth: .grin)
        drawHead(in: &graphics, face: face, outfit: outfit, neckwear: true)

        // The raised arm comes up from the bottom edge and drops its paw onto the button.
        let centerX: CGFloat = 30.8
        let paw = CGPoint(x: 32.6 - 1.6 * press, y: 17.5 + 8.0 * press)
        drawSleeveStub(in: &graphics, outfit: outfit, from: CGPoint(x: 27.0, y: 35), to: paw, width: 5.4)

        // Button: steel base, red dome that squashes under the paw.
        let base = Path(ellipseIn: CGRect(x: centerX - 5.2, y: 28.0, width: 10.4, height: 3.8))
        sticker(&graphics, base, TeddyPalette.steel)
        let height = 4.6 - 2.4 * press
        var dome = Path()
        dome.move(to: CGPoint(x: centerX - 4.2, y: 29.6))
        dome.addCurve(
            to: CGPoint(x: centerX + 4.2, y: 29.6),
            control1: CGPoint(x: centerX - 4.2, y: 29.6 - height * 1.35),
            control2: CGPoint(x: centerX + 4.2, y: 29.6 - height * 1.35)
        )
        dome.closeSubpath()
        sticker(&graphics, dome, TeddyPalette.buttonRed)
        var shine = Path()
        shine.move(to: CGPoint(x: centerX - 2.8, y: 28.8))
        shine.addQuadCurve(to: CGPoint(x: centerX - 1.0, y: 29.6 - height * 0.95), control: CGPoint(x: centerX - 2.7, y: 29.6 - height * 0.9))
        stroke(&graphics, shine, .white.opacity(0.85), width: 0.7)
        sticker(&graphics, circle(paw, 3.3), TeddyPalette.fur)

        if press > 0.55 {
            let gold = Color(red: 1.0, green: 0.84, blue: 0.25)
            var rays = Path()
            for degrees in [-175.0, -150.0, -30.0, -5.0] {
                let angle = degrees * .pi / 180
                rays.move(to: CGPoint(x: centerX + CGFloat(cos(angle)) * 6.0, y: 27.6 + CGFloat(sin(angle)) * 4.0))
                rays.addLine(to: CGPoint(x: centerX + CGFloat(cos(angle)) * 8.6, y: 27.6 + CGFloat(sin(angle)) * 6.0))
            }
            stroke(&graphics, rays, TeddyPalette.ink, width: 2.5)
            stroke(&graphics, rays, gold, width: 1.1)
        }
    }

    // MARK: Milestone

    /// Party hat, confetti, a big grin and both paws up.
    private static func drawCelebration(in graphics: inout GraphicsContext, time: TimeInterval, outfit: TeddyOutfit) {
        drawConfetti(in: &graphics, time: time)
        let hop = CGFloat(abs(sin(time * 5))) * 0.9
        graphics.translateBy(x: 0, y: -hop)
        let face = TeddyFace(eyes: .happy, mouth: .grin)
        drawHead(in: &graphics, face: face, outfit: outfit, partyHat: true, neckwear: true)
        let wave = CGFloat(sin(time * 9)) * 0.9
        drawSleeveStub(in: &graphics, outfit: outfit, from: CGPoint(x: 6.6, y: 35), to: CGPoint(x: 3.8, y: 24.2 + wave), width: 5.2)
        drawSleeveStub(in: &graphics, outfit: outfit, from: CGPoint(x: 29.4, y: 35), to: CGPoint(x: 32.2, y: 24.2 - wave), width: 5.2)
        sticker(&graphics, circle(CGPoint(x: 3.8, y: 24.2 + wave), 3.1), TeddyPalette.fur)
        sticker(&graphics, circle(CGPoint(x: 32.2, y: 24.2 - wave), 3.1), TeddyPalette.fur)
    }

    private static func drawConfetti(in graphics: inout GraphicsContext, time: TimeInterval) {
        let colors: [Color] = [
            Color(red: 1.0, green: 0.42, blue: 0.62), Color(red: 1.0, green: 0.84, blue: 0.25),
            Color(red: 0.35, green: 0.78, blue: 0.98), Color(red: 0.45, green: 0.85, blue: 0.5),
            Color(red: 1.0, green: 0.6, blue: 0.25), .white,
        ]
        let columns: [CGFloat] = [1.5, 4.5, 8, 12.5, 18, 23.5, 27.5, 30.5, 33.5, 14.5, 20.5, 34.8, 2.8, 26]
        for (index, x) in columns.enumerated() {
            let fall = (CGFloat(index) * 5.3 + CGFloat(time) * 7).truncatingRemainder(dividingBy: 36) - 2
            var bit = graphics
            bit.translateBy(x: x + CGFloat(sin(time * 3 + Double(index))) * 0.8, y: fall)
            bit.rotate(by: .radians(time * 4 + Double(index)))
            let rect = CGRect(x: -1.4, y: -0.8, width: 2.8, height: 1.6)
            bit.fill(Path(rect), with: .color(colors[index % colors.count]))
            bit.stroke(Path(rect), with: .color(TeddyPalette.ink), lineWidth: 0.35)
        }
    }
}
