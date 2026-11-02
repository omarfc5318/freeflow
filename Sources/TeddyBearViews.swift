import AppKit
import SwiftUI

// MARK: - Talking bear (recording pill)

/// A black-and-white cutout bear speaking into a microphone. Its mouth opens with the
/// microphone level and sound arcs ripple out of the mic; while the dictation is being
/// turned into text it looks up and "thinks".
struct TalkingBearView: View {
    enum Mood {
        case idle
        case talking
        case thinking
    }

    let mood: Mood
    var audioLevel: Float = 0
    var height: CGFloat = 28

    /// Drawing space; the art is laid out on a 44 x 32 grid and scaled to `height`.
    static let gridSize = CGSize(width: 44, height: 32)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { graphics, size in
                let scale = size.height / Self.gridSize.height
                graphics.scaleBy(x: scale, y: scale)
                TeddyArt.drawTalkingBear(
                    in: &graphics,
                    time: time,
                    level: mood == .talking ? CGFloat(min(max(audioLevel, 0), 1)) : 0,
                    mood: mood
                )
            }
        }
        .frame(width: height * Self.gridSize.width / Self.gridSize.height, height: height)
        .accessibilityLabel(mood == .thinking ? "Transcribing" : "Recording")
    }
}

// MARK: - Running teddy ("Teddy go crazy")

/// The same bear, full body: a chubby teddy running on two feet with fat arms.
struct RunningTeddyView: View {
    let time: TimeInterval
    var isJumping = false
    var height: CGFloat = TeddyLapController.bearHeight

    static let gridSize = CGSize(width: 40, height: 50)

    var body: some View {
        Canvas { graphics, size in
            let scale = size.height / Self.gridSize.height
            graphics.scaleBy(x: scale, y: scale)
            TeddyArt.drawRunningTeddy(in: &graphics, time: time, isJumping: isJumping)
        }
        .frame(width: height * Self.gridSize.width / Self.gridSize.height, height: height)
        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
    }
}

/// The whole trip, driven by wall-clock time: out of the pill, one loop, back in.
struct TeddyLapView: View {
    let start: Date
    let track: TeddyLap.Track

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
            let elapsed = context.date.timeIntervalSince(start)
            let pose = TeddyLap.pose(at: elapsed, on: track)
            RunningTeddyView(time: elapsed, isJumping: pose.isJumping)
                .scaleEffect(x: pose.facesRight ? pose.scale : -pose.scale, y: pose.scale)
                .position(pose.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
    }
}

/// Shows the trip in a click-through window above everything. `stop()` removes it
/// at once (for example when a new dictation starts) without calling `onFinished`.
/// Main thread only.
final class TeddyLapController {
    static let bearHeight: CGFloat = 64

    private var panel: NSPanel?
    private var finishWorkItem: DispatchWorkItem?

    var isRunning: Bool { panel != nil }

    /// `home` is the bear's centre in the pill, measured from the top left of `screen`.
    func start(on screen: NSScreen, home: CGPoint, onFinished: @escaping () -> Void) {
        stop()
        let frame = screen.frame
        let track = TeddyLap.track(screenSize: frame.size, home: home, margin: Self.bearHeight / 2 + 8)

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.setFrame(frame, display: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: TeddyLapView(start: Date(), track: track))
        panel.orderFrontRegardless()
        self.panel = panel

        let finish = DispatchWorkItem { [weak self] in
            self?.stop()
            onFinished()
        }
        finishWorkItem = finish
        DispatchQueue.main.asyncAfter(deadline: .now() + TeddyLap.duration(of: track), execute: finish)
    }

