import CoreGraphics
import Foundation

/// The Dougie as a timeline of body poses. One loop is four beats at 85 BPM (about 2.82 s).
/// Beats 1 and 2 are authored as keyframes; beats 3 and 4 are their mirror image, so the
/// lean, the stepping foot and the sweeping paw swap sides every two beats.
enum TeddyDougie {
    static let bpm = 85.0
    static let beatsPerLoop = 4
    static let loopCount = 4
    static let beatSeconds: TimeInterval = 60 / bpm
    static let loopSeconds: TimeInterval = beatSeconds * Double(beatsPerLoop)
    static let danceSeconds: TimeInterval = loopSeconds * Double(loopCount)

    /// Eight keyframes per loop (the counts 1 & 2 & 3 & 4 &), evenly spaced.
    static let keysPerLoop = 8

    // MARK: Keyframes

    static let leftShoulder = CGPoint(x: 12.6, y: 28.5)
    static let rightShoulder = CGPoint(x: 27.4, y: 28.5)

    private static func limb(_ angle: Double, _ length: CGFloat) -> TeddyBodyPose.Limb {
        .init(angle: angle, length: length)
    }

    private static func key(
        lean: Double, bob: CGFloat, hip: CGFloat, head: Double,
        leftArm: TeddyBodyPose.Limb, rightArm: TeddyBodyPose.Limb,
        leftLeg: TeddyBodyPose.Limb, rightLeg: TeddyBodyPose.Limb, mouth: CGFloat
    ) -> TeddyBodyPose {
        var pose = TeddyBodyPose()
        pose.leanDegrees = lean
        pose.bob = bob
        pose.hipShift = hip
        pose.feetPlanted = true
        pose.headTiltDegrees = head
        pose.leftArm = leftArm
        pose.rightArm = rightArm
        pose.leftLeg = leftLeg
        pose.rightLeg = rightLeg
        pose.face = .init(mouthOpen: mouth, isBlinking: false, winks: false)
        return pose
    }

    /// Counts 1, &, 2, & (lean to the viewer's right, left paw sweeping over the head).
    /// Angles run past pi on purpose: the paw travels over the top of the head.
    private static let firstHalf: [TeddyBodyPose] = [
        // 1: deep knee bend, step right (weight on right), paw at the left forehead, right arm swung out.
        key(lean: 12, bob: -4, hip: 1.5, head: 6,
            leftArm: limb(2.95, 15.5), rightArm: limb(0.9, 6.4),
            leftLeg: limb(-0.06, 5.2), rightLeg: limb(0.28, 5.2), mouth: 0.9),
        // &: rise, paw slides over the top-left of the head.
        key(lean: 12, bob: 0, hip: 1.2, head: 8,
            leftArm: limb(3.3, 16), rightArm: limb(0.8, 6.4),
            leftLeg: limb(-0.05, 6.5), rightLeg: limb(0.2, 6.5), mouth: 0.65),
        // 2: left foot taps beside the right, paw passes behind the left ear.
        key(lean: 10, bob: -2.5, hip: 0.6, head: 6,
            leftArm: limb(3.55, 14.5), rightArm: limb(0.7, 6.4),
            leftLeg: limb(0.2, 6), rightLeg: limb(0.1, 5.6), mouth: 0.9),
        // &: weight transfer, left arm drops, right arm rises.
        key(lean: 0, bob: 1, hip: -0.4, head: 0,
            leftArm: limb(5.75, 6.4), rightArm: limb(1.9, 9),
            leftLeg: limb(0.06, 6.5), rightLeg: limb(0.06, 6.5), mouth: 0.65),
    ]

    /// Left and right swapped: negated lean, tilt, hip shift and angles.
    static func mirrored(_ pose: TeddyBodyPose) -> TeddyBodyPose {
        var m = pose
        m.leanDegrees = -pose.leanDegrees
        m.headTiltDegrees = -pose.headTiltDegrees
        m.hipShift = -pose.hipShift
        m.leftArm = limb(-pose.rightArm.angle, pose.rightArm.length)
        m.rightArm = limb(-pose.leftArm.angle, pose.leftArm.length)
        m.leftLeg = limb(-pose.rightLeg.angle, pose.rightLeg.length)
        m.rightLeg = limb(-pose.leftLeg.angle, pose.leftLeg.length)
        return m
    }

