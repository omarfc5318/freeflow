import CoreGraphics
import Foundation

/// "Ragdoll" secondary motion for Rio's dances: loose parts (head, arms, body bounce) lag
/// behind the body, swing past and settle, as if they had weight. Each is a damped spring
/// pulled towards the choreographed pose and, like a pendulum on a moving pivot, pushed the
/// other way when the body accelerates sideways. The whole dance is simulated once at a
/// fixed step, so drawing a frame only looks up the result and every frame is reproducible.
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

    /// Tuning: the head and a resting arm are floppy; an arm reaching over the head is held
    /// firmer so the paw still lands on the head.
    static let headHertz = 2.0, headDamping = 0.2
    static let looseArmHertz = 2.2, looseArmDamping = 0.22
    static let reachingArmHertz = 5.5, reachingArmDamping = 0.55
    static let bounceHertz = 3.2, bounceDamping = 0.35
    /// How hard a sideways shove of the shoulders tips the head (degrees/s² per grid unit/s²).
    static let headCoupling = 2.0
    /// Grid units from the feet to the shoulders, used to turn lean into sideways motion.
    static let shoulderHeight = 20.0
    static let restingArmLength: CGFloat = 6.6
    static let reachingArmLength: CGFloat = 14

    /// Runs `choreography` for `seconds` and returns one pose per step, starting from rest.
    static func simulate(seconds: TimeInterval, choreography: (TimeInterval) -> TeddyBodyPose) -> [TeddyBodyPose] {
        let dt = 1 / stepsPerSecond
        let count = Int((seconds * stepsPerSecond).rounded(.up)) + 1
        let start = choreography(0)
        var head = Spring(hertz: headHertz, damping: headDamping, value: start.headTiltDegrees)
        var bob = Spring(hertz: bounceHertz, damping: bounceDamping, value: Double(start.bob))
        var leftArm = start.leftArm.angle, leftVelocity = 0.0
        var rightArm = start.rightArm.angle, rightVelocity = 0.0
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
            stepArm(&leftArm, &leftVelocity, towards: target.leftArm, pivotAcceleration: accelerationX, dt: dt)
            stepArm(&rightArm, &rightVelocity, towards: target.rightArm, pivotAcceleration: accelerationX, dt: dt)

            var pose = target
            pose.headTiltDegrees = head.value
            pose.bob = CGFloat(bob.value)
            pose.leftArm = .init(angle: TeddyDougie.normalized(leftArm), length: target.leftArm.length)
            pose.rightArm = .init(angle: TeddyDougie.normalized(rightArm), length: target.rightArm.length)
            frames.append(pose)
        }
        return frames
    }

    /// The pose at `time` in a simulated run, blending the two nearest steps.
    static func pose(at time: TimeInterval, in frames: [TeddyBodyPose]) -> TeddyBodyPose {
        guard let last = frames.last else { return .standing }
        let position = max(0, time) * stepsPerSecond
        let index = Int(position)
        guard index + 1 < frames.count else { return last }
        let a = frames[index], b = frames[index + 1]
        let t = position - Double(index)
        var pose = a
        pose.headTiltDegrees = a.headTiltDegrees + (b.headTiltDegrees - a.headTiltDegrees) * t
        pose.bob = a.bob + (b.bob - a.bob) * CGFloat(t)
        pose.leftArm.angle = a.leftArm.angle + TeddyDougie.normalized(b.leftArm.angle - a.leftArm.angle) * t
        pose.rightArm.angle = a.rightArm.angle + TeddyDougie.normalized(b.rightArm.angle - a.rightArm.angle) * t
        return pose
    }

    /// How far the shoulders sit to the side, from the lean and the hip sway.
    static func sideways(_ pose: TeddyBodyPose) -> Double {
        shoulderHeight * sin(pose.leanDegrees * .pi / 180) + Double(pose.hipShift)
    }

    /// A pendulum arm: a spring towards the choreographed angle (always the short way round),
    /// pushed by the moving shoulder. A pivot accelerating right swings a hanging arm left.
    private static func stepArm(
        _ angle: inout Double,
        _ velocity: inout Double,
        towards target: TeddyBodyPose.Limb,
        pivotAcceleration: Double,
        dt: Double
    ) {
        let reach = Double(min(max((target.length - restingArmLength) / (reachingArmLength - restingArmLength), 0), 1))
        let hertz = looseArmHertz + (reachingArmHertz - looseArmHertz) * reach
        let damping = looseArmDamping + (reachingArmDamping - looseArmDamping) * reach
        let omega = 2 * Double.pi * hertz
        let error = TeddyDougie.normalized(target.angle - angle)
        let swing = -pivotAcceleration / max(Double(target.length), 1) * cos(angle) * (1 - reach)
        let acceleration = omega * omega * error - 2 * damping * omega * velocity + swing
        velocity += acceleration * dt
        angle += velocity * dt
    }
}
