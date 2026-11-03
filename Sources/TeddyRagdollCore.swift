import CoreGraphics
import Foundation

/// "Ragdoll" secondary motion for Rio's dances: loose parts (head, arms, forearms, shoulders,
/// body bounce) lag behind the body, swing past and settle, as if they had weight. Each is a
/// damped spring pulled towards the choreographed pose and, like a pendulum on a moving pivot,
/// pushed the other way when the body accelerates sideways. The whole dance is simulated once at
/// a fixed step, so drawing a frame only looks up the result and every frame is reproducible.
enum TeddyRagdoll {
    static let stepsPerSecond = 240.0

    /// A damped spring with natural frequency `hertz` and damping ratio `damping`
    /// (below 1 overshoots: lower is floppier).
    struct Spring {
        let hertz: Double
        let damping: Double
        var value: Double
        var velocity = 0.0

        /// Semi-implicit Euler; `push` is an extra acceleration (e.g. from the moving pivot).
        mutating func step(towards target: Double, push: Double, dt: Double) {
            let omega = 2 * Double.pi * hertz
            let acceleration = omega * omega * (target - value) - 2 * damping * omega * velocity + push
            velocity += acceleration * dt
            value += velocity * dt
        }
    }

    /// Tuning: the head and a hanging arm are floppy; an arm lifted over the head is held
    /// firmer so the paw still lands on the head.
    static let headHertz = 2.0, headDamping = 0.2
    static let looseArmHertz = 2.2, looseArmDamping = 0.22
    static let reachingArmHertz = 5.5, reachingArmDamping = 0.55
    /// Elbows: a forearm lags its upper arm and follows through when it drops.
    static let looseElbowHertz = 4.0, looseElbowDamping = 0.35
    static let reachingElbowHertz = 6.5, reachingElbowDamping = 0.6
    /// Shoulders overshoot a little.
    static let shoulderHertz = 4.5, shoulderDamping = 0.5
    static let bounceHertz = 3.2, bounceDamping = 0.35
    /// How hard a sideways shove of the shoulders tips the head (degrees/s² per grid unit/s²).
    static let headCoupling = 2.0
    /// How strongly the upper arm's angular acceleration drags the forearm the other way.
    static let elbowDrag = 0.35
    /// Grid units from the feet to the shoulders, used to turn lean into sideways motion.
    static let shoulderHeight = 20.0
    /// An upper arm lifted away from the side by this much counts as fully "reaching".
    static let hangingAngle = 0.9, reachingAngle = 1.9

    /// One arm's springs: the upper arm swings like a pendulum, the forearm bends on a spring.
    private struct ArmState {
        var angle: Double
        var velocity = 0.0
        var bend: Spring?
        var shoulder: Spring

        init(target: TeddyBodyPose.Limb, forearm: TeddyBodyPose.Limb?, shoulderLift: CGFloat) {
            angle = target.angle
            bend = forearm.map { Spring(hertz: looseElbowHertz, damping: looseElbowDamping, value: $0.angle) }
            shoulder = Spring(hertz: shoulderHertz, damping: shoulderDamping, value: Double(shoulderLift))
        }
    }

    /// Runs `choreography` for `seconds` and returns one pose per step, starting from rest.
    static func simulate(seconds: TimeInterval, choreography: (TimeInterval) -> TeddyBodyPose) -> [TeddyBodyPose] {
        let dt = 1 / stepsPerSecond
        let count = Int((seconds * stepsPerSecond).rounded(.up)) + 1
        let start = choreography(0)
        var head = Spring(hertz: headHertz, damping: headDamping, value: start.headTiltDegrees)
        var bob = Spring(hertz: bounceHertz, damping: bounceDamping, value: Double(start.bob))
        var left = ArmState(target: start.leftArm, forearm: start.leftForearm, shoulderLift: start.leftShoulderLift)
        var right = ArmState(target: start.rightArm, forearm: start.rightForearm, shoulderLift: start.rightShoulderLift)
        var previousX = sideways(start), previousVelocityX = 0.0

        var frames: [TeddyBodyPose] = []
        frames.reserveCapacity(count)
        for index in 0..<count {
            let target = choreography(Double(index) * dt)
            // The shoulders' sideways acceleration drives the pendulums.
            let x = sideways(target)
            let velocityX = index == 0 ? 0 : (x - previousX) / dt
            let accelerationX = index == 0 ? 0 : (velocityX - previousVelocityX) / dt
            previousX = x
            previousVelocityX = velocityX

            // The head tips away from a sudden sideways push, then catches up.
            head.step(towards: target.headTiltDegrees, push: -accelerationX * headCoupling, dt: dt)
            bob.step(towards: Double(target.bob), push: 0, dt: dt)
            step(&left, upper: target.leftArm, forearm: target.leftForearm, shoulderLift: target.leftShoulderLift,
                 pivotAcceleration: accelerationX, dt: dt)
            step(&right, upper: target.rightArm, forearm: target.rightForearm, shoulderLift: target.rightShoulderLift,
                 pivotAcceleration: accelerationX, dt: dt)

            var pose = target
            pose.headTiltDegrees = head.value
            pose.bob = CGFloat(bob.value)
            pose.leftArm = .init(angle: TeddyDougie.normalized(left.angle), length: target.leftArm.length)
            pose.rightArm = .init(angle: TeddyDougie.normalized(right.angle), length: target.rightArm.length)
            pose.leftForearm = forearm(left, target.leftForearm)
            pose.rightForearm = forearm(right, target.rightForearm)
            pose.leftShoulderLift = CGFloat(left.shoulder.value)
            pose.rightShoulderLift = CGFloat(right.shoulder.value)
            frames.append(pose)
        }
        return frames
    }

