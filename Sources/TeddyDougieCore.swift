import CoreGraphics
import Foundation

/// The Dougie as continuous motion. One loop is four counts (about 2.82 s at the default 85 BPM);
/// counts 3 and 4 mirror counts 1 and 2. All directions are the viewer's left and right.
///
/// Count 1: step wide to the right and drop into the knees, lean and turn the chest right, right
/// shoulder down, left up. The left elbow is tucked into the side with the forearm folded up (a
/// loose fist by the shoulder) and the right forearm drops across the belly.
/// Count 2: the left foot slides in beside the right with a small toe tap; the raised forearm
/// bounces on the beat.
/// Counts 3 and 4: the same on the other side; the forearms swap through the "&" before each.
/// On every fourth loop the raised arm adds a flourish: over the side of the head and back.
enum TeddyDougie {
    static let defaultBPM = 85.0
    static let beatsPerLoop = 4
    static let loopCount = 8
    static let beatSeconds: TimeInterval = 60 / defaultBPM
    static let loopSeconds: TimeInterval = beatSeconds * Double(beatsPerLoop)
    static let danceSeconds: TimeInterval = loopSeconds * Double(loopCount)

    /// Tempos outside this range (or not numbers) fall back to something danceable.
    static let bpmRange = 50.0...180.0

    static func sanitized(bpm: Double) -> Double {
        guard bpm.isFinite else { return defaultBPM }
        return min(max(bpm, bpmRange.lowerBound), bpmRange.upperBound)
    }

    static func beatSeconds(bpm: Double) -> TimeInterval { 60 / sanitized(bpm: bpm) }
    static func loopSeconds(bpm: Double) -> TimeInterval { beatSeconds(bpm: bpm) * Double(beatsPerLoop) }
    static func danceSeconds(bpm: Double) -> TimeInterval { loopSeconds(bpm: bpm) * Double(loopCount) }

    // MARK: Motion

    static let leftShoulder = CGPoint(x: 12.6, y: 28.5)
    static let rightShoulder = CGPoint(x: 27.4, y: 28.5)

    /// Peak lean, reached around counts 1-2 (right) and 3-4 (left).
    static let maxLeanDegrees = 10.5
    /// How quickly the weight shifts from side to side (higher is snappier).
    static let rockSharpness = 2.2
    /// Where in the loop the rock peaks. The weight switches at the "&" before count 3 (0.375)
    /// and before count 1 (0.875), so the lean holds through counts 1-2 and counts 3-4.
    static let rockPeak = 0.125
    /// The shoulder on the lean side drops and the other rises (grid units).
    static let shoulderDrop = 2.0
    static let shoulderRise = 1.5
    /// How far the chest turns towards the step (see `TeddyBodyPose.twist`).
    static let maxTwist = 0.4
    /// Kept small: with planted feet a big slide stretches the trailing leg out flat.
    static let hipSway = 1.2

    /// The weight shift, -1 (left) ... 1 (right): quick across the "&", then riding it out.
    static func rock(at fraction: Double) -> Double {
        tanh(rockSharpness * cos(2 * .pi * (fraction - rockPeak))) / tanh(rockSharpness)
    }

    /// Shoulder height for a rock value: positive rock raises this shoulder, negative drops it
    /// (a little more than it rises).
    static func shoulderLift(forRock rock: Double) -> Double {
        rock > 0 ? shoulderRise * rock : shoulderDrop * rock
    }

    // Feet: a step-touch. The right foot steps out at count 1, the left slides in and taps
    // at count 2; counts 3 and 4 do the same the other way round.
    /// How far a foot sits to the side of its home spot when the stance is shifted.
    /// Rio's legs are short, so a wider step reads as a split rather than a step.
    static let stanceShift = 2.0
    private static let slideStart = 0.58, tapStart = 0.75, tapEnd = 0.83, stepStart = 0.87
    private static let slideLift = 0.6, tapLift = 1.2, stepLift = 2.0

    private static func smoother(_ u: Double) -> Double {
        let c = min(max(u, 0), 1)
        return c * c * c * (c * (c * 6 - 15) + 10)
    }

    /// The right foot's sideways shift through the loop: out at count 1, slides in during
    /// counts 3-4 to tap beside the left foot at count 4, then steps out again.
    static func rightFootShift(at fraction: Double) -> Double {
        let t = wrapped(fraction)
        if t < slideStart { return stanceShift }
        if t < tapStart { return stanceShift - 2 * stanceShift * smoother((t - slideStart) / (tapStart - slideStart)) }
        if t < stepStart { return -stanceShift }
        return -stanceShift + 2 * stanceShift * smoother((t - stepStart) / (1 - stepStart))
    }