    /// Eight keyframes, then the first again to close the loop. Limb angles are unwrapped so
    /// that interpolating takes the short way round.
    static let keyframes: [TeddyBodyPose] = {
        var keys = firstHalf + firstHalf.map(mirrored)
        keys.append(keys[0])
        for i in 1..<keys.count {
            keys[i].leftArm.angle = unwrapped(keys[i].leftArm.angle, near: keys[i - 1].leftArm.angle)
            keys[i].rightArm.angle = unwrapped(keys[i].rightArm.angle, near: keys[i - 1].rightArm.angle)
            keys[i].leftLeg.angle = unwrapped(keys[i].leftLeg.angle, near: keys[i - 1].leftLeg.angle)
            keys[i].rightLeg.angle = unwrapped(keys[i].rightLeg.angle, near: keys[i - 1].rightLeg.angle)
        }
        return keys
    }()

    private static func unwrapped(_ angle: Double, near reference: Double) -> Double {
        let turn = 2 * Double.pi
        return angle - turn * ((angle - reference) / turn).rounded()
    }

    /// Wraps an angle into -pi...pi.
    static func normalized(_ angle: Double) -> Double {
        unwrapped(angle, near: 0)
    }

    // MARK: Interpolation

    static func smoothstep(_ t: Double) -> Double {
        let c = min(max(t, 0), 1)
        return c * c * (3 - 2 * c)
    }

    private static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    private static func mix(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }

    private static func mix(_ a: TeddyBodyPose.Limb, _ b: TeddyBodyPose.Limb, _ t: Double) -> TeddyBodyPose.Limb {
        limb(normalized(mix(a.angle, b.angle, t)), mix(a.length, b.length, t))
    }

    /// The pose `fraction` of the way through one loop (wraps), easing in and out of each key.
    /// Limb angles come back in -pi...pi.
    static func pose(atLoopFraction fraction: Double) -> TeddyBodyPose {
        let wrapped = fraction - fraction.rounded(.down)
        let scaled = wrapped * Double(keysPerLoop)
        let index = min(Int(scaled), keysPerLoop - 1)
        let t = smoothstep(scaled - Double(index))
        let a = keyframes[index]
        let b = keyframes[index + 1]
        var pose = a
        pose.leanDegrees = mix(a.leanDegrees, b.leanDegrees, t)
        pose.bob = mix(a.bob, b.bob, t)
        pose.hipShift = mix(a.hipShift, b.hipShift, t)
        pose.headTiltDegrees = mix(a.headTiltDegrees, b.headTiltDegrees, t)
        pose.leftArm = mix(a.leftArm, b.leftArm, t)
        pose.rightArm = mix(a.rightArm, b.rightArm, t)
        pose.leftLeg = mix(a.leftLeg, b.leftLeg, t)
        pose.rightLeg = mix(a.rightLeg, b.rightLeg, t)
        pose.face.mouthOpen = mix(a.face.mouthOpen, b.face.mouthOpen, t)
        return pose
    }

    /// A blink every other loop, just before the next 1.
    static let blinkLoopFraction = 0.9
    static let blinkSeconds: TimeInterval = 0.14

    static func isBlinking(atDanceTime time: TimeInterval) -> Bool {
        guard time >= 0 else { return false }
        let loop = Int(time / loopSeconds)
        guard loop % 2 == 0 else { return false }
        let start = (Double(loop) + blinkLoopFraction) * loopSeconds
        return time >= start && time < start + blinkSeconds
    }

    /// The pose `time` seconds into the dance: four loops, with a blink now and then.
    static func pose(atDanceTime time: TimeInterval) -> TeddyBodyPose {
        var pose = Self.pose(atLoopFraction: min(max(time, 0), danceSeconds) / loopSeconds)
        pose.face.isBlinking = isBlinking(atDanceTime: time)
        return pose
    }

    // MARK: Routine

    /// Jump out, run to the middle, dance four loops, run back, jump in.
    static func routine(screenSize: CGSize, home: CGPoint, margin: CGFloat) -> TeddyRoutine {
        let landing = TeddyRoutine.landing(for: home, screenSize: screenSize, margin: margin)
        let middle = TeddyWiggle.middle(landing: landing, screenSize: screenSize)
        let jumpOut = TeddyRoutine.jump(from: home, to: landing, leavingHome: true)
        let runOut = TeddyRoutine.run(from: landing, to: middle)
        let dance = TeddyRoutine.hold(at: middle, seconds: danceSeconds) { fraction in
            .posed(pose(atDanceTime: fraction * danceSeconds))
        }
        let danceStart = jumpOut.duration + runOut.duration
        var routine = TeddyRoutine(steps: [
            jumpOut,
            runOut,
            dance,
            TeddyRoutine.run(from: middle, to: landing),
            TeddyRoutine.jump(from: landing, to: home, leavingHome: false),
        ])
        routine.beatWindow = danceStart...(danceStart + danceSeconds)
        return routine
    }
}
