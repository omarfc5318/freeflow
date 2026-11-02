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

// MARK: - Learned-word card (pill)

/// The pill bear peeking in with one paw on a white card that shows the words it just
/// learned from the user's corrections.
struct LearnedWordView: View {
    let label: String

    var body: some View {
        HStack(spacing: -7) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                Canvas { graphics, size in
                    let scale = size.height / 32
                    graphics.scaleBy(x: scale, y: scale)
                    TeddyArt.drawBearHoldingCard(in: &graphics, time: context.date.timeIntervalSinceReferenceDate)
                }
            }
            .frame(width: 30 * 36 / 32, height: 30)
            .zIndex(1)

            VStack(alignment: .leading, spacing: 0) {
                Text("Learned")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.55))
                Text(label)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black)
                    .lineLimit(1)
            }
            .padding(.leading, 11)
            .padding(.trailing, 8)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(.white))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Learned \(label)")
    }
}

// MARK: - Full-body teddy (voice tricks)

/// The same bear, full body: a chubby teddy on two feet with fat arms.
struct TeddyFigureView: View {
    let time: TimeInterval
    var action: TeddyPose.Action = .running
    var height: CGFloat = TeddyTripController.bearHeight

    static let gridSize = CGSize(width: 40, height: 50)

    var body: some View {
        Canvas { graphics, size in
            let scale = size.height / Self.gridSize.height
            graphics.scaleBy(x: scale, y: scale)
            TeddyArt.drawTeddy(in: &graphics, time: time, action: action)
        }
        .frame(width: height * Self.gridSize.width / Self.gridSize.height, height: height)
        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
    }
}

/// A whole trick, driven by wall-clock time.
struct TeddyTripView: View {
    let start: Date
    let routine: TeddyRoutine

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
            let elapsed = context.date.timeIntervalSince(start)
            let pose = routine.pose(at: elapsed)
            TeddyFigureView(time: elapsed, action: pose.action)
                .scaleEffect(x: pose.facesRight ? pose.scale : -pose.scale, y: pose.scale)
                .position(pose.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
    }
}

/// Shows a trick in a click-through window above everything. `stop()` removes it at once
/// (for example when a new dictation starts) without calling `onFinished`.
/// Main thread only.
final class TeddyTripController {
    static let bearHeight: CGFloat = 64
    static var margin: CGFloat { bearHeight / 2 + 8 }

    private var panel: NSPanel?
    private var finishWorkItem: DispatchWorkItem?

    var isRunning: Bool { panel != nil }