    /// The right foot's lift: low while sliding in, a small toe tap on arrival, a high step out.
    static func rightFootLift(at fraction: Double) -> Double {
        let t = wrapped(fraction)
        func arc(_ from: Double, _ to: Double, _ height: Double) -> Double {
            height * sin(.pi * (t - from) / (to - from))
        }
        if t >= slideStart && t < tapStart { return arc(slideStart, tapStart, slideLift) }
        if t >= tapStart && t < tapEnd { return arc(tapStart, tapEnd, tapLift) }
        if t >= stepStart { return arc(stepStart, 1, stepLift) }
        return 0
    }

    static func pose(atLoopFraction fraction: Double) -> TeddyBodyPose {
        let t = wrapped(fraction)
        let rock = rock(at: t)
        // 1 on every count, easing to 0 between; counts 1 and 3 drop deeper than 2 and 4.
        let dip = pow(0.5 + 0.5 * cos(8 * .pi * t), 1.5)
        let depth = 0.75 + 0.25 * cos(4 * .pi * t)

        var pose = TeddyBodyPose()
        pose.feetPlanted = true
        pose.leanDegrees = maxLeanDegrees * rock
        pose.hipShift = CGFloat(hipSway * rock)
        // Shallow enough for Rio's short legs: deeper drops splay the planted legs sideways.
        pose.bob = CGFloat(0.5 - 2.1 * dip * depth)
        pose.headTiltDegrees = 7 * rock + 3 * rock * dip * depth
        pose.twist = maxTwist * rock
        pose.leftShoulderLift = CGFloat(shoulderLift(forRock: rock))
        pose.rightShoulderLift = CGFloat(shoulderLift(forRock: -rock))

        let left = leftArm(at: fraction, flourish: true)
        let right = leftArm(at: fraction + 0.5, flourish: false)
        pose.leftArm = left.upper
        pose.leftForearm = left.forearm
        pose.rightArm = .init(angle: -right.upper.angle, length: right.upper.length)
        pose.rightForearm = .init(angle: -right.forearm.angle, length: right.forearm.length)

        pose.rightFootShift = CGFloat(rightFootShift(at: t))
        pose.leftFootShift = CGFloat(-rightFootShift(at: t + 0.5))
        pose.rightFootLift = CGFloat(rightFootLift(at: t))
        pose.leftFootLift = CGFloat(rightFootLift(at: t + 0.5))

        // Knees bend on the dips; each leg leans from its hip to its foot.
        let legLength = CGFloat(6.5 - 1.8 * dip * depth)
        let hip = Double(pose.hipShift)
        pose.leftLeg = .init(angle: atan2(Double(pose.leftFootShift) - hip, Double(legLength)), length: legLength)
        pose.rightLeg = .init(angle: atan2(Double(pose.rightFootShift) - hip, Double(legLength)), length: legLength)

        pose.face.mouthOpen = CGFloat(0.3 + 0.25 * dip)
        return pose
    }

    // MARK: Arms

    static let upperArmLength: CGFloat = 5.4
    /// The forearm is a touch shorter folded up by the shoulder than reaching across the belly.
    static let forearmUpLength: CGFloat = 5.0
    static let forearmAcrossLength: CGFloat = 6.0

    struct Arm: Equatable {
        var upper: TeddyBodyPose.Limb
        var forearm: TeddyBodyPose.Limb
    }

    /// The elbow stays tucked into the side: the upper arm hangs almost straight down.
    static let tuckedUpperAngle = -0.1
    /// Forearm bend (relative to the upper arm) with the fist up by the shoulder, and with the
    /// forearm dropped across the belly towards the midline.
    static let forearmUpBend = -3.0
    static let forearmAcrossBend = 1.7
    /// How far the raised forearm pumps on each beat (radians).
    static let pumpRadians = 0.2
    /// The hair-brush flourish: on count 1 of every fourth loop the raised arm goes over the
    /// side of the head and back. It lasts this much of the loop.
    static let flourishLoopInterval = 4
    static let flourishLength = 0.3
    static let flourishUpperAngle = -2.8
    static let flourishBend = -0.7
    static let flourishReach: CGFloat = 6.8

