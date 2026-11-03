import SwiftUI

// MARK: - Snapshot

/// Everything needed to draw one frame of the corner bear; built by the model each tick (or
/// by hand in the render harness). Coordinates are in the panel's space, origin top left.
struct RioCompanionSnapshot {
    struct Bubble: Equatable {
        var caption: String?
        var text: String
    }

    struct Impact: Equatable {
        var center: CGPoint
        var progress: Double
    }

    var figure: RioCompanionFigure
    var time: TimeInterval
    /// Horizontal centre of the body and the y of the floor (soles of the shoes).
    var center: CGPoint
    var outfit: TeddyOutfit = .hoodie
    var look: SpokenLook = .none
    var bubble: Bubble?
    var impact: Impact?
    var isHidden = false
}

enum RioCompanionMetrics {
    /// Points per body-grid unit: the bear is about 63 pt tall (ears to soles) at rest.
    static let unit: CGFloat = 1.4
    /// Panel for the sleeping or talking corner bear.
    static let cornerPanelSize = CGSize(width: 360, height: 150)
    static let leftPad: CGFloat = 8
    /// Body centre's distance from the left edge of the artwork.
    static var halfBody: CGFloat { 14 * unit }
}

// MARK: - Scene (shared by the live panel and the render harness)

struct RioCompanionSceneView: View {
    let snapshot: RioCompanionSnapshot
    var showsStop = false
    var onStop: () -> Void = {}

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { graphics, _ in
                guard !snapshot.isHidden else { return }
                RioCompanionRenderer.draw(snapshot, in: &graphics)
            }
            if !snapshot.isHidden, let bubble = snapshot.bubble {
                RioSpeechCard(bubble: bubble)
                    .fixedSize()
                    .position(cardCenter(for: bubble))
            }
            if showsStop, !snapshot.isHidden {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color(red: 0.9, green: 0.2, blue: 0.2)))
                        .overlay(Circle().stroke(TeddyPalette.ink, lineWidth: 1.4))
                }
                .buttonStyle(.plain)
                .position(x: snapshot.center.x - 36, y: snapshot.center.y - 12)
                .accessibilityLabel("Stop dictation")
            }
        }
    }

    /// The card sits to the right of the bear, level with his head.
    private func cardCenter(for bubble: RioCompanionSnapshot.Bubble) -> CGPoint {
        let size = RioSpeechCard.size(for: bubble)
        let headY = snapshot.center.y - RioCompanionMetrics.unit * 33
        return CGPoint(x: snapshot.center.x + 34 + size.width / 2, y: headY)
    }
}

/// A white sticker card with a small tail pointing back at the bear.
struct RioSpeechCard: View {
    let bubble: RioCompanionSnapshot.Bubble

    static let maxTextWidth: CGFloat = 230

    static func size(for bubble: RioCompanionSnapshot.Bubble) -> CGSize {
        let textWidth = min(maxTextWidth, CGFloat(bubble.text.count) * 7.2 + 4)
        let captionWidth = CGFloat(bubble.caption?.count ?? 0) * 5.2
        let width = max(textWidth, captionWidth) + 26
        return CGSize(width: max(70, width), height: bubble.caption == nil ? 30 : 40)
    }

    var body: some View {
        let size = Self.size(for: bubble)
        VStack(alignment: .leading, spacing: 0) {
            if let caption = bubble.caption {
                Text(caption.uppercased())
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(TeddyPalette.hoodie)
            }
            Text(bubble.text)
                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                .foregroundStyle(TeddyPalette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: size.width - 20, height: size.height - 8, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white)
                RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(TeddyPalette.ink, lineWidth: 1.6)
                Tail().fill(.white).frame(width: 9, height: 12).offset(x: -7.5)
                Tail().stroke(TeddyPalette.ink, lineWidth: 1.6).frame(width: 9, height: 12).offset(x: -7.5)
            }
        )
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(bubble.caption.map { $0 + ": " } ?? "")\(bubble.text)")
    }

    private struct Tail: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY + 1))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 1))
            return path
        }
    }
}

// MARK: - Renderer