    func stop() {
        finishWorkItem?.cancel()
        finishWorkItem = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - Artwork

/// Flat cutout drawing: white shapes, black details and outlines, no gradients.
/// The pill bear and the running teddy share `drawHead`, so the face always matches.
enum TeddyArt {
    private static let outline: CGFloat = 1.1

    // MARK: Head (shared)

    /// Drawn on a grid where the head's centre is (16, 18.5) and the ears reach y = 3.
    /// The black rim behind every shape keeps the bear readable on any background.
    private static func drawHead(
        in graphics: inout GraphicsContext,
        mouthOpen open: CGFloat,
        isBlinking: Bool,
        isThinking: Bool
    ) {
        let ears = [CGPoint(x: 7.5, y: 8), CGPoint(x: 24.5, y: 8)]
        let headCenter = CGPoint(x: 16, y: 18.5)
        for center in ears { fill(&graphics, circle(center, 5 + outline), .black) }
        fill(&graphics, circle(headCenter, 11.5 + outline), .black)
        for center in ears {
            fill(&graphics, circle(center, 5), .white)
            let inner = CGPoint(x: center.x + (center.x < 16 ? 0.8 : -0.8), y: center.y + 0.8)
            fill(&graphics, circle(inner, 2.3), .black)
        }
        fill(&graphics, circle(headCenter, 11.5), .white)

        // Eyes: look up and to the side while thinking.
        let gaze = isThinking ? CGSize(width: 0.9, height: -1.5) : .zero
        for x in [11.8, 20.2] {
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

    private static func isBlinking(at time: TimeInterval) -> Bool {
        time.truncatingRemainder(dividingBy: 3.6) < 0.13
    }

    // MARK: Talking bear

    static func drawTalkingBear(
        in graphics: inout GraphicsContext,
        time: TimeInterval,
        level: CGFloat,
        mood: TalkingBearView.Mood
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

    private static func drawMicrophone(in graphics: inout GraphicsContext) {
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

    private static func drawSoundArcs(in graphics: inout GraphicsContext, time: TimeInterval, strength: CGFloat) {
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

    private static func drawThoughtDots(in graphics: inout GraphicsContext, time: TimeInterval) {
        let dots: [(CGPoint, CGFloat)] = [
            (CGPoint(x: 31, y: 10.5), 1.2), (CGPoint(x: 35.2, y: 7.5), 1.6), (CGPoint(x: 40, y: 4.5), 2.1),
        ]
        for (index, dot) in dots.enumerated() {
            let pulse = 0.35 + 0.65 * max(0, sin(time * 5 - Double(index) * 0.9))
            fill(&graphics, circle(dot.0, dot.1), .white.opacity(pulse))
        }
    }

    // MARK: Running teddy

    /// On a 40 x 50 grid, facing right: big head, round tummy with a patch, stubby legs
    /// and fat arms swinging opposite each other. Jumping throws both arms up.
    static func drawRunningTeddy(in graphics: inout GraphicsContext, time: TimeInterval, isJumping: Bool) {
        let stride = time * 16
        let swing = isJumping ? 0 : sin(stride) * 0.75
        if !isJumping {
            graphics.translateBy(x: 0, y: -CGFloat(abs(sin(stride))) * 2)
            drawSpeedLines(in: &graphics)
        }

        // Legs and feet behind the tummy.
        // Each leg lifts (gets shorter) as it swings forward, so the stride reads clearly.
        let legSwing = swing * 0.55
        let leftLift = isJumping ? 2 : CGFloat(max(0, legSwing)) * 3.2
        let rightLift = isJumping ? 2 : CGFloat(max(0, -legSwing)) * 3.2
        limb(&graphics, from: CGPoint(x: 15.2, y: 37.5), angle: isJumping ? -0.35 : legSwing, length: 6.5 - leftLift, width: 6.6, end: .foot)
        limb(&graphics, from: CGPoint(x: 24.8, y: 37.5), angle: isJumping ? 0.35 : -legSwing, length: 6.5 - rightLift, width: 6.6, end: .foot)

        // Tummy with the classic teddy belly patch.
        let body = Path(ellipseIn: CGRect(x: 11.5, y: 24.5, width: 17, height: 16))
        fill(&graphics, body, .white)
        graphics.stroke(body, with: .color(.black), lineWidth: outline)
        let patch = Path(ellipseIn: CGRect(x: 15.6, y: 29.5, width: 8.8, height: 8))
        graphics.stroke(patch, with: .color(.black), lineWidth: 0.8)

        // Fat arms, swinging opposite the legs; straight up when jumping.
        let armAngle = isJumping ? 2.5 : -swing
        limb(&graphics, from: CGPoint(x: 12.6, y: 28.5), angle: isJumping ? -armAngle : armAngle - 0.35, length: 6.4, width: 6, end: .paw)
        limb(&graphics, from: CGPoint(x: 27.4, y: 28.5), angle: isJumping ? armAngle : -armAngle + 0.35, length: 6.4, width: 6, end: .paw)

        // The pill bear's head, scaled onto the body, grinning.
        var head = graphics
        head.translateBy(x: 20 - 16 * 0.82, y: 15 - 18.5 * 0.82)
        head.scaleBy(x: 0.82, y: 0.82)
        drawHead(
            in: &head,
            mouthOpen: 0.55 + 0.15 * CGFloat(abs(sin(stride * 0.5))),
            isBlinking: false,
            isThinking: false
        )
    }

    private enum LimbEnd {
        case foot
        case paw
    }

    /// A rounded, outlined limb hanging from `from`; `angle` swings it (0 = straight down,
    /// positive = forward, to the right).
    private static func limb(
        _ graphics: inout GraphicsContext,
        from start: CGPoint,
        angle: Double,
        length: CGFloat,
        width: CGFloat,
        end: LimbEnd
    ) {
        let tip = CGPoint(x: start.x + CGFloat(sin(angle)) * length, y: start.y + CGFloat(cos(angle)) * length)
        var path = Path()
        path.move(to: start)
        path.addLine(to: tip)
        graphics.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: width + outline * 2, lineCap: .round))
        graphics.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: width, lineCap: .round))

        switch end {
        case .foot:
            let foot = Path(ellipseIn: CGRect(x: tip.x - 3, y: tip.y - 1.2, width: 7.4, height: 4.4))
            fill(&graphics, foot, .white)
            graphics.stroke(foot, with: .color(.black), lineWidth: outline)
            fill(&graphics, Path(ellipseIn: CGRect(x: tip.x + 0.4, y: tip.y + 0.1, width: 3, height: 1.9)), .black)
        case .paw:
            let paw = circle(tip, width / 2 + 0.4)
            fill(&graphics, paw, .white)
            graphics.stroke(paw, with: .color(.black), lineWidth: outline)
        }
    }

    private static func drawSpeedLines(in graphics: inout GraphicsContext) {
        var lines = Path()
        for (y, length) in [(27.0, 4.5), (32.0, 6.0), (37.0, 3.5)] {
            lines.move(to: CGPoint(x: 6 - length, y: y))
            lines.addLine(to: CGPoint(x: 6, y: y))
        }
        graphics.stroke(lines, with: .color(.white), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
        graphics.stroke(lines, with: .color(.black), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
    }

    private static func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private static func fill(_ graphics: inout GraphicsContext, _ path: Path, _ color: Color) {
        graphics.fill(path, with: .color(color))
    }
}