    /// The viewer's-left arm. It is the raised one (fist by the shoulder) while the weight is on
    /// the right, and drops across the belly through the "&" while the weight moves left. The
    /// right arm is this same motion half a loop later, mirrored (pass `flourish: false`).
    static func leftArm(at fraction: Double, flourish: Bool) -> Arm {
        let t = wrapped(fraction)
        let raised = 0.5 + 0.5 * rock(at: t)
        let pump = pumpRadians * cos(8 * .pi * t) * raised
        var upper = tuckedUpperAngle
        var bend = forearmAcrossBend + (forearmUpBend - forearmAcrossBend) * raised + pump
        var upperLength = upperArmLength
        var forearmLength = forearmAcrossLength + (forearmUpLength - forearmAcrossLength) * CGFloat(raised)
        let loop = Int(fraction.rounded(.down))
        if flourish, loop % flourishLoopInterval == flourishLoopInterval - 1, t < flourishLength {
            // The arm opens up and reaches a little further to get over the side of the head.
            let lift = pow(sin(.pi * t / flourishLength), 2)
            upper += (flourishUpperAngle - tuckedUpperAngle) * lift
            bend += (flourishBend - forearmUpBend) * lift
            upperLength += (flourishReach - upperArmLength) * CGFloat(lift)
            forearmLength += (flourishReach - forearmLength) * CGFloat(lift)
        }
        return Arm(
            upper: .init(angle: upper, length: upperLength),
            forearm: .init(angle: bend, length: forearmLength)
        )
    }

    /// Where a paw is: the elbow from the shoulder, then the forearm from the elbow.
    static func pawTip(upper: TeddyBodyPose.Limb, forearm: TeddyBodyPose.Limb?, shoulder: CGPoint) -> CGPoint {
        let elbow = CGPoint(
            x: shoulder.x + CGFloat(sin(upper.angle)) * upper.length,
            y: shoulder.y + CGFloat(cos(upper.angle)) * upper.length
        )
        guard let forearm else { return elbow }
        let angle = upper.angle + forearm.angle
        return CGPoint(x: elbow.x + CGFloat(sin(angle)) * forearm.length, y: elbow.y + CGFloat(cos(angle)) * forearm.length)
    }

    /// The paws in a pose (body grid, before lean), with each side's shoulder lift applied.
    static func leftPaw(in pose: TeddyBodyPose) -> CGPoint {
        pawTip(upper: pose.leftArm, forearm: pose.leftForearm,
               shoulder: CGPoint(x: leftShoulder.x, y: leftShoulder.y - pose.leftShoulderLift))
    }

    static func rightPaw(in pose: TeddyBodyPose) -> CGPoint {
        pawTip(upper: pose.rightArm, forearm: pose.rightForearm,
               shoulder: CGPoint(x: rightShoulder.x, y: rightShoulder.y - pose.rightShoulderLift))
    }

    /// Left and right swapped: negated lean, tilt, twist, hip shift and angles; swapped
    /// shoulders, forearms, feet shifts (negated) and foot lifts.
    static func mirrored(_ pose: TeddyBodyPose) -> TeddyBodyPose {
        func flip(_ limb: TeddyBodyPose.Limb) -> TeddyBodyPose.Limb { .init(angle: -limb.angle, length: limb.length) }
        var m = pose
        m.leanDegrees = -pose.leanDegrees
        m.headTiltDegrees = -pose.headTiltDegrees
        m.hipShift = -pose.hipShift
        m.twist = -pose.twist
        m.leftArm = flip(pose.rightArm)
        m.rightArm = flip(pose.leftArm)
        m.leftForearm = pose.rightForearm.map(flip)
        m.rightForearm = pose.leftForearm.map(flip)
        m.leftLeg = flip(pose.rightLeg)
        m.rightLeg = flip(pose.leftLeg)
        m.leftShoulderLift = pose.rightShoulderLift
        m.rightShoulderLift = pose.leftShoulderLift
        m.leftFootShift = -pose.rightFootShift
        m.rightFootShift = -pose.leftFootShift
        m.leftFootLift = pose.rightFootLift
        m.rightFootLift = pose.leftFootLift
        return m
    }

    // MARK: Walking in