    /// `home` is the bear's centre in the pill, measured from the top left of `screen`.
    func start(_ trick: TeddyTrick, on screen: NSScreen, home: CGPoint, onFinished: @escaping () -> Void) {
        stop()
        let frame = screen.frame
        let routine = TeddyRoutine.make(trick, screenSize: frame.size, home: home, margin: Self.margin)

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
        panel.contentView = NSHostingView(rootView: TeddyTripView(start: Date(), routine: routine))
        panel.orderFrontRegardless()
        self.panel = panel

        let finish = DispatchWorkItem { [weak self] in
            self?.stop()
            onFinished()
        }
        finishWorkItem = finish
        DispatchQueue.main.asyncAfter(deadline: .now() + routine.duration, execute: finish)
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
/// The pill bear and the full-body teddy share `drawHead`, so the face always matches.
enum TeddyArt {
    private static let outline: CGFloat = 1.1

    // MARK: Head (shared)

    /// Drawn on a grid where the head's centre is (16, 18.5) and the ears reach y = 3.
    /// The black rim behind every shape keeps the bear readable on any background.
    private static func drawHead(
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
    private static func drawHeadShape(in graphics: inout GraphicsContext, innerEars: Bool) {
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

    /// On a 36 x 32 grid: the pill bear's head, smiling, with a paw at the right edge
    /// that rests on the card next to it.
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

    // MARK: Full-body teddy

    /// On a 40 x 50 grid: big head, round tummy, stubby legs and fat arms.
    static func drawTeddy(in graphics: inout GraphicsContext, time: TimeInterval, action: TeddyPose.Action) {
        switch action {
        case .running:
            drawFrontTeddy(in: &graphics, time: time, pose: .running)
        case .jumping:
            drawFrontTeddy(in: &graphics, time: time, pose: .jumping)
        case .standing:
            drawFrontTeddy(in: &graphics, time: time, pose: .standing)
        case .thumbsUp:
            drawFrontTeddy(in: &graphics, time: time, pose: .thumbsUp)
        case let .wiggling(phase):
            drawBackTeddy(in: &graphics, sway: CGFloat(sin(phase * 2 * .pi)))
        case let .turning(towardBack, progress):
            // Squash to a sliver and switch sides halfway, like spinning on the spot.
            let squash = max(0.08, CGFloat(abs(cos(progress * .pi))))
            graphics.translateBy(x: 20, y: 0)
            graphics.scaleBy(x: squash, y: 1)
            graphics.translateBy(x: -20, y: 0)
            let showsBack = towardBack ? progress >= 0.5 : progress < 0.5
            if showsBack {
                drawBackTeddy(in: &graphics, sway: 0)
            } else {
                drawFrontTeddy(in: &graphics, time: time, pose: .standing)
            }
        }
    }

    private enum FrontPose {
        case running
        case jumping
        case standing
        case thumbsUp
    }

    private static let bodyRect = CGRect(x: 11.5, y: 24.5, width: 17, height: 16)
    private static let leftHip = CGPoint(x: 15.2, y: 37.5)
    private static let rightHip = CGPoint(x: 24.8, y: 37.5)
    private static let leftShoulder = CGPoint(x: 12.6, y: 28.5)
    private static let rightShoulder = CGPoint(x: 27.4, y: 28.5)

    /// Facing the viewer. Running swings fat arms opposite stubby legs; jumping throws both
    /// arms up; the thumbs up raises one paw and winks.
    private static func drawFrontTeddy(in graphics: inout GraphicsContext, time: TimeInterval, pose: FrontPose) {
        let stride = time * 16
        let swing = pose == .running ? sin(stride) * 0.75 : 0
        if pose == .running {
            graphics.translateBy(x: 0, y: -CGFloat(abs(sin(stride))) * 2)
            drawSpeedLines(in: &graphics)
        }

        // Legs and feet behind the tummy; each leg lifts as it swings forward.
        let legSwing = swing * 0.55
        let isJumping = pose == .jumping
        let leftLift = isJumping ? 2 : CGFloat(max(0, legSwing)) * 3.2
        let rightLift = isJumping ? 2 : CGFloat(max(0, -legSwing)) * 3.2
        limb(&graphics, from: leftHip, angle: isJumping ? -0.35 : legSwing, length: 6.5 - leftLift, width: 6.6, end: .foot)
        limb(&graphics, from: rightHip, angle: isJumping ? 0.35 : -legSwing, length: 6.5 - rightLift, width: 6.6, end: .foot)

        drawTummy(in: &graphics, withPatch: true)

        switch pose {
        case .jumping:
            limb(&graphics, from: leftShoulder, angle: -2.5, length: 6.4, width: 6, end: .paw)
            limb(&graphics, from: rightShoulder, angle: 2.5, length: 6.4, width: 6, end: .paw)
        case .thumbsUp:
            limb(&graphics, from: leftShoulder, angle: -0.3, length: 6.4, width: 6, end: .paw)
            let fist = limb(&graphics, from: rightShoulder, angle: 2.35, length: 6.4, width: 6, end: .none)
            drawThumbsUpFist(in: &graphics, at: fist)
            drawSparkle(in: &graphics, at: CGPoint(x: fist.x + 5, y: fist.y - 6.5), size: 2.4, time: time)
        case .running, .standing:
            limb(&graphics, from: leftShoulder, angle: -swing - 0.35, length: 6.4, width: 6, end: .paw)
            limb(&graphics, from: rightShoulder, angle: swing + 0.35, length: 6.4, width: 6, end: .paw)
        }

        // The pill bear's head, scaled onto the body.
        var head = graphics
        head.translateBy(x: 20 - 16 * 0.82, y: 15 - 18.5 * 0.82)
        head.scaleBy(x: 0.82, y: 0.82)
        let open: CGFloat
        switch pose {
        case .running, .jumping: open = 0.55 + 0.15 * CGFloat(abs(sin(stride * 0.5)))
        case .standing: open = 0
        case .thumbsUp: open = 0.35
        }
        drawHead(
            in: &head,
            mouthOpen: open,
            isBlinking: pose == .standing && isBlinking(at: time),
            isThinking: false,
            winks: pose == .thumbsUp
        )
    }

    /// Seen from behind: plain back of the head, a little round tail, and hips that sway
    /// side to side (`sway` -1...1) while the feet stay planted.
    private static func drawBackTeddy(in graphics: inout GraphicsContext, sway: CGFloat) {
        let hipShift = sway * 3.2
        let footY: CGFloat = 44

        // Planted feet, legs leaning towards the swaying hips.
        for (hip, footX) in [(leftHip, CGFloat(14.6)), (rightHip, CGFloat(25.4))] {
            let shiftedHip = CGPoint(x: hip.x + hipShift, y: hip.y)
            limb(&graphics, from: shiftedHip, to: CGPoint(x: footX, y: footY), width: 6.6, end: .heel)
        }

        // Body and tail swing with the hips and tilt slightly the other way.
        var hips = graphics
        hips.translateBy(x: 20 + hipShift, y: 32)
        hips.rotate(by: .radians(Double(-sway) * 0.18))
        hips.translateBy(x: -20, y: -32)
        drawTummy(in: &hips, withPatch: false)
        // Stitched seam down the back.
        var seam = Path()
        seam.move(to: CGPoint(x: 20, y: 26))
        seam.addLine(to: CGPoint(x: 20, y: 35))
        hips.stroke(seam, with: .color(.black), style: StrokeStyle(lineWidth: 0.7, lineCap: .round, dash: [1.2, 1.2]))
        let tail = circle(CGPoint(x: 20 + sway * 1.4, y: 37.2), 2.9)
        hips.fill(tail, with: .color(.white))
        hips.stroke(tail, with: .color(.black), lineWidth: outline)

        limb(&hips, from: leftShoulder, angle: -0.4, length: 6.2, width: 6, end: .paw)
        limb(&hips, from: rightShoulder, angle: 0.4, length: 6.2, width: 6, end: .paw)

        // Back of the head stays nearly still, nodding along a little.
        var head = graphics
        head.translateBy(x: 20 - 16 * 0.82 - sway * 0.5, y: 15 - 18.5 * 0.82)
        head.scaleBy(x: 0.82, y: 0.82)
        drawHeadShape(in: &head, innerEars: false)
    }

    private static func drawTummy(in graphics: inout GraphicsContext, withPatch: Bool) {
        let body = Path(ellipseIn: bodyRect)
        fill(&graphics, body, .white)
        graphics.stroke(body, with: .color(.black), lineWidth: outline)
        if withPatch {
            let patch = Path(ellipseIn: CGRect(x: 15.6, y: 29.5, width: 8.8, height: 8))
            graphics.stroke(patch, with: .color(.black), lineWidth: 0.8)
        }
    }

    /// A classic thumbs up: a chunky fist with curled fingers on the outer side and a short,
    /// wide thumb rising from its inner top corner, sharing one outline.
    private static func drawThumbsUpFist(in graphics: inout GraphicsContext, at center: CGPoint) {
        let fist = Path(roundedRect: CGRect(x: center.x - 3.4, y: center.y - 2.6, width: 6.8, height: 6.2), cornerRadius: 2.4)
        var thumb = Path()
        thumb.move(to: CGPoint(x: center.x - 1.5, y: center.y - 1.6))
        thumb.addLine(to: CGPoint(x: center.x - 2.3, y: center.y - 5.4))
        let thumbStyle = StrokeStyle(lineWidth: 3.6, lineCap: .round)

        graphics.stroke(thumb, with: .color(.black), style: StrokeStyle(lineWidth: 3.6 + outline * 2, lineCap: .round))
        graphics.stroke(fist, with: .color(.black), lineWidth: outline * 2)
        graphics.stroke(thumb, with: .color(.white), style: thumbStyle)
        fill(&graphics, fist, .white)

        var curls = Path()
        for y in [center.y - 0.7, center.y + 0.9, center.y + 2.4] {
            curls.move(to: CGPoint(x: center.x + 0.6, y: y))
            curls.addLine(to: CGPoint(x: center.x + 3.3, y: y))
        }
        graphics.stroke(curls, with: .color(.black), style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
    }

    private static func drawSparkle(in graphics: inout GraphicsContext, at center: CGPoint, size: CGFloat, time: TimeInterval) {
        let pulse = 0.75 + 0.25 * CGFloat(sin(time * 8))
        let r = size * pulse
        var star = Path()
        star.move(to: CGPoint(x: center.x, y: center.y - r))
        star.addQuadCurve(to: CGPoint(x: center.x + r, y: center.y), control: center)
        star.addQuadCurve(to: CGPoint(x: center.x, y: center.y + r), control: center)
        star.addQuadCurve(to: CGPoint(x: center.x - r, y: center.y), control: center)
        star.addQuadCurve(to: CGPoint(x: center.x, y: center.y - r), control: center)
        graphics.stroke(star, with: .color(.black), lineWidth: 1.6)
        fill(&graphics, star, .white)
    }

    private enum LimbEnd {
        case foot
        case heel
        case paw
        case none
    }

    /// A rounded, outlined limb hanging from `start`; `angle` swings it (0 = straight down,
    /// positive = to the right). Returns where it ends.
    @discardableResult
    private static func limb(
        _ graphics: inout GraphicsContext,
        from start: CGPoint,
        angle: Double,
        length: CGFloat,
        width: CGFloat,
        end: LimbEnd
    ) -> CGPoint {
        let tip = CGPoint(x: start.x + CGFloat(sin(angle)) * length, y: start.y + CGFloat(cos(angle)) * length)
        limb(&graphics, from: start, to: tip, width: width, end: end)
        return tip
    }

    private static func limb(_ graphics: inout GraphicsContext, from start: CGPoint, to tip: CGPoint, width: CGFloat, end: LimbEnd) {
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
        case .heel:
            let heel = Path(ellipseIn: CGRect(x: tip.x - 3.4, y: tip.y - 1.6, width: 6.8, height: 4))
            fill(&graphics, heel, .white)
            graphics.stroke(heel, with: .color(.black), lineWidth: outline)
        case .paw:
            let paw = circle(tip, width / 2 + 0.4)
            fill(&graphics, paw, .white)
            graphics.stroke(paw, with: .color(.black), lineWidth: outline)
        case .none:
            break
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
