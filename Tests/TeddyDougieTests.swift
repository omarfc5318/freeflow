import CoreGraphics
import Foundation

/// The Dougie trick: phrase matching, the dance timeline, the routine and the beat pattern.
enum TeddyDougieTests {
    static func run() {
        testPhraseVariants()
        testNearMissesAreTypedNormally()
        testDanceLengthIsFourLoops()
        testKeyTimesEqualKeyframes()
        testSecondHalfMirrorsFirst()
        testLoopIsContinuous()
        testPawReachesTheHeadOnTheHighShoulderSide()
        testBlinkIsOccasional()
        testRoutineStartsAndEndsInThePill()
        testRoutineDancesBetweenRuns()
        testBeatLength()
        testBeatPatternTiming()
        testBeatIsAudibleAndBounded()
    }

    private static let screen = CGSize(width: 1440, height: 900)
    private static let home = CGPoint(x: 720, y: 24)
    private static let margin: CGFloat = 40

    private static func testPhraseVariants() {
        let phrases = [
            "Teddy, hit the Dougie.", "teddy hit the dougie", "Teddy do the Dougie", "teddy, dougie",
            "Teddy hit the Duggie", "Teddy hit the Dougy!", "Teddy, hit the doggie", "teddy hit the doggy",
            "Teddy does the Dougie", "  TEDDY HIT THE DOUGIE  ", "Teddie hit the dougie",
        ]
        for phrase in phrases {
            TestSupport.expectEqual(TeddyCommand.trick(in: phrase), .dougie)
        }
    }

    private static func testNearMissesAreTypedNormally() {
        let phrases = [
            "Teddy hit the dougie now", "I told Teddy to hit the dougie", "hit the dougie",
            "Teddy hit the dog", "Teddy hit the", "Teddy the dougie", "Teddy hit dougie please",
            "Teddy hit the big doggie", "Teddy dougie dougie", "Teddy", "Teddy hit the hit the dougie",
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

    private static func testKeyTimesEqualKeyframes() {
        for i in 0..<8 {
            let pose = TeddyDougie.pose(atLoopFraction: Double(i) / 8)
            TestSupport.expect(isClose(pose, TeddyDougie.keyframes[i]), "Key \(i) is reached on time")
        }
        let first = TeddyDougie.pose(atLoopFraction: 0)
        TestSupport.expectEqual(first.leanDegrees, 12)
        TestSupport.expect(first.bob < 0, "Count 1 is a knee bend")
        let rise = TeddyDougie.pose(atLoopFraction: 0.125)
        TestSupport.expectEqual(rise.bob, 0)
        TestSupport.expect(first.leftLeg.length < rise.leftLeg.length, "Bent knee is shorter")
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

    private static func testPawReachesTheHeadOnTheHighShoulderSide() {
        let count1 = TeddyDougie.keyframes[0]
        let paw = tip(of: count1.leftArm, from: TeddyDougie.leftShoulder)
        TestSupport.expect(paw.y < 15, "Paw is at head height")
        TestSupport.expect(abs(paw.x - 20) < 9.4, "Paw is beside the head")
        TestSupport.expect(count1.leanDegrees > 0, "Leaning right, so the left paw is high")
        let count3 = TeddyDougie.keyframes[4]
        TestSupport.expect(count3.leanDegrees < 0, "Count 3 leans left")
        TestSupport.expect(tip(of: count3.rightArm, from: TeddyDougie.rightShoulder).y < 15, "Right paw is high on count 3")
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