    private static func forearm(_ state: ArmState, _ target: TeddyBodyPose.Limb?) -> TeddyBodyPose.Limb? {
        guard let target, let bend = state.bend else { return nil }
        return .init(angle: bend.value, length: target.length)
    }

    /// The pose at `time` in a simulated run, blending the two nearest steps.
    static func pose(at time: TimeInterval, in frames: [TeddyBodyPose]) -> TeddyBodyPose {
        guard let last = frames.last else { return .standing }
        let position = max(0, time) * stepsPerSecond
        let index = Int(position)
        guard index + 1 < frames.count else { return last }
        let a = frames[index], b = frames[index + 1]
        let t = position - Double(index)
        let f = CGFloat(t)
        var pose = a
        pose.headTiltDegrees = a.headTiltDegrees + (b.headTiltDegrees - a.headTiltDegrees) * t
        pose.bob = a.bob + (b.bob - a.bob) * f
        pose.leftArm.angle = a.leftArm.angle + TeddyDougie.normalized(b.leftArm.angle - a.leftArm.angle) * t
        pose.rightArm.angle = a.rightArm.angle + TeddyDougie.normalized(b.rightArm.angle - a.rightArm.angle) * t
        if let x = a.leftForearm, let y = b.leftForearm { pose.leftForearm?.angle = x.angle + (y.angle - x.angle) * t }
        if let x = a.rightForearm, let y = b.rightForearm { pose.rightForearm?.angle = x.angle + (y.angle - x.angle) * t }
        pose.leftShoulderLift = a.leftShoulderLift + (b.leftShoulderLift - a.leftShoulderLift) * f
        pose.rightShoulderLift = a.rightShoulderLift + (b.rightShoulderLift - a.rightShoulderLift) * f
        // Feet, twist and lean come straight from the choreography; blend them so they stay smooth.
        pose.leanDegrees = a.leanDegrees + (b.leanDegrees - a.leanDegrees) * t
        pose.twist = a.twist + (b.twist - a.twist) * t
        pose.hipShift = a.hipShift + (b.hipShift - a.hipShift) * f
        pose.leftFootShift = a.leftFootShift + (b.leftFootShift - a.leftFootShift) * f
        pose.rightFootShift = a.rightFootShift + (b.rightFootShift - a.rightFootShift) * f
        pose.leftFootLift = a.leftFootLift + (b.leftFootLift - a.leftFootLift) * f
        pose.rightFootLift = a.rightFootLift + (b.rightFootLift - a.rightFootLift) * f
        return pose
    }

    /// How far the shoulders sit to the side, from the lean and the hip sway.
    static func sideways(_ pose: TeddyBodyPose) -> Double {
        shoulderHeight * sin(pose.leanDegrees * .pi / 180) + Double(pose.hipShift)
    }

    /// One arm for one step: the upper arm is a spring towards the choreographed angle (always
    /// the short way round) pushed by the moving shoulder, the forearm a spring dragged against
    /// the upper arm's swing, and the shoulder a lightly underdamped spring.
    private static func step(
        _ arm: inout ArmState,
        upper target: TeddyBodyPose.Limb,
        forearm targetForearm: TeddyBodyPose.Limb?,
        shoulderLift: CGFloat,
        pivotAcceleration: Double,
        dt: Double
    ) {
        let lifted = Double(min(max((abs(TeddyDougie.normalized(target.angle)) - hangingAngle) / (reachingAngle - hangingAngle), 0), 1))
        let hertz = looseArmHertz + (reachingArmHertz - looseArmHertz) * lifted
        let damping = looseArmDamping + (reachingArmDamping - looseArmDamping) * lifted
        let omega = 2 * Double.pi * hertz
        let error = TeddyDougie.normalized(target.angle - arm.angle)
        let swing = -pivotAcceleration / max(Double(target.length), 1) * cos(arm.angle) * (1 - lifted)
        let acceleration = omega * omega * error - 2 * damping * omega * arm.velocity + swing
        arm.velocity += acceleration * dt
        arm.angle += arm.velocity * dt

        if let targetForearm, let bend = arm.bend {
            var spring = Spring(
                hertz: looseElbowHertz + (reachingElbowHertz - looseElbowHertz) * lifted,
                damping: looseElbowDamping + (reachingElbowDamping - looseElbowDamping) * lifted,
                value: bend.value,
                velocity: bend.velocity
            )
            spring.step(towards: targetForearm.angle, push: -acceleration * elbowDrag * (1 - lifted), dt: dt)
            arm.bend = spring
        }
        arm.shoulder.step(towards: Double(shoulderLift), push: 0, dt: dt)
    }
}
