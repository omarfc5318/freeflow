import CoreGraphics
import Foundation

/// The Dougie trick: phrase matching, the dance timeline, the routine and the beat pattern.
enum TeddyDougieTests {
    static func run() {
        testPhraseVariants()
        testNearMissesAreTypedNormally()
        testDanceLengthIsFourLoops()
        testCountOneLeansIntoAKneeDip()
        testSecondHalfMirrorsFirst()
        testLoopIsContinuous()
        testPawBrushesOverTheHeadOnTheHighShoulderSide()
        testBrushGlidesOverTheHairNotTheFace()
        testRagdollHeadLagsAndSettles()
        testRagdollKeepsTheBrushOnTheHead()
        testRagdollRestingArmSwingsLoose()
        testBlinkIsOccasional()
        testRoutineStartsAndEndsInThePill()
        testRoutineDancesBetweenRuns()
        testSongStartTime()
        testBeatLength()
        testBeatPatternTiming()
        testBeatIsAudibleAndBounded()
    }

    private static let screen = CGSize(width: 1440, height: 900)
    private static let home = CGPoint(x: 720, y: 24)
    private static let margin: CGFloat = 40

    private static func testPhraseVariants() {
        let phrases = [
            "Rio, hit the Dougie.", "ryo hit the dougie", "Rio do the Dougie", "ryo, dougie",
            "Rio hit the Duggie", "Rio hit the Dougy!", "Rio, hit the doggie", "ryo hit the doggy",
            "Rio does the Dougie", "  RIO HIT THE DOUGIE  ", "Reo hit the dougie",
        ]
        for phrase in phrases {
            TestSupport.expectEqual(TeddyCommand.trick(in: phrase), .dougie)
        }
    }

    private static func testNearMissesAreTypedNormally() {
        let phrases = [
            "Rio hit the dougie now", "I told Rio to hit the dougie", "hit the dougie",
            "Rio hit the dog", "Rio hit the", "Rio the dougie", "Rio hit dougie please",
            "Rio hit the big doggie", "Rio dougie dougie", "Rio", "Rio hit the hit the dougie",
        ]
        for phrase in phrases {
            TestSupport.expect(TeddyCommand.trick(in: phrase) != .dougie, "Typed normally: \"\(phrase)\"")
        }
    }

    private static func testDanceLengthIsFourLoops() {
        TestSupport.expectApproximatelyEqual(TeddyDougie.beatSeconds, 60.0 / 85.0)
        TestSupport.expectApproximatelyEqual(TeddyDougie.loopSeconds, 4 * 60.0 / 85.0)
        TestSupport.expectEqual(TeddyDougie.loopCount, 4)
        TestSupport.expectApproximatelyEqual(TeddyDougie.danceSeconds, 4 * TeddyDougie.loopSeconds)
    }

    private static func sameAngle(_ a: Double, _ b: Double) -> Bool {
        abs(sin(a) - sin(b)) < 1e-9 && abs(cos(a) - cos(b)) < 1e-9
    }

    private static func isClose(_ a: TeddyBodyPose, _ b: TeddyBodyPose) -> Bool {
        func limb(_ x: TeddyBodyPose.Limb, _ y: TeddyBodyPose.Limb) -> Bool {
            sameAngle(x.angle, y.angle) && abs(x.length - y.length) < 1e-6
        }
        return abs(a.leanDegrees - b.leanDegrees) < 1e-9 && abs(a.bob - b.bob) < 1e-6
            && abs(a.hipShift - b.hipShift) < 1e-6 && abs(a.headTiltDegrees - b.headTiltDegrees) < 1e-9
            && limb(a.leftArm, b.leftArm) && limb(a.rightArm, b.rightArm)
            && limb(a.leftLeg, b.leftLeg) && limb(a.rightLeg, b.rightLeg)
            && abs(a.face.mouthOpen - b.face.mouthOpen) < 1e-6
    }

    private static func testCountOneLeansIntoAKneeDip() {
        let count1 = TeddyDougie.pose(atLoopFraction: 0)
        TestSupport.expectEqual(count1.leanDegrees, TeddyDougie.maxLeanDegrees)
        TestSupport.expect(count1.bob < 0, "Count 1 is a knee dip")
        let between = TeddyDougie.pose(atLoopFraction: 0.125)
        TestSupport.expect(between.bob > count1.bob, "It rises between beats")
        TestSupport.expect(count1.leftLeg.length < between.leftLeg.length, "A bent knee is shorter")
        TestSupport.expect(TeddyDougie.pose(atLoopFraction: 0.5).leanDegrees < -12.9, "Count 3 leans left")
        for beat in [0.25, 0.5, 0.75] {
            TestSupport.expect(TeddyDougie.pose(atLoopFraction: beat).bob < 0, "Dips on every beat")
        }
    }