    /// Walking in place, `steps` steps over `progress` 0...1, alternating feet with the arms
    /// swinging loosely and the body bobbing a little. Ends with both feet down.
    static func walkingPose(progress: Double, steps: Int) -> TeddyBodyPose {
        let x = min(max(progress, 0), 1) * Double(steps)
        let step = min(Int(x), steps - 1)
        let phase = x - Double(step)
        let lift = 1.8 * sin(.pi * phase)
        let swing = 0.3 * cos(.pi * x)

        var pose = TeddyBodyPose()
        pose.feetPlanted = true
        pose.bob = CGFloat(0.6 * abs(sin(.pi * x)))
        pose.leftFootLift = CGFloat(step % 2 == 0 ? lift : 0)
        pose.rightFootLift = CGFloat(step % 2 == 1 ? lift : 0)
        pose.leftLeg = .init(angle: 0, length: 6.5 - 0.6 * CGFloat(pose.leftFootLift))
        pose.rightLeg = .init(angle: 0, length: 6.5 - 0.6 * CGFloat(pose.rightFootLift))
        pose.leftArm = .init(angle: -0.34 + swing, length: upperArmLength)
        pose.rightArm = .init(angle: 0.34 + swing, length: upperArmLength)
        pose.leftForearm = .init(angle: 0.3, length: forearmAcrossLength)
        pose.rightForearm = .init(angle: -0.3, length: forearmAcrossLength)
        pose.headTiltDegrees = 3 * sin(.pi * x)
        pose.face.mouthOpen = 0.25
        return pose
    }

