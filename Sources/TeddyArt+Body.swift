import SwiftUI

// Full-body teddy: front and back views used by the voice tricks.
extension TeddyArt {
    // MARK: Full-body teddy

    /// On a 40 x 50 grid: big head, round tummy, stubby legs and fat arms.
    static func drawTeddy(
        in graphics: inout GraphicsContext,
        time: TimeInterval,
        action: TeddyPose.Action,
        outfit: TeddyOutfit = .hoodie
    ) {
        switch action {
        case .posed:
            drawFrontTeddy(in: &graphics, time: time, pose: .standing)
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

    enum FrontPose {
        case running
        case jumping
        case standing
        case thumbsUp
    }

    static let bodyRect = CGRect(x: 11.5, y: 24.5, width: 17, height: 16)
    static let leftHip = CGPoint(x: 15.2, y: 37.5)
    static let rightHip = CGPoint(x: 24.8, y: 37.5)
    static let leftShoulder = CGPoint(x: 12.6, y: 28.5)
    static let rightShoulder = CGPoint(x: 27.4, y: 28.5)

    /// Facing the viewer. Running swings fat arms opposite stubby legs; jumping throws both
    /// arms up; the thumbs up raises one paw and winks.
    static func drawFrontTeddy(in graphics: inout GraphicsContext, time: TimeInterval, pose: FrontPose) {
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
    static func drawBackTeddy(in graphics: inout GraphicsContext, sway: CGFloat) {
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

    static func drawTummy(in graphics: inout GraphicsContext, withPatch: Bool) {
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
    static func drawThumbsUpFist(in graphics: inout GraphicsContext, at center: CGPoint) {
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

    static func drawSparkle(in graphics: inout GraphicsContext, at center: CGPoint, size: CGFloat, time: TimeInterval) {
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

    enum LimbEnd {
        case foot
        case heel
        case paw
        case none
    }

    /// A rounded, outlined limb hanging from `start`; `angle` swings it (0 = straight down,
    /// positive = to the right). Returns where it ends.
    @discardableResult
    static func limb(
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

    static func limb(_ graphics: inout GraphicsContext, from start: CGPoint, to tip: CGPoint, width: CGFloat, end: LimbEnd) {
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

    static func drawSpeedLines(in graphics: inout GraphicsContext) {
        var lines = Path()
        for (y, length) in [(27.0, 4.5), (32.0, 6.0), (37.0, 3.5)] {
            lines.move(to: CGPoint(x: 6 - length, y: y))
            lines.addLine(to: CGPoint(x: 6, y: y))
        }
        graphics.stroke(lines, with: .color(.white), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
        graphics.stroke(lines, with: .color(.black), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
    }
}