    private static func testSecondHalfMirrorsFirst() {
        for i in 0..<64 {
            let t = Double(i) / 64
            let early = TeddyDougie.pose(atLoopFraction: t)
            let late = TeddyDougie.pose(atLoopFraction: t + 0.5)
            TestSupport.expect(isClose(late, TeddyDougie.mirrored(early)), "Mirror symmetry at \(t)")
        }
    }

    private static func testLoopIsContinuous() {
        TestSupport.expect(
            isClose(TeddyDougie.pose(atLoopFraction: 0), TeddyDougie.pose(atLoopFraction: 1)),
            "A loop ends where it begins"
        )
        // No arm jumps by more than half a radian between frames at 60 fps.
        var previous = TeddyDougie.pose(atDanceTime: 0)
        var time = 1.0 / 60
        while time <= TeddyDougie.loopSeconds * 2 {
            let pose = TeddyDougie.pose(atDanceTime: time)
            for (a, b) in [(previous.leftArm, pose.leftArm), (previous.rightArm, pose.rightArm)] {
                let diff = abs(TeddyDougie.normalized(a.angle - b.angle))
                TestSupport.expect(diff < 0.5, "Arm moves smoothly at \(time)")
            }
            previous = pose
            time += 1.0 / 60
        }
    }

    private static func tip(of limb: TeddyBodyPose.Limb, from shoulder: CGPoint) -> CGPoint {
        CGPoint(x: shoulder.x + sin(limb.angle) * limb.length, y: shoulder.y + cos(limb.angle) * limb.length)
    }

    /// The paw on the high-shoulder side brushes over the head: it reaches the top of the head
    /// around counts 1 and 2 (left paw, leaning right) and 3 and 4 (right paw, leaning left).
    private static func testPawBrushesOverTheHeadOnTheHighShoulderSide() {
        func highest(_ arm: (TeddyBodyPose) -> TeddyBodyPose.Limb, shoulder: CGPoint, from: Double, to: Double) -> CGPoint {
            var best = CGPoint(x: 0, y: 99)
            var t = from
            while t <= to {
                let paw = tip(of: arm(TeddyDougie.pose(atLoopFraction: t)), from: shoulder)
                if paw.y < best.y { best = paw }
                t += 0.005
            }
            return best
        }
        let left = highest({ $0.leftArm }, shoulder: TeddyDougie.leftShoulder, from: -0.05, to: 0.3)
        TestSupport.expect(left.y < 15 && abs(left.x - 20) < 12, "Left paw goes over the head on counts 1-2")
        let right = highest({ $0.rightArm }, shoulder: TeddyDougie.rightShoulder, from: 0.45, to: 0.8)
        TestSupport.expect(right.y < 15 && abs(right.x - 20) < 12, "Right paw goes over the head on counts 3-4")
        let resting = TeddyDougie.pose(atLoopFraction: 0.6).leftArm
        TestSupport.expect(tip(of: resting, from: TeddyDougie.leftShoulder).y > 30, "The other paw rests low meanwhile")
    }

    /// The brush glides along the hair: from the top of the head back over the ear, with the
    /// paw never crossing in front of the face (left of the face's left edge, or above it).
    private static func testBrushGlidesOverTheHairNotTheFace() {
        let faceLeft = 13.0, faceTop = 10.0
        var previousX = Double.infinity
        var t = -0.25
        while t < 0.5 {
            let paw = tip(of: TeddyDougie.brushingArm(at: t), from: TeddyDougie.leftShoulder)
            TestSupport.expect(Double(paw.x) < faceLeft || Double(paw.y) < faceTop, "Paw stays off the face at \(t)")
            t += 0.005
        }
        // From the top of the head (around count 1) back to the ear (count 2) the paw moves outward.
        t = 0.03
        while t <= 0.25 {
            let paw = tip(of: TeddyDougie.brushingArm(at: t), from: TeddyDougie.leftShoulder)
            TestSupport.expect(Double(paw.x) <= previousX + 0.01, "The brush glides back over the ear at \(t)")
            TestSupport.expect(paw.y < 16, "The paw stays on the head at \(t)")
            previousX = Double(paw.x)
            t += 0.01
        }
    }

