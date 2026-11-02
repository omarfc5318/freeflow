import CoreGraphics
import Foundation

/// The Dougie as continuous motion. One loop is four beats at 85 BPM (about 2.82 s); beats 3
/// and 4 mirror beats 1 and 2, so the lean, the stepping foot and the brushing paw swap sides.
enum TeddyDougie {
    static let bpm = 85.0
    static let beatsPerLoop = 4
    static let loopCount = 4
    static let beatSeconds: TimeInterval = 60 / bpm
    static let loopSeconds: TimeInterval = beatSeconds * Double(beatsPerLoop)
    static let danceSeconds: TimeInterval = loopSeconds * Double(loopCount)

    // MARK: Motion

    static let leftShoulder = CGPoint(x: 12.6, y: 28.5)
    static let rightShoulder = CGPoint(x: 27.4, y: 28.5)

    /// Peak lean, reached on counts 1 (right) and 3 (left).
    static let maxLeanDegrees = 13.0
    /// How quickly the weight shifts from side to side (higher is snappier).
    static let rockSharpness = 2.2

    /// The Dougie is one continuous motion, so every part is a smooth curve of the loop
    /// fraction instead of a run of poses (stopping at each pose looked robotic):
    /// - the whole body rocks side to side, leaning into the stepping foot, hips swaying with it;
    /// - the knees dip on every beat;
    /// - the paw on the high-shoulder side draws one circle per loop: up in front of the face to
    ///   the forehead, slowly over the top of the head to behind the ear (the hair brush), then
    ///   down the outside. The right paw does the same half a loop later, mirrored.
    static func pose(atLoopFraction fraction: Double) -> TeddyBodyPose {
        let t = fraction - fraction.rounded(.down)
        // A weight shift, not a pendulum: the body moves onto the stepping foot fairly quickly
        // and rides it out, which also gives the ragdoll parts something to follow through on.
        let rock = tanh(rockSharpness * cos(2 * .pi * t)) / tanh(rockSharpness)
        // 1 on every beat (t = 0, 0.25, 0.5, 0.75), easing to 0 between beats.
        let dip = pow(0.5 + 0.5 * cos(8 * .pi * t), 1.5)

        var pose = TeddyBodyPose()
        pose.feetPlanted = true
        pose.leanDegrees = maxLeanDegrees * rock
        pose.hipShift = CGFloat(1.8 * rock)
        pose.bob = CGFloat(0.8 - 3.2 * dip)
        pose.headTiltDegrees = 8 * rock

        pose.leftArm = brushingArm(at: t)
        let right = brushingArm(at: t - 0.5)
        pose.rightArm = .init(angle: -right.angle, length: right.length)

        // Step-touch: both feet shift towards the stepping side, knees bending on the beat.
        let legLength = CGFloat(6.5 - 1.4 * dip)
        pose.rightLeg = .init(angle: 0.06 + 0.2 * rock, length: legLength)
        pose.leftLeg = .init(angle: -0.06 + 0.2 * rock, length: legLength)

        pose.face.mouthOpen = CGFloat(0.3 + 0.25 * dip)
        return pose
    }

    /// The left arm's hair brush. Starting a quarter loop before count 1, the paw rises up
    /// the outside of the body (never across the face), plants on the hair at the top of the
    /// head around count 1, glides back over the ear through count 2, then drops down the side
    /// and rests while the other paw takes its turn. Angles stay on the left side (negative).
    static func brushingArm(at loopFraction: Double) -> TeddyBodyPose.Limb {
        let s = wrapped(loopFraction + 0.25) / 0.75
        guard s < 1 else {
            return .init(angle: restAngle, length: restLength)
        }
        let angle = monotoneCubic(s, points: brushAngleKeys)
        let length = monotoneCubic(s, points: brushLengthKeys)
        return .init(angle: angle, length: CGFloat(length))
    }

    static let restAngle = -0.55
    static let restLength = 6.6
    /// (time through the brush, angle): up the side, top of the head, back over the ear, down.
    static let brushAngleKeys: [(Double, Double)] = [(0, restAngle), (0.24, -2.55), (0.36, -3.04), (0.68, -2.62), (1, restAngle)]
    /// (time through the brush, length): the arm stretches to reach the top of the head.
    static let brushLengthKeys: [(Double, Double)] = [(0, restLength), (0.24, 14), (0.36, 18.5), (0.68, 15.5), (1, restLength)]

    /// Left and right swapped: negated lean, tilt, hip shift and angles.
    static func mirrored(_ pose: TeddyBodyPose) -> TeddyBodyPose {
        var m = pose
        m.leanDegrees = -pose.leanDegrees
        m.headTiltDegrees = -pose.headTiltDegrees
        m.hipShift = -pose.hipShift
        m.leftArm = .init(angle: -pose.rightArm.angle, length: pose.rightArm.length)
        m.rightArm = .init(angle: -pose.leftArm.angle, length: pose.leftArm.length)
        m.leftLeg = .init(angle: -pose.rightLeg.angle, length: pose.rightLeg.length)
        m.rightLeg = .init(angle: -pose.leftLeg.angle, length: pose.leftLeg.length)
        return m
    }

    /// Wraps an angle into -pi...pi.
    static func normalized(_ angle: Double) -> Double {
        let turn = 2 * Double.pi
        return angle - turn * (angle / turn).rounded()
    }

    private static func wrapped(_ t: Double) -> Double {
        t - t.rounded(.down)
    }

    /// Monotone cubic (Fritsch-Carlson) through increasing x points: smooth, with no stops at
    /// the points and no overshoot between them.
    static func monotoneCubic(_ x: Double, points: [(Double, Double)]) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if x <= first.0 { return first.1 }
        if x >= last.0 { return last.1 }
        let n = points.count
        var slopes = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            slopes[i] = (points[i + 1].1 - points[i].1) / (points[i + 1].0 - points[i].0)
        }
        var tangents = [Double](repeating: 0, count: n)
        tangents[0] = slopes[0]
        tangents[n - 1] = slopes[n - 2]
        for i in 1..<(n - 1) {
            tangents[i] = slopes[i - 1] * slopes[i] <= 0 ? 0 : (slopes[i - 1] + slopes[i]) / 2
        }
        for i in 0..<(n - 1) where slopes[i] != 0 {
            let a = tangents[i] / slopes[i], b = tangents[i + 1] / slopes[i]
            let h = a * a + b * b
            if h > 9 {
                let k = 3 / h.squareRoot()
                tangents[i] = k * a * slopes[i]
                tangents[i + 1] = k * b * slopes[i]
            }
        }
        var i = 0
        while x > points[i + 1].0 { i += 1 }
        let (x0, y0) = points[i], (x1, y1) = points[i + 1]
        let h = x1 - x0, u = (x - x0) / h
        let u2 = u * u, u3 = u2 * u
        return (2 * u3 - 3 * u2 + 1) * y0 + (u3 - 2 * u2 + u) * h * tangents[i]
            + (-2 * u3 + 3 * u2) * y1 + (u3 - u2) * h * tangents[i + 1]
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

    /// The pose `time` seconds into the dance: four loops with ragdoll follow-through, and a
    /// blink now and then.
    /// The whole dance with ragdoll follow-through (see TeddyRagdoll), simulated once.
    static let ragdollFrames: [TeddyBodyPose] = TeddyRagdoll.simulate(seconds: danceSeconds) { time in
        pose(atLoopFraction: time / loopSeconds)
    }

    static func pose(atDanceTime time: TimeInterval) -> TeddyBodyPose {
        var pose = TeddyRagdoll.pose(at: min(max(time, 0), danceSeconds), in: ragdollFrames)
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
