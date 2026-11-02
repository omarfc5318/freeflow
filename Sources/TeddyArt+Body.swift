import SwiftUI

// Full-body teddy: front and back views used by the voice tricks. Every action, from the
// old running/jumping/standing/thumbs-up/wiggling to the numeric `.posed` dance poses,
// ends up in the one renderer `drawBody`.
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
        case let .posed(pose):
            drawBody(in: &graphics, time: time, pose: pose, outfit: outfit)
        case .running:
            drawBody(in: &graphics, time: time, pose: runningPose(time: time), outfit: outfit)
        case .jumping:
            drawBody(in: &graphics, time: time, pose: jumpingPose(time: time), outfit: outfit)
        case .standing:
            drawBody(in: &graphics, time: time, pose: standingPose(time: time), outfit: outfit)
        case .thumbsUp:
            drawBody(in: &graphics, time: time, pose: thumbsUpPose(), outfit: outfit)
        case let .wiggling(phase):
            drawBody(in: &graphics, time: time, pose: wigglePose(sway: CGFloat(sin(phase * 2 * .pi))), outfit: outfit)
        case let .turning(towardBack, progress):
            // Squash to a sliver and switch sides halfway, like spinning on the spot.
            let squash = max(0.08, CGFloat(abs(cos(progress * .pi))))
            graphics.translateBy(x: 20, y: 0)
            graphics.scaleBy(x: squash, y: 1)
            graphics.translateBy(x: -20, y: 0)
            let showsBack = towardBack ? progress >= 0.5 : progress < 0.5
            let pose = showsBack ? wigglePose(sway: 0) : standingPose(time: time)
            drawBody(in: &graphics, time: time, pose: pose, outfit: outfit)
        }
    }

    // MARK: Poses for the classic actions

    static func standingPose(time: TimeInterval) -> TeddyBodyPose {
        var pose = TeddyBodyPose.standing
        pose.face.isBlinking = isBlinking(at: time)
        return pose
    }

    /// Fat arms swing opposite stubby legs, and the whole bear bounces.
    static func runningPose(time: TimeInterval) -> TeddyBodyPose {
        let stride = time * 16
        let swing = sin(stride) * 0.75
        let legSwing = swing * 0.55
        var pose = TeddyBodyPose.standing
        pose.bob = CGFloat(abs(sin(stride))) * 2
        pose.leftLeg = .init(angle: legSwing, length: 6.5 - CGFloat(max(0, legSwing)) * 3.2)
        pose.rightLeg = .init(angle: -legSwing, length: 6.5 - CGFloat(max(0, -legSwing)) * 3.2)
        pose.leftArm = .init(angle: -swing - 0.35, length: 6.4)
        pose.rightArm = .init(angle: swing + 0.35, length: 6.4)
        pose.face.mouthOpen = 0.55 + 0.15 * CGFloat(abs(sin(stride * 0.5)))
        pose.showsSpeedLines = true
        return pose
    }

    /// Both arms thrown up, legs tucked and splayed.
    static func jumpingPose(time: TimeInterval) -> TeddyBodyPose {
        var pose = TeddyBodyPose.standing
        pose.leftLeg = .init(angle: -0.35, length: 4.5)
        pose.rightLeg = .init(angle: 0.35, length: 4.5)
        pose.leftArm = .init(angle: -2.5, length: 6.4)
        pose.rightArm = .init(angle: 2.5, length: 6.4)
        pose.face.mouthOpen = 0.55 + 0.15 * CGFloat(abs(sin(time * 8)))
        return pose
    }

    static func thumbsUpPose() -> TeddyBodyPose {
        var pose = TeddyBodyPose.standing
        pose.leftArm = .init(angle: -0.3, length: 6.4)
        pose.rightArm = .init(angle: 2.35, length: 6.4)
        pose.rightPaw = .thumbsUp
        pose.face = .init(mouthOpen: 0.35, isBlinking: false, winks: true)
        pose.showsSparkle = true
        return pose
    }

    /// Seen from behind, hips swaying (`sway` -1...1) while the feet stay planted.
    static func wigglePose(sway: CGFloat) -> TeddyBodyPose {
        var pose = TeddyBodyPose.standing
        pose.side = .back
        pose.hipShift = sway * 3.2
        pose.feetPlanted = true
        pose.leftLeg = .init(angle: -0.092, length: 6.53)
        pose.rightLeg = .init(angle: 0.092, length: 6.53)
        pose.leftArm = .init(angle: -0.4, length: 6.2)
        pose.rightArm = .init(angle: 0.4, length: 6.2)
        return pose
    }

    // MARK: The renderer

    static let bodyRect = CGRect(x: 11.5, y: 24.5, width: 17, height: 16)
    static let leftHip = CGPoint(x: 15.2, y: 37.5)
    static let rightHip = CGPoint(x: 24.8, y: 37.5)
    static let leftShoulder = CGPoint(x: 12.6, y: 28.5)
    static let rightShoulder = CGPoint(x: 27.4, y: 28.5)
    /// Where the feet touch the ground; the whole bear leans about this point.
    static let groundPoint = CGPoint(x: 20, y: 46)
    /// Tilt of the upper body per grid point of hip shift (a full wiggle is 3.2 points).
    static let hipTiltPerPoint: Double = 0.18 / 3.2

    /// Draws any `TeddyBodyPose`, front or back, in the given outfit.
    static func drawBody(in graphics: inout GraphicsContext, time: TimeInterval, pose: TeddyBodyPose, outfit: TeddyOutfit) {
        var body = graphics
        body.translateBy(x: 0, y: -pose.bob)
        if pose.leanDegrees != 0 {
            body.translateBy(x: groundPoint.x, y: groundPoint.y)
            body.rotate(by: .degrees(pose.leanDegrees))
            body.translateBy(x: -groundPoint.x, y: -groundPoint.y)
        }
        if pose.showsSpeedLines { drawSpeedLines(in: &body) }

        let isBack = pose.side == .back
        let legs = [(leftHip, pose.leftLeg, true), (rightHip, pose.rightLeg, false)]
        for (hip, limb, isLeft) in legs {
            drawLeg(in: &body, hip: hip, limb: limb, pose: pose, outfit: outfit, isLeft: isLeft)
        }

        // Hips, tummy and arms sway together, tilting against the hip shift.
        var upper = body
        upper.translateBy(x: 20 + pose.hipShift, y: 32)
        upper.rotate(by: .radians(-Double(pose.hipShift) * hipTiltPerPoint))
        upper.translateBy(x: -20, y: -32)
        if isBack {
            drawBackTorso(in: &upper, outfit: outfit)
        } else {
            drawFrontTorso(in: &upper, outfit: outfit)
        }

        // The pill bear's head, scaled onto the body; it hardly follows the hips.
        var head = body
        head.translateBy(x: -pose.hipShift * 0.156, y: 0)
        head.translateBy(x: 20, y: 24)
        head.rotate(by: .degrees(pose.headTiltDegrees))
        head.translateBy(x: -20, y: -24)
        head.translateBy(x: 20 - 16 * 0.82, y: 15 - 18.5 * 0.82)
        head.scaleBy(x: 0.82, y: 0.82)
        if isBack {
            drawHeadBack(in: &head, outfit: outfit)
        } else {
            let face = TeddyFace(
                mouthOpen: pose.face.mouthOpen,
                isBlinking: pose.face.isBlinking,
                winks: pose.face.winks
            )
            drawHead(in: &head, face: face, outfit: outfit)
        }

        // Arms last, so a paw reaching for the head passes in front of it.
        let tips = [
            drawArm(in: &upper, shoulder: leftShoulder, limb: pose.leftArm, outfit: outfit, paw: .round),
            drawArm(in: &upper, shoulder: rightShoulder, limb: pose.rightArm, outfit: outfit, paw: pose.rightPaw),
        ]
        if pose.showsSparkle {
            let anchor = pose.rightPaw == .thumbsUp ? CGPoint(x: tips[1].x + 5, y: tips[1].y - 6.5) : CGPoint(x: 33.5, y: 9)
            drawSparkle(in: &upper, at: anchor, size: 2.4, time: time)
        }
    }

    // MARK: Limbs

    static func drawLeg(
        in graphics: inout GraphicsContext,
        hip: CGPoint,
        limb: TeddyBodyPose.Limb,
        pose: TeddyBodyPose,
        outfit: TeddyOutfit,
        isLeft: Bool
    ) {
        let start = CGPoint(x: hip.x + pose.hipShift, y: hip.y)
        let base = pose.feetPlanted ? hip : start
        let tip = CGPoint(x: base.x + CGFloat(sin(limb.angle)) * limb.length, y: base.y + CGFloat(cos(limb.angle)) * limb.length)
        var path = Path()
        path.move(to: start)
        path.addLine(to: tip)
        stroke(&graphics, path, TeddyPalette.ink, width: 6.6 + outline * 2)
        stroke(&graphics, path, outfit == .suit ? TeddyPalette.suit : TeddyPalette.jeans, width: 6.6)
        drawShoe(in: &graphics, at: tip, isLeft: isLeft, isBack: pose.side == .back, outfit: outfit)
    }

    /// A fat sleeve the whole way from the shoulder, with the paw at the end. Returns the tip.
    @discardableResult
    static func drawArm(
        in graphics: inout GraphicsContext,
        shoulder: CGPoint,
        limb: TeddyBodyPose.Limb,
        outfit: TeddyOutfit,
        paw: TeddyBodyPose.PawShape
    ) -> CGPoint {
        let direction = CGPoint(x: CGFloat(sin(limb.angle)), y: CGFloat(cos(limb.angle)))
        let tip = CGPoint(x: shoulder.x + direction.x * limb.length, y: shoulder.y + direction.y * limb.length)
        let width: CGFloat = 6.2
        var sleeve = Path()
        sleeve.move(to: shoulder)
        sleeve.addLine(to: tip)
        stroke(&graphics, sleeve, TeddyPalette.ink, width: width + outline * 2)
        stroke(&graphics, sleeve, outfit == .suit ? TeddyPalette.suit : TeddyPalette.hoodie, width: width)
        if limb.length > 4.5 {
            var cuff = Path()
            cuff.move(to: CGPoint(x: tip.x - direction.x * 3.7, y: tip.y - direction.y * 3.7))
            cuff.addLine(to: CGPoint(x: tip.x - direction.x * 2.1, y: tip.y - direction.y * 2.1))
            let cuffColor = outfit == .suit ? TeddyPalette.shirt : TeddyPalette.hoodieDark
            graphics.stroke(cuff, with: .color(cuffColor), style: StrokeStyle(lineWidth: width, lineCap: .butt))
        }
        switch paw {
        case .round:
            sticker(&graphics, circle(tip, width / 2 + 0.4), TeddyPalette.fur)
        case .thumbsUp:
            drawThumbsUpFist(in: &graphics, at: tip)
        }
        return tip
    }

    /// A classic thumbs up: a chunky fist with curled fingers on the outer side and a short,
    /// wide thumb rising from its inner top corner, sharing one outline.
    static func drawThumbsUpFist(in graphics: inout GraphicsContext, at center: CGPoint) {
        let fist = Path(roundedRect: CGRect(x: center.x - 3.4, y: center.y - 2.6, width: 6.8, height: 6.2), cornerRadius: 2.4)
        var thumb = Path()
        thumb.move(to: CGPoint(x: center.x - 1.5, y: center.y - 1.6))
        thumb.addLine(to: CGPoint(x: center.x - 2.3, y: center.y - 5.4))

        stroke(&graphics, thumb, TeddyPalette.ink, width: 3.6 + outline * 2)
        graphics.stroke(fist, with: .color(TeddyPalette.ink), lineWidth: outline * 2)
        stroke(&graphics, thumb, TeddyPalette.fur, width: 3.6)
        fill(&graphics, fist, TeddyPalette.fur)

        var curls = Path()
        for y in [center.y - 0.7, center.y + 0.9, center.y + 2.4] {
            curls.move(to: CGPoint(x: center.x + 0.6, y: y))
            curls.addLine(to: CGPoint(x: center.x + 3.3, y: y))
        }
        stroke(&graphics, curls, TeddyPalette.ink, width: 0.7)
    }

    // MARK: Effects

    static func drawSparkle(in graphics: inout GraphicsContext, at center: CGPoint, size: CGFloat, time: TimeInterval) {
        let pulse = 0.75 + 0.25 * CGFloat(sin(time * 8))
        let r = size * pulse
        var star = Path()
        star.move(to: CGPoint(x: center.x, y: center.y - r))
        star.addQuadCurve(to: CGPoint(x: center.x + r, y: center.y), control: center)
        star.addQuadCurve(to: CGPoint(x: center.x, y: center.y + r), control: center)
        star.addQuadCurve(to: CGPoint(x: center.x - r, y: center.y), control: center)
        star.addQuadCurve(to: CGPoint(x: center.x, y: center.y - r), control: center)
        graphics.stroke(star, with: .color(TeddyPalette.ink), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
        fill(&graphics, star, Color(red: 1.0, green: 0.88, blue: 0.3))
    }

    static func drawSpeedLines(in graphics: inout GraphicsContext) {
        var lines = Path()
        for (y, length) in [(27.0, 4.5), (32.0, 6.0), (37.0, 3.5)] {
            lines.move(to: CGPoint(x: 6 - length, y: y))
            lines.addLine(to: CGPoint(x: 6, y: y))
        }
        stroke(&graphics, lines, TeddyPalette.ink, width: 2.8)
        stroke(&graphics, lines, .white, width: 1.3)
    }
}