    /// Ragdoll: on each weight shift the head lags behind the choreography, swings past it
    /// (follow-through) and settles, and it stays in a sane range for the whole dance.
    private static func testRagdollHeadLagsAndSettles() {
        let loop = TeddyDougie.loopSeconds
        func firstTime(from start: Double, reaching level: Double, _ value: (Double) -> Double) -> Double {
            var time = start
            while time < start + loop / 2, value(time) < level { time += 0.002 }
            return time
        }
        let shift = loop * 1.5 + 0.02 // the shift back to the right, heading into loop 3's count 1
        let target = TeddyDougie.pose(atLoopFraction: 0).headTiltDegrees
        // Halfway through the shift the choreographed head is upright, but the floppy head is
        // still tipped the old way (it lags)...
        let midShift = firstTime(from: shift, reaching: 0) { TeddyDougie.pose(atLoopFraction: $0 / loop).headTiltDegrees }
        let lagging = TeddyDougie.pose(atDanceTime: midShift).headTiltDegrees
        TestSupport.expect(lagging < -1, "The head lags the weight shift (\(lagging)°)")
        // ...then swings past the pose (follow-through)...
        var peak = -Double.infinity
        var time = shift
        while time < shift + loop / 2 { peak = max(peak, TeddyDougie.pose(atDanceTime: time).headTiltDegrees); time += 0.002 }
        TestSupport.expect(peak > target + 1, "The head swings past the pose (\(peak)° vs \(target)°)")
        // ...and settles back near it before the next shift.
        let settled = TeddyDougie.pose(atDanceTime: shift + loop * 0.45).headTiltDegrees
        TestSupport.expect(abs(settled - target) < 1.5, "Then it settles (\(settled)°)")
        for frame in TeddyDougie.ragdollFrames {
            TestSupport.expect(frame.headTiltDegrees.isFinite && abs(frame.headTiltDegrees) < 30, "Head stays in range")
            TestSupport.expect(frame.bob > -8 && frame.bob < 5, "Bounce stays in range")
            TestSupport.expect(frame.leftArm.angle.isFinite && frame.rightArm.angle.isFinite, "Arms stay finite")
        }
    }

    private static func testRagdollKeepsTheBrushOnTheHead() {
        let loop = TeddyDougie.loopSeconds
        var best = 99.0
        var time = loop * 2 - 0.15 * loop
        while time <= loop * 2 + 0.3 * loop {
            let pose = TeddyDougie.pose(atDanceTime: time)
            best = min(best, Double(tip(of: pose.leftArm, from: TeddyDougie.leftShoulder).y))
            time += 0.01
        }
        TestSupport.expect(best < 15.5, "With physics, the paw still reaches over the head (y \(best))")
    }

    /// While a paw rests low, the body's rocking swings it away from the choreographed angle.
    private static func testRagdollRestingArmSwingsLoose() {
        let loop = TeddyDougie.loopSeconds
        var largest = 0.0
        var time = loop * 2 + 0.5 * loop
        while time <= loop * 2 + 0.75 * loop {
            let simulated = TeddyDougie.pose(atDanceTime: time).leftArm.angle
            let choreographed = TeddyDougie.pose(atLoopFraction: time / loop).leftArm.angle
            largest = max(largest, abs(TeddyDougie.normalized(simulated - choreographed)))
            time += 0.01
        }
        TestSupport.expect(largest > 0.05 && largest < 1.2, "The resting arm swings loose (\(largest) rad)")
    }

    private static func testSongStartTime() {
        let defaults = UserDefaults(suiteName: "TeddyDougieTests.song")!
        defaults.removePersistentDomain(forName: "TeddyDougieTests.song")
        TestSupport.expect(TeddyDougieSong.fileURL(defaults: defaults) == nil, "No song: the built-in beat plays")
        defaults.set("/nonexistent/song.m4a", forKey: TeddyDougieSong.pathKey)
        TestSupport.expect(TeddyDougieSong.fileURL(defaults: defaults) == nil, "A missing file falls back to the beat")
        defaults.set(22.0, forKey: TeddyDougieSong.startSecondsKey)
        TestSupport.expectEqual(TeddyDougieSong.startTime(clampedTo: 230, defaults: defaults), 22)
        TestSupport.expectEqual(TeddyDougieSong.startTime(clampedTo: 15, defaults: defaults), 0)
        defaults.set(-5.0, forKey: TeddyDougieSong.startSecondsKey)
        TestSupport.expectEqual(TeddyDougieSong.startTime(clampedTo: 230, defaults: defaults), 0)
        defaults.removePersistentDomain(forName: "TeddyDougieTests.song")
    }

