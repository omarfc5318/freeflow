import SwiftUI

// MARK: - Artwork

/// Flat cutout drawing: white shapes, black details and outlines, no gradients.
/// The pill bear and the full-body teddy share `drawHead`, so the face always matches.
enum TeddyArt {
    static let outline: CGFloat = 1.1

    // MARK: Head (shared)

    /// Drawn on a grid where the head's centre is (16, 18.5) and the ears reach y = 3.
    /// The black rim behind every shape keeps the bear readable on any background.
    static func drawHead(
        in graphics: inout GraphicsContext,
        mouthOpen open: CGFloat,
        isBlinking: Bool,
        isThinking: Bool,
        winks: Bool = false
    ) {
        drawHeadShape(in: &graphics, innerEars: true)

        // Eyes: look up and to the side while thinking; the left one closes for a wink.
        let gaze = isThinking ? CGSize(width: 0.9, height: -1.5) : .zero
        for x in [11.8, 20.2] {
            if winks && x < 16 {
                var lid = Path()
                lid.move(to: CGPoint(x: x - 1.8, y: 15))
                lid.addQuadCurve(to: CGPoint(x: x + 1.8, y: 15), control: CGPoint(x: x, y: 13.4))
                graphics.stroke(lid, with: .color(.black), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
                continue
            }
            let eye = CGRect(
                x: x - 1.6 + gaze.width,
                y: 15 - (isBlinking ? 0.25 : 1.6) + gaze.height,
                width: 3.2,
                height: isBlinking ? 0.5 : 3.2
            )
            fill(&graphics, Path(ellipseIn: eye), .black)
        }

        // Snout, nose and mouth.
        let snout = Path(ellipseIn: CGRect(x: 10.8, y: 18.6, width: 10.4, height: 7.8))
        fill(&graphics, snout, .white)
        graphics.stroke(snout, with: .color(.black), lineWidth: outline)
        fill(&graphics, Path(ellipseIn: CGRect(x: 13.9, y: 19.3, width: 4.2, height: 2.8)), .black)
        if open > 0.05 {
            let width = 2.6 + 2.2 * open
            let height = 0.9 + 2.6 * open
            fill(&graphics, Path(ellipseIn: CGRect(x: 16 - width / 2, y: 22.6, width: width, height: height)), .black)
        } else {
            var smile = Path()
            smile.move(to: CGPoint(x: isThinking ? 15 : 14.4, y: 23.3))
            smile.addQuadCurve(
                to: CGPoint(x: isThinking ? 17.4 : 17.6, y: 23.3),
                control: CGPoint(x: 16, y: isThinking ? 23.3 : 24.4)
            )
            graphics.stroke(smile, with: .color(.black), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
        }
    }

    /// Ears and head with their black rim; from behind the ears have no inner patch.
    static func drawHeadShape(in graphics: inout GraphicsContext, innerEars: Bool) {
        let ears = [CGPoint(x: 7.5, y: 8), CGPoint(x: 24.5, y: 8)]
        let headCenter = CGPoint(x: 16, y: 18.5)
        for center in ears { fill(&graphics, circle(center, 5 + outline), .black) }
        fill(&graphics, circle(headCenter, 11.5 + outline), .black)
        for center in ears {
            fill(&graphics, circle(center, 5), .white)
            if innerEars {
                let inner = CGPoint(x: center.x + (center.x < 16 ? 0.8 : -0.8), y: center.y + 0.8)
                fill(&graphics, circle(inner, 2.3), .black)
            }
        }
        fill(&graphics, circle(headCenter, 11.5), .white)
    }

    static func isBlinking(at time: TimeInterval) -> Bool {
        time.truncatingRemainder(dividingBy: 3.6) < 0.13
    }

    // MARK: Talking bear

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

        drawHead(
            in: &graphics,
            mouthOpen: open,
            isBlinking: mood != .thinking && isBlinking(at: time),
            isThinking: mood == .thinking
        )
        drawMicrophone(in: &graphics)

        switch mood {
        case .talking:
            drawSoundArcs(in: &graphics, time: time, strength: open)
        case .thinking:
            drawThoughtDots(in: &graphics, time: time)
        case .idle:
            break
        }
    }

    /// On a 36 x 32 grid: the pill bear's head, smiling, with a paw at the right edge
    /// that rests on the card next to it.
    /// The pill bear for a between-dictation moment, posed to match it, in a 36 x 32 grid
    /// whose right edge overlaps the card next to it.
    static func drawMomentBear(
        in graphics: inout GraphicsContext,
        time: TimeInterval,
        moment: TeddyMoment,
        outfit: TeddyOutfit = .hoodie
    ) {
        drawBearHoldingCard(in: &graphics, time: time)
    }

    static func drawBearHoldingCard(in graphics: inout GraphicsContext, time: TimeInterval) {
        // A small proud bounce.
        graphics.translateBy(x: 0, y: -CGFloat(abs(sin(time * 4))) * 0.8)
        drawHead(in: &graphics, mouthOpen: 0.3, isBlinking: isBlinking(at: time), isThinking: false)
        let paw = circle(CGPoint(x: 31.5, y: 24.5), 3.3)
        fill(&graphics, paw, .white)
        graphics.stroke(paw, with: .color(.black), lineWidth: outline)
        var toes = Path()
        for x in [30.2, 32.8] {
            toes.move(to: CGPoint(x: x, y: 21.6))
            toes.addLine(to: CGPoint(x: x, y: 23.2))
        }
        graphics.stroke(toes, with: .color(.black), style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
    }

    static func drawMicrophone(in graphics: inout GraphicsContext) {
        // Handle, outlined, running down and out from the mic head.
        var handle = Path()
        handle.move(to: CGPoint(x: 30.6, y: 26))
        handle.addLine(to: CGPoint(x: 33.8, y: 31))
        graphics.stroke(handle, with: .color(.black), style: StrokeStyle(lineWidth: 3.8, lineCap: .round))
        graphics.stroke(handle, with: .color(.white), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))

        // Head with a cross-hatched grille.
        let head = circle(CGPoint(x: 29.3, y: 23.4), 3.4)
        fill(&graphics, head, .white)
        var grille = graphics
        grille.clip(to: head)
        var lines = Path()
        for offset in stride(from: -4.0, through: 4.0, by: 2.0) {
            lines.move(to: CGPoint(x: 25.3 + offset, y: 19.4))
            lines.addLine(to: CGPoint(x: 33.3 + offset, y: 27.4))
            lines.move(to: CGPoint(x: 33.3 + offset, y: 19.4))
            lines.addLine(to: CGPoint(x: 25.3 + offset, y: 27.4))
        }
        grille.stroke(lines, with: .color(.black), lineWidth: 0.55)
        graphics.stroke(head, with: .color(.black), lineWidth: outline)

        // Paw wrapped around the handle.
        let paw = circle(CGPoint(x: 31.9, y: 28.4), 2.3)
        fill(&graphics, paw, .white)
        graphics.stroke(paw, with: .color(.black), lineWidth: outline * 0.9)
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

    static func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    static func fill(_ graphics: inout GraphicsContext, _ path: Path, _ color: Color) {
        graphics.fill(path, with: .color(color))
    }
}
