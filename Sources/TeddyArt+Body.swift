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

    /// Shoulder points for a pose: lifted or dropped, pulled in with the narrowed torso, and
    /// the far one drawn further in when the chest turns.
    static func shoulders(for pose: TeddyBodyPose) -> (left: CGPoint, right: CGPoint) {
        let narrow = 1 - abs(pose.twist) * twistNarrowing
        let farIn = CGFloat(abs(pose.twist)) * 1.0
        var left = CGPoint(x: 20 + (leftShoulder.x - 20) * CGFloat(narrow), y: leftShoulder.y - pose.leftShoulderLift)
        var right = CGPoint(x: 20 + (rightShoulder.x - 20) * CGFloat(narrow), y: rightShoulder.y - pose.rightShoulderLift)
        // Shoulder of the side turning away goes inward; the near one comes a little forward.
        if pose.twist > 0 { left.x += farIn; right.x += farIn * 0.3 } else if pose.twist < 0 { right.x -= farIn; left.x -= farIn * 0.3 }
        return (left, right)
    }
    /// Where the feet touch the ground; the whole bear leans about this point.
    static let groundPoint = CGPoint(x: 20, y: 46)
    /// Tilt of the upper body per grid point of hip shift (a full wiggle is 3.2 points).
    static let hipTiltPerPoint: Double = 0.18 / 3.2

    /// Draws any `TeddyBodyPose`, front or back, in the given outfit.
    static func drawBody(
        in graphics: inout GraphicsContext,
        time: TimeInterval,
        pose: TeddyBodyPose,
        outfit: TeddyOutfit,
        look: SpokenLook = .none
    ) {
        // With planted feet the body leans and drops from the hips (like a person bending their
        // knees); otherwise the whole bear tips about the ground point.
        let pivot = pose.feetPlanted ? hipCenter : groundPoint
        var body = graphics
        body.translateBy(x: 0, y: -pose.bob)
        if pose.leanDegrees != 0 {
            body.translateBy(x: pivot.x, y: pivot.y)
            body.rotate(by: .degrees(pose.leanDegrees))
            body.translateBy(x: -pivot.x, y: -pivot.y)
        }
        if pose.showsSpeedLines { drawSpeedLines(in: &body) }

        let isBack = pose.side == .back
        let legs = [(leftHip, pose.leftLeg, true), (rightHip, pose.rightLeg, false)]
        for (hip, limb, isLeft) in legs {
            if pose.feetPlanted {
                var ground = graphics
                drawPlantedLeg(in: &ground, hip: hip, limb: limb, pose: pose, pivot: pivot, outfit: outfit, isLeft: isLeft)
            } else {
                drawLeg(in: &body, hip: hip, limb: limb, pose: pose, outfit: outfit, isLeft: isLeft)
            }
        }

        // Hips, tummy and arms sway together, tilting against the hip shift.
        var upper = body
        upper.translateBy(x: 20 + pose.hipShift, y: 32)
        upper.rotate(by: .radians(-Double(pose.hipShift) * hipTiltPerPoint))
        upper.translateBy(x: -20, y: -32)
        if isBack {
            drawBackTorso(in: &upper, outfit: outfit, pose: pose)
        } else if look != .none {
            drawFrontRobe(in: &upper, look: look)
        } else {
            drawFrontTorso(in: &upper, outfit: outfit, pose: pose)
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
                isThinking: pose.face.isThinking,
                winks: pose.face.winks,
                eyes: TeddyFace.Eyes(pose.face.eyes),
                mouth: TeddyFace.Mouth(pose.face.mouth),
                raisedBrows: pose.face.raisedBrows,
                eyesClosed: pose.face.eyesClosed,
                earLift: pose.face.earLift,
                grumpy: pose.face.grumpy
            )
            drawHead(in: &head, face: face, outfit: outfit, faceShift: CGFloat(pose.twist) * 2.2, look: look)
            if pose.headProp == .nightcap { drawNightcap(in: &head) }
            if pose.headProp == .headphones { drawHeadphones(in: &head) }
        }

        // Arms last, so a paw reaching for the head passes in front of it.
        let points = shoulders(for: pose)
        let tips = [
            drawArm(in: &upper, shoulder: points.left, limb: pose.leftArm, forearm: pose.leftForearm, outfit: outfit, paw: .round, look: look),
            drawArm(in: &upper, shoulder: points.right, limb: pose.rightArm, forearm: pose.rightForearm, outfit: outfit, paw: pose.rightPaw, look: look),
        ]
        drawHeldProp(pose.heldProp, in: &upper, paw: tips[1], time: time)
        if pose.showsSparkle {
            let anchor = pose.rightPaw == .thumbsUp ? CGPoint(x: tips[1].x + 5, y: tips[1].y - 6.5) : CGPoint(x: 33.5, y: 9)
            drawSparkle(in: &upper, at: anchor, size: 2.4, time: time)
        }
    }

    // MARK: Limbs

    static let hipCenter = CGPoint(x: 20, y: 37.5)
    /// Hip to sole when standing straight.
    static let standingLegLength: CGFloat = 6.5

    /// A leg whose foot stays on the ground (at its stepped or tapped spot) while the hip moves
    /// with the body's drop, lean and sway; the knee bows outwards when the hip comes down.
    static func drawPlantedLeg(
        in graphics: inout GraphicsContext,
        hip: CGPoint,
        limb: TeddyBodyPose.Limb,
        pose: TeddyBodyPose,
        pivot: CGPoint,
        outfit: TeddyOutfit,
        isLeft: Bool
    ) {
        // Where the hip ends up: swayed, leaned about the pivot, dropped by the bob.
        let swayed = CGPoint(x: hip.x + pose.hipShift, y: hip.y)
        let radians = pose.leanDegrees * .pi / 180
        let dx = Double(swayed.x - pivot.x), dy = Double(swayed.y - pivot.y)
        let start = CGPoint(
            x: pivot.x + CGFloat(dx * cos(radians) - dy * sin(radians)),
            y: pivot.y + CGFloat(dx * sin(radians) + dy * cos(radians)) - pose.bob
        )
        let shift = isLeft ? pose.leftFootShift : pose.rightFootShift
        let lift = isLeft ? pose.leftFootLift : pose.rightFootLift
        let tip = CGPoint(
            x: hip.x + CGFloat(sin(limb.angle)) * standingLegLength + shift,
            y: hip.y + standingLegLength - lift
        )
        // Knee bend: the closer hip and foot, the more the knee bows outwards.
        let chord = CGPoint(x: tip.x - start.x, y: tip.y - start.y)
        let chordLength = max(0.001, hypot(chord.x, chord.y))
        let natural = standingLegLength + 0.6
        let bend = max(0.4, sqrt(max(0, natural * natural - chordLength * chordLength)) * 0.55)
        var normal = CGPoint(x: chord.y / chordLength, y: -chord.x / chordLength)
        if (normal.x < 0) != isLeft { normal = CGPoint(x: -normal.x, y: -normal.y) }
        let knee = CGPoint(x: (start.x + tip.x) / 2 + normal.x * bend, y: (start.y + tip.y) / 2 + normal.y * bend)
        var path = Path()
        path.move(to: start)
        path.addQuadCurve(to: tip, control: knee)
        stroke(&graphics, path, TeddyPalette.ink, width: 6.6 + outline * 2)
        stroke(&graphics, path, outfit == .suit ? TeddyPalette.suit : TeddyPalette.jeans, width: 6.6)
        if outfit == .hoodie { drawJeansDetail(in: &graphics, along: path, isLeft: isLeft, isBack: pose.side == .back) }
        let tilt = pose.side == .front ? min(0.55, Double(max(0, lift)) * 0.2) : 0
        drawShoe(in: &graphics, at: tip, isLeft: isLeft, isBack: pose.side == .back, outfit: outfit, tilt: tilt)
    }

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
        let shift = isLeft ? pose.leftFootShift : pose.rightFootShift
        let lift = isLeft ? pose.leftFootLift : pose.rightFootLift
        let tip = CGPoint(
            x: base.x + CGFloat(sin(limb.angle)) * limb.length + shift,
            y: base.y + CGFloat(cos(limb.angle)) * limb.length - lift
        )
        // A stepped-out or tapping foot bends the leg a little, knee bowing outwards.
        var path = Path()
        path.move(to: start)
        let bend = min(2.2, abs(shift) * 0.2 + max(0, lift) * 0.35)
        if bend > 0.05 {
            let chord = CGPoint(x: tip.x - start.x, y: tip.y - start.y)
            let chordLength = max(0.001, hypot(chord.x, chord.y))
            var normal = CGPoint(x: chord.y / chordLength, y: -chord.x / chordLength)
            if (normal.x < 0) != isLeft { normal = CGPoint(x: -normal.x, y: -normal.y) }
            let control = CGPoint(x: (start.x + tip.x) / 2 + normal.x * bend * 2, y: (start.y + tip.y) / 2 + normal.y * bend * 2)
            path.addQuadCurve(to: tip, control: control)
        } else {
            path.addLine(to: tip)
        }
        stroke(&graphics, path, TeddyPalette.ink, width: 6.6 + outline * 2)
        stroke(&graphics, path, outfit == .suit ? TeddyPalette.suit : TeddyPalette.jeans, width: 6.6)
        if outfit == .hoodie { drawJeansDetail(in: &graphics, along: path, isLeft: isLeft, isBack: pose.side == .back) }
        let tilt = pose.side == .front ? min(0.55, Double(max(0, lift)) * 0.2) : 0
        drawShoe(in: &graphics, at: tip, isLeft: isLeft, isBack: pose.side == .back, outfit: outfit, tilt: tilt)
    }

    /// A fat sleeve from the shoulder with the paw at the end; with a `forearm` it bends at a
    /// rounded elbow (the forearm angle is relative to the upper arm). Returns the paw position.
    @discardableResult
    static func drawArm(
        in graphics: inout GraphicsContext,
        shoulder: CGPoint,
        limb: TeddyBodyPose.Limb,
        forearm: TeddyBodyPose.Limb? = nil,
        outfit: TeddyOutfit,
        paw: TeddyBodyPose.PawShape,
        look: SpokenLook = .none
    ) -> CGPoint {
        let direction = CGPoint(x: CGFloat(sin(limb.angle)), y: CGFloat(cos(limb.angle)))
        let elbow = CGPoint(x: shoulder.x + direction.x * limb.length, y: shoulder.y + direction.y * limb.length)
        let width: CGFloat = 6.2
        let sleeveColor = sleeveColors(outfit: outfit, look: look).sleeve

        var tip = elbow
        var tipDirection = direction
        var tipWidth = width
        if let forearm {
            let angle = limb.angle + forearm.angle
            tipDirection = CGPoint(x: CGFloat(sin(angle)), y: CGFloat(cos(angle)))
            tip = CGPoint(x: elbow.x + tipDirection.x * forearm.length, y: elbow.y + tipDirection.y * forearm.length)
            tipWidth = 5.8
            // One outline for the whole bent arm, then the sleeve colour on top, so the
            // elbow is a round joint with no seam.
            var upper = Path()
            upper.move(to: shoulder)
            upper.addLine(to: elbow)
            var lower = Path()
            lower.move(to: elbow)
            lower.addLine(to: tip)
            // A faint drop shadow so a bent arm lifts off the torso it crosses.
            var shadow = Path()
            shadow.addPath(upper)
            shadow.addPath(lower)
            var lowered = graphics
            lowered.translateBy(x: 0.35, y: 0.9)
            stroke(&lowered, shadow, TeddyPalette.ink.opacity(0.22), width: width + outline * 2)
            stroke(&graphics, upper, TeddyPalette.ink, width: width + outline * 2)
            stroke(&graphics, lower, TeddyPalette.ink, width: tipWidth + outline * 2)
            fill(&graphics, circle(elbow, width / 2 + outline), TeddyPalette.ink)
            stroke(&graphics, upper, sleeveColor, width: width)
            stroke(&graphics, lower, sleeveColor, width: tipWidth)
            fill(&graphics, circle(elbow, width / 2), sleeveColor)
        } else {
            var sleeve = Path()
            sleeve.move(to: shoulder)
            sleeve.addLine(to: tip)
            stroke(&graphics, sleeve, TeddyPalette.ink, width: width + outline * 2)
            stroke(&graphics, sleeve, sleeveColor, width: width)
        }
        let cuffLength = forearm?.length ?? limb.length
        if cuffLength > 4.5 {
            var cuff = Path()
            cuff.move(to: CGPoint(x: tip.x - tipDirection.x * 3.7, y: tip.y - tipDirection.y * 3.7))
            cuff.addLine(to: CGPoint(x: tip.x - tipDirection.x * 2.1, y: tip.y - tipDirection.y * 2.1))
            let cuffColor = sleeveColors(outfit: outfit, look: look).cuff
            graphics.stroke(cuff, with: .color(cuffColor), style: StrokeStyle(lineWidth: tipWidth, lineCap: .butt))
        }
        switch paw {
        case .round:
            sticker(&graphics, circle(tip, tipWidth / 2 + 0.4), TeddyPalette.fur)
        case .thumbsUp:
            drawThumbsUpFist(in: &graphics, at: tip)
        case .fist:
            drawClenchedFist(in: &graphics, at: tip, direction: tipDirection)
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