    private static func testBlinkIsOccasional() {
        var blinking = 0
        var time = 0.0
        while time < TeddyDougie.danceSeconds {
            if TeddyDougie.pose(atDanceTime: time).face.isBlinking { blinking += 1 }
            time += 1.0 / 60
        }
        TestSupport.expect(blinking > 0, "Blinks at least once")
        TestSupport.expect(Double(blinking) / 60 < 1.5, "Blinks only now and then")
    }

    private static func testRoutineStartsAndEndsInThePill() {
        let routine = TeddyDougie.routine(screenSize: screen, home: home, margin: margin)
        let start = routine.pose(at: 0)
        let end = routine.pose(at: routine.duration)
        TestSupport.expectEqual(start.center, home)
        TestSupport.expectEqual(start.scale, TeddyRoutine.homeScale)
        TestSupport.expectEqual(end.center, home)
        TestSupport.expectEqual(end.scale, TeddyRoutine.homeScale)
        TestSupport.expectEqual(TeddyRoutine.make(.dougie, screenSize: screen, home: home, margin: margin).duration, routine.duration)
    }

    private static func testRoutineDancesBetweenRuns() {
        let routine = TeddyDougie.routine(screenSize: screen, home: home, margin: margin)
        guard let window = routine.beatWindow else {
            TestSupport.expect(false, "The routine exposes the dance window")
            return
        }
        TestSupport.expectApproximatelyEqual(window.upperBound - window.lowerBound, TeddyDougie.danceSeconds)
        let landing = TeddyRoutine.landing(for: home, screenSize: screen, margin: margin)
        let middle = TeddyWiggle.middle(landing: landing, screenSize: screen)

        TestSupport.expectEqual(routine.pose(at: window.lowerBound - 0.05).action, .running)
        let atStart = routine.pose(at: window.lowerBound + 0.001)
        let atEnd = routine.pose(at: window.upperBound - 0.001)
        TestSupport.expectEqual(atStart.center, middle)
        TestSupport.expectEqual(atEnd.center, middle)
        for pose in [atStart, atEnd, routine.pose(at: (window.lowerBound + window.upperBound) / 2)] {
            guard case .posed = pose.action else {
                TestSupport.expect(false, "Dancing uses posed frames")
                return
            }
        }
        TestSupport.expectEqual(routine.pose(at: window.upperBound + 0.05).action, .running)
        let runBack = Double(hypot(middle.x - landing.x, middle.y - landing.y) / TeddyRoutine.runPointsPerSecond)
        TestSupport.expectApproximatelyEqual(routine.duration - window.upperBound, runBack + TeddyRoutine.jumpSeconds)
        for trick in [TeddyTrick.wiggle, .goCrazy] {
            TestSupport.expect(
                TeddyRoutine.make(trick, screenSize: screen, home: home, margin: margin).beatWindow == nil,
                "Other tricks have no music"
            )
        }
    }

    private static func testBeatLength() {
        TestSupport.expectApproximatelyEqual(TeddyBeatPattern.loopSeconds, 2 * TeddyDougie.loopSeconds)
        let frames = TeddyBeatPattern.frameCount(sampleRate: 44_100)
        TestSupport.expect(abs(Double(frames) - 8 * 4 * 44_100 * 60 / 85 / 4 * 1) <= 1, "Two bars at 85 BPM")
        TestSupport.expectEqual(TeddyBeatPattern.render().count, frames)
    }

    private static func testBeatPatternTiming() {
        TestSupport.expectEqual(TeddyBeatPattern.startFrame(ofStep: 0), 0)
        // One beat = four steps = 60/85 s.
        let beat = TeddyBeatPattern.startFrame(ofStep: 4)
        TestSupport.expect(abs(Double(beat) - 44_100 * 60 / 85) <= 1, "A beat is 60/85 s")
        TestSupport.expectEqual(TeddyBeatPattern.loopSteps(TeddyBeatPattern.clapSteps), [4, 12, 20, 28])
        TestSupport.expect(TeddyBeatPattern.loopSteps(TeddyBeatPattern.kickSteps).allSatisfy { $0 < 32 }, "Kicks stay in the loop")
    }

    private static func testBeatIsAudibleAndBounded() {
        let samples = TeddyBeatPattern.render()
        let peak = samples.map { abs($0) }.max() ?? 0
        TestSupport.expect(peak > 0.2, "The beat is not silent")
        TestSupport.expect(peak <= 1, "The beat never clips")
        TestSupport.expect(abs(samples[samples.count - 1]) < 0.01, "The loop seam is quiet")
        TestSupport.expect(samples == TeddyBeatPattern.render(), "Rendering is deterministic")
        // Safe to call repeatedly without ever starting.
        let beat = TeddyBeat()
        beat.stop()
        beat.stop()
    }
}