    /// Blends two poses (`weight` 0 gives `a`, 1 gives `b`), for gliding from the walk into the
    /// dance and back. Angles take the short way round.
    static func blend(_ a: TeddyBodyPose, _ b: TeddyBodyPose, weight: Double) -> TeddyBodyPose {
        let w = min(max(weight, 0), 1)
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * w }
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * CGFloat(w) }
        func limb(_ x: TeddyBodyPose.Limb, _ y: TeddyBodyPose.Limb) -> TeddyBodyPose.Limb {
            .init(angle: x.angle + normalized(y.angle - x.angle) * w, length: mix(x.length, y.length))
        }
        func bend(_ x: TeddyBodyPose.Limb?, _ y: TeddyBodyPose.Limb?) -> TeddyBodyPose.Limb? {
            switch (x, y) {
            case let (x?, y?): return limb(x, y)
            default: return w < 0.5 ? x : y
            }
        }
        var pose = w < 0.5 ? a : b
        pose.leanDegrees = mix(a.leanDegrees, b.leanDegrees)
        pose.bob = mix(a.bob, b.bob)
        pose.hipShift = mix(a.hipShift, b.hipShift)
        pose.headTiltDegrees = mix(a.headTiltDegrees, b.headTiltDegrees)
        pose.leftArm = limb(a.leftArm, b.leftArm)
        pose.rightArm = limb(a.rightArm, b.rightArm)
        pose.leftLeg = limb(a.leftLeg, b.leftLeg)
        pose.rightLeg = limb(a.rightLeg, b.rightLeg)
        pose.leftForearm = bend(a.leftForearm, b.leftForearm)
        pose.rightForearm = bend(a.rightForearm, b.rightForearm)
        pose.leftShoulderLift = mix(a.leftShoulderLift, b.leftShoulderLift)
        pose.rightShoulderLift = mix(a.rightShoulderLift, b.rightShoulderLift)
        pose.twist = mix(a.twist, b.twist)
        pose.leftFootShift = mix(a.leftFootShift, b.leftFootShift)
        pose.rightFootShift = mix(a.rightFootShift, b.rightFootShift)
        pose.leftFootLift = mix(a.leftFootLift, b.leftFootLift)
        pose.rightFootLift = mix(a.rightFootLift, b.rightFootLift)
        pose.face.mouthOpen = mix(a.face.mouthOpen, b.face.mouthOpen)
        return pose
    }

    /// Wraps an angle into -pi...pi.
    static func normalized(_ angle: Double) -> Double {
        let turn = 2 * Double.pi
        return angle - turn * (angle / turn).rounded()
    }

    private static func wrapped(_ t: Double) -> Double {
        t - t.rounded(.down)
    }

    // MARK: Timeline

    /// A blink every other loop, just before the next 1.
    static let blinkLoopFraction = 0.9
    static let blinkSeconds: TimeInterval = 0.14

    static func isBlinking(atDanceTime time: TimeInterval, bpm: Double = defaultBPM) -> Bool {
        guard time >= 0 else { return false }
        let loopLength = loopSeconds(bpm: bpm)
        let loop = Int(time / loopLength)
        guard loop % 2 == 0 else { return false }
        let start = (Double(loop) + blinkLoopFraction) * loopLength
        return time >= start && time < start + blinkSeconds
    }

    /// The whole dance with ragdoll follow-through (see TeddyRagdoll), simulated once per tempo.
    static func ragdollFrames(bpm: Double = defaultBPM) -> [TeddyBodyPose] {
        let tempo = sanitized(bpm: bpm)
        return ragdollCache.frames(forBPM: tempo) {
            let loop = loopSeconds(bpm: tempo)
            return TeddyRagdoll.simulate(seconds: danceSeconds(bpm: tempo)) { time in
                pose(atLoopFraction: time / loop)
            }
        }
    }

    private static let ragdollCache = RagdollCache()

    /// The pose `time` seconds into the dance at `bpm`: eight loops with ragdoll follow-through
    /// and a blink now and then.
    static func pose(atDanceTime time: TimeInterval, bpm: Double = defaultBPM) -> TeddyBodyPose {
        let length = danceSeconds(bpm: bpm)
        var pose = TeddyRagdoll.pose(at: min(max(time, 0), length), in: ragdollFrames(bpm: bpm))
        pose.face.isBlinking = isBlinking(atDanceTime: time, bpm: bpm)
        return pose
    }

    // MARK: Routine

    /// Big enough (about a fifth of the screen height) that each joint reads clearly.
    static let danceScale: CGFloat = 3.0
    static let approachSeconds: TimeInterval = 0.8
    static let walkBackSeconds: TimeInterval = 0.6
    private static let approachSteps = 4, walkBackSteps = 3
    /// The last part of the approach (and first of the walk back) glides between walk and dance.
    private static let glideFraction = 0.3

    private static func easeInOut(_ f: Double) -> CGFloat {
        let c = min(max(f, 0), 1)
        return CGFloat(c * c * (3 - 2 * c))
    }

    /// Jump out, run to the middle, walk towards the viewer (growing to `danceScale`), dance eight
    /// loops at `bpm`, walk back, run back, jump in. `beatWindow` marks exactly the dance.
    static func routine(screenSize: CGSize, home: CGPoint, margin: CGFloat, bpm: Double = defaultBPM) -> TeddyRoutine {
        let tempo = sanitized(bpm: bpm)
        let length = danceSeconds(bpm: tempo)
        let landing = TeddyRoutine.landing(for: home, screenSize: screenSize, margin: margin)
        let middle = TeddyWiggle.middle(landing: landing, screenSize: screenSize)
        let jumpOut = TeddyRoutine.jump(from: home, to: landing, leavingHome: true)
        let runOut = TeddyRoutine.run(from: landing, to: middle)
        let danceStart = pose(atDanceTime: 0, bpm: tempo)
        let danceEnd = pose(atDanceTime: length, bpm: tempo)

        let approach = TeddyRoutine.hold(
            at: middle, seconds: approachSeconds, scale: { easeInOut($0) * (danceScale - 1) + 1 }
        ) { fraction in
            let walk = walkingPose(progress: fraction, steps: approachSteps)
            let glide = (fraction - (1 - glideFraction)) / glideFraction
            return .posed(blend(walk, danceStart, weight: Double(easeInOut(glide))))
        }
        let dance = TeddyRoutine.hold(at: middle, seconds: length, scale: { _ in danceScale }) { fraction in
            .posed(pose(atDanceTime: fraction * length, bpm: tempo))
        }
        let walkBack = TeddyRoutine.hold(
            at: middle, seconds: walkBackSeconds, scale: { danceScale - easeInOut($0) * (danceScale - 1) }
        ) { fraction in
            let walk = walkingPose(progress: fraction, steps: walkBackSteps)
            return .posed(blend(danceEnd, walk, weight: Double(easeInOut(fraction / glideFraction))))
        }
        let beatStart = jumpOut.duration + runOut.duration + approach.duration
        var routine = TeddyRoutine(steps: [
            jumpOut,
            runOut,
            approach,
            dance,
            walkBack,
            TeddyRoutine.run(from: middle, to: landing),
            TeddyRoutine.jump(from: landing, to: home, leavingHome: false),
        ])
        routine.beatWindow = beatStart...(beatStart + length)
        return routine
    }
}

/// Per-tempo cache of the precomputed ragdoll frames (safe to call from any thread).
private final class RagdollCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [Int: [TeddyBodyPose]] = [:]

    func frames(forBPM bpm: Double, compute: () -> [TeddyBodyPose]) -> [TeddyBodyPose] {
        let key = Int((bpm * 100).rounded())
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let frames = compute()
        cache[key] = frames
        return frames
    }
}