enum RioCompanionRenderer {
    /// Draws the bear and the effects around him into a panel-sized canvas.
    static func draw(_ snapshot: RioCompanionSnapshot, in graphics: inout GraphicsContext) {
        let unit = RioCompanionMetrics.unit
        let figure = snapshot.figure

        var scene = graphics
        scene.translateBy(x: snapshot.center.x, y: snapshot.center.y)
        if !figure.facesRight { scene.scaleBy(x: -1, y: 1) }
        scene.translateBy(x: -20 * unit, y: -RioCompanionPoseBuilder.groundY * unit)
        scene.scaleBy(x: unit, y: unit)

        // A soft contact shadow on the floor, shrinking while he leaps.
        var shadow = scene
        let lift = max(0, figure.pose.bob)
        shadow.opacity = 0.22 * Double(max(0.35, 1 - lift / 18))
        shadow.fill(
            Path(ellipseIn: CGRect(x: 10 + lift * 0.25, y: RioCompanionPoseBuilder.groundY - 1.2, width: 20 - lift * 0.5, height: 2.6)),
            with: .color(.black)
        )

        var body = scene
        body.addFilter(.shadow(color: .black.opacity(0.3), radius: 1.6, x: 0, y: 0.8))
        TeddyArt.drawBody(in: &body, time: snapshot.time, pose: figure.pose, outfit: snapshot.outfit, look: snapshot.look)

        drawEffects(figure, snapshot: snapshot, in: &scene)

        if let impact = snapshot.impact {
            TeddyArt.drawImpactBurst(in: &graphics, at: impact.center, radius: 20, progress: impact.progress)
        }
    }

    private static func drawEffects(
        _ figure: RioCompanionFigure, snapshot: RioCompanionSnapshot, in scene: inout GraphicsContext
    ) {
        let time = snapshot.time
        for effect in figure.effects {
            switch effect {
            case .sleepZees:
                TeddyArt.drawSleepZees(in: &scene, time: time, origin: CGPoint(x: 26, y: 15))
            case .thoughtDots:
                TeddyArt.drawBubbleDots(in: &scene, time: time, origin: CGPoint(x: 30, y: 8))
            case let .micWaves(strength):
                TeddyArt.drawMicWaves(in: &scene, time: time, origin: CGPoint(x: 27.4, y: 16.4), strength: strength)
            case .listenWaves:
                TeddyArt.drawListenWaves(in: &scene, time: time, center: CGPoint(x: 20, y: 14))
            case let .exclaim(pop):
                TeddyArt.drawExclaim(in: &scene, at: CGPoint(x: 31, y: 4.5 - figure.pose.bob * 0.4), pop: pop)
            case .question:
                TeddyArt.drawQuestionMark(in: &scene, at: CGPoint(x: 31.5 + CGFloat(sin(time * 3)) * 0.4, y: 5), scale: 1.35)
            case .sweat:
                TeddyArt.drawSweatDrop(in: &scene, at: CGPoint(x: 29.5, y: 10 + CGFloat(abs(sin(time * 3))) * 0.6))
            case .sparkle:
                TeddyArt.drawSparkle(in: &scene, at: CGPoint(x: 32.5, y: 8), size: 2.4, time: time)
            case .confetti:
                drawConfetti(in: &scene, time: time)
            }
        }
    }

    private static func drawConfetti(in graphics: inout GraphicsContext, time: TimeInterval) {
        let colors: [Color] = [TeddyPalette.impact, TeddyPalette.blush, TeddyPalette.hoodie, TeddyPalette.jeansCuff, .white]
        for index in 0..<12 {
            let seed = Double(index) * 1.7
            let fall = (time * 0.9 + seed).truncatingRemainder(dividingBy: 1)
            let x = 6 + CGFloat((seed * 7).truncatingRemainder(dividingBy: 28)) + CGFloat(sin(time * 4 + seed)) * 1.5
            let y = -2 + CGFloat(fall) * 34
            var piece = graphics
            piece.translateBy(x: x, y: y)
            piece.rotate(by: .radians(time * 5 + seed))
            piece.opacity = 1 - fall * 0.6
            TeddyArt.sticker(&piece, Path(CGRect(x: -1, y: -0.6, width: 2, height: 1.2)), colors[index % colors.count], rim: 0.35)
        }
    }
}
