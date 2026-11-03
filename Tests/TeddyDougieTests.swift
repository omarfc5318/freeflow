import CoreGraphics
import Foundation

/// The Dougie trick: phrase matching, the dance timeline, the routine and the beat pattern.
enum TeddyDougieTests {
    static func run() {
        testPhraseVariants()
        testNearMissesAreTypedNormally()
        testDanceLengthIsEightLoops()
        testTimingFollowsTheTempo()
        testBadTempoFallsBack()
        testCountOneStepsAndDrops()
        testStepTouchFeet()
        testShouldersDropOnTheStepSide()
        testTwistFollowsTheStep()
        testElbowsStayTuckedAndForearmsSwap()
        testSecondHalfMirrorsFirst()
        testLoopIsContinuous()
        testHairBrushFlourishOnEveryFourthLoop()
        testRagdollHeadLagsAndSettles()
        testRagdollForearmsFollowThrough()
        testRagdollKeepsTheFlourishOnTheHead()
        testRagdollIsStableAtAnyTempo()
        testBlinkIsOccasional()
        testRoutineStartsAndEndsInThePill()
        testRoutineWalksInDancesAndWalksBack()
        testRoutineFollowsTheTempo()
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

    private static func testDanceLengthIsEightLoops() {
        TestSupport.expectApproximatelyEqual(TeddyDougie.beatSeconds, 60.0 / 85.0)
        TestSupport.expectApproximatelyEqual(TeddyDougie.loopSeconds, 4 * 60.0 / 85.0)
        TestSupport.expectEqual(TeddyDougie.loopCount, 8)
        TestSupport.expectApproximatelyEqual(TeddyDougie.danceSeconds, 8 * TeddyDougie.loopSeconds)
        TestSupport.expect(abs(TeddyDougie.danceSeconds - 22.6) < 0.1, "About the length of the chorus")
        TestSupport.expectEqual(TeddyDougie.ragdollFrames().count, Int((TeddyDougie.danceSeconds * 240).rounded(.up)) + 1)
    }

    private static func testTimingFollowsTheTempo() {
        TestSupport.expectApproximatelyEqual(TeddyDougie.beatSeconds(bpm: 120), 0.5)
        TestSupport.expectApproximatelyEqual(TeddyDougie.loopSeconds(bpm: 120), 2)
        TestSupport.expectApproximatelyEqual(TeddyDougie.danceSeconds(bpm: 120), 16)
        TestSupport.expectApproximatelyEqual(TeddyDougie.danceSeconds(bpm: 85), TeddyDougie.danceSeconds)
        // The precomputed frames cover the whole dance at each tempo and are cached per tempo.
        TestSupport.expectEqual(TeddyDougie.ragdollFrames(bpm: 120).count, 16 * 240 + 1)
        TestSupport.expect(TeddyDougie.ragdollFrames(bpm: 120) == TeddyDougie.ragdollFrames(bpm: 120), "Deterministic")
        TestSupport.expect(TeddyDougie.ragdollFrames(bpm: 120).count != TeddyDougie.ragdollFrames(bpm: 85).count, "Per tempo")
        // The choreography follows the loop fraction, so counts land on the beat at any tempo.
        for bpm in [70.0, 85, 128] {
            let loop = TeddyDougie.loopSeconds(bpm: bpm)
            let a = TeddyDougie.pose(atDanceTime: loop * 2.25, bpm: bpm)
            let reference = TeddyDougie.pose(atLoopFraction: 2.25)
            // (The frames are sampled at 240 Hz and blended, so allow a hair of interpolation error.)
            TestSupport.expect(abs(a.leanDegrees - reference.leanDegrees) < 0.05, "Lean follows loop fraction at \(bpm) BPM")
            TestSupport.expect(abs(a.rightFootShift - reference.rightFootShift) < 0.05, "Feet follow loop fraction at \(bpm) BPM")
        }
        TestSupport.expect(TeddyDougie.isBlinking(atDanceTime: TeddyDougie.loopSeconds(bpm: 120) * 0.9 + 0.01, bpm: 120), "Blinks at 120 BPM")
    }

    private static func testBadTempoFallsBack() {
        TestSupport.expectEqual(TeddyDougie.sanitized(bpm: .nan), 85)
        TestSupport.expectEqual(TeddyDougie.sanitized(bpm: 0), TeddyDougie.bpmRange.lowerBound)
        TestSupport.expectEqual(TeddyDougie.sanitized(bpm: 9999), TeddyDougie.bpmRange.upperBound)
        TestSupport.expectEqual(TeddyDougie.sanitized(bpm: 100), 100)
    }

    private static func sameAngle(_ a: Double, _ b: Double) -> Bool {
        abs(sin(a) - sin(b)) < 1e-9 && abs(cos(a) - cos(b)) < 1e-9
    }

    private static func isClose(_ a: TeddyBodyPose, _ b: TeddyBodyPose) -> Bool {
        func limb(_ x: TeddyBodyPose.Limb, _ y: TeddyBodyPose.Limb) -> Bool {
            sameAngle(x.angle, y.angle) && abs(x.length - y.length) < 1e-6
        }
        func optional(_ x: TeddyBodyPose.Limb?, _ y: TeddyBodyPose.Limb?) -> Bool {
            switch (x, y) {
            case let (x?, y?): return limb(x, y)
            case (nil, nil): return true
            default: return false
            }
        }
        return abs(a.leanDegrees - b.leanDegrees) < 1e-9 && abs(a.bob - b.bob) < 1e-6
            && abs(a.hipShift - b.hipShift) < 1e-6 && abs(a.headTiltDegrees - b.headTiltDegrees) < 1e-9
            && abs(a.twist - b.twist) < 1e-9
            && limb(a.leftArm, b.leftArm) && limb(a.rightArm, b.rightArm)
            && optional(a.leftForearm, b.leftForearm) && optional(a.rightForearm, b.rightForearm)
            && limb(a.leftLeg, b.leftLeg) && limb(a.rightLeg, b.rightLeg)
            && abs(a.leftShoulderLift - b.leftShoulderLift) < 1e-6 && abs(a.rightShoulderLift - b.rightShoulderLift) < 1e-6
            && abs(a.leftFootShift - b.leftFootShift) < 1e-6 && abs(a.rightFootShift - b.rightFootShift) < 1e-6
            && abs(a.leftFootLift - b.leftFootLift) < 1e-6 && abs(a.rightFootLift - b.rightFootLift) < 1e-6
            && abs(a.face.mouthOpen - b.face.mouthOpen) < 1e-6
    }

    /// Count 1: step out wide to the right and drop into the knees, leaning right.
    private static func testCountOneStepsAndDrops() {
        let count1 = TeddyDougie.pose(atLoopFraction: 0)
        TestSupport.expect(count1.leanDegrees > 9 && count1.leanDegrees < 12, "Count 1 leans right about 10 degrees")
        TestSupport.expect(count1.bob < -1.5, "Count 1 is a knee drop")
        TestSupport.expect(count1.rightFootShift >= TeddyDougie.stanceShift * 0.875, "The right foot steps out wide")
        TestSupport.expect(count1.leftFootShift <= -TeddyDougie.stanceShift * 0.875, "The left foot is still out on the other side")
        let between = TeddyDougie.pose(atLoopFraction: 0.125)
        TestSupport.expect(between.bob > count1.bob + 1, "The body rises a little between counts")
        TestSupport.expect(count1.leftLeg.length < between.leftLeg.length, "A bent knee is shorter")
        TestSupport.expect(TeddyDougie.pose(atLoopFraction: 0.5).leanDegrees < -9, "Count 3 leans left")
        for count in [0.0, 0.25, 0.5, 0.75] {
            TestSupport.expect(TeddyDougie.pose(atLoopFraction: count).bob < -0.5, "Knees dip on every count")
        }
        let deepest = [0.0, 0.5].map { TeddyDougie.pose(atLoopFraction: $0).bob }
        let shallow = [0.25, 0.75].map { TeddyDougie.pose(atLoopFraction: $0).bob }
        TestSupport.expect(deepest.max()! < shallow.min()!, "The drops on counts 1 and 3 are deeper")
    }

    /// Step-touch: the foot steps out on count 1; on count 2 the other foot slides in beside it
    /// and taps (a small lift); counts 3 and 4 mirror that.
    private static func testStepTouchFeet() {
        let one = TeddyDougie.pose(atLoopFraction: 0)
        let two = TeddyDougie.pose(atLoopFraction: 0.25)
        TestSupport.expect(one.rightFootLift < 0.05, "The stepping foot is down and takes the weight on count 1")
        TestSupport.expect(abs(two.leftFootShift - two.rightFootShift) < 0.1, "On count 2 the left foot is beside the right")
        TestSupport.expect(two.leftFootShift > TeddyDougie.stanceShift * 0.875, "Both feet are over on the right")
        var tap = 0.0
        var t = 0.25
        while t < 0.4 { tap = max(tap, TeddyDougie.pose(atLoopFraction: t).leftFootLift); t += 0.005 }
        TestSupport.expect(tap >= 0.8 && tap <= 2, "A small toe tap after the slide (\(tap))")
        TestSupport.expect(TeddyDougie.pose(atLoopFraction: 0.6).leftFootLift < 0.05, "The tap is over")
        // It travels out before count 1: the right foot is on its way across just before.
        let before = TeddyDougie.pose(atLoopFraction: 0.93)
        TestSupport.expect(before.rightFootShift < one.rightFootShift - 0.5 && before.rightFootLift > 0.5, "The foot is lifted and stepping out")
        // Counts 3 and 4: the left foot steps out, then the right slides in and taps.
        let three = TeddyDougie.pose(atLoopFraction: 0.5)
        TestSupport.expect(three.leftFootShift <= -TeddyDougie.stanceShift * 0.875 && three.leftFootLift < 0.05, "The left foot steps out on count 3")
        let four = TeddyDougie.pose(atLoopFraction: 0.75)
        TestSupport.expect(abs(four.leftFootShift - four.rightFootShift) < 0.1, "On count 4 the right foot is beside the left")
        TestSupport.expect(TeddyDougie.pose(atLoopFraction: 0.79).rightFootLift > 0.8, "The right foot taps")
    }

    /// The shoulder on the step side drops and the other rises.
    private static func testShouldersDropOnTheStepSide() {
        let one = TeddyDougie.pose(atLoopFraction: 0)
        TestSupport.expect(one.rightShoulderLift < -1.5 && one.rightShoulderLift > -2.2, "Right shoulder drops on count 1")
        TestSupport.expect(one.leftShoulderLift > 1.2 && one.leftShoulderLift < 1.8, "Left shoulder rises on count 1")
        let three = TeddyDougie.pose(atLoopFraction: 0.5)
        TestSupport.expect(three.leftShoulderLift < -1.5, "Left shoulder drops on count 3")
        TestSupport.expect(three.rightShoulderLift > 1.2, "Right shoulder rises on count 3")
        // It rolls through the "&" rather than jumping.
        var previous = TeddyDougie.pose(atLoopFraction: 0.3).leftShoulderLift
        var t = 0.3
        while t < 0.6 {
            t += 1.0 / 240
            let lift = TeddyDougie.pose(atLoopFraction: t).leftShoulderLift
            TestSupport.expect(abs(lift - previous) < 0.15,"Shoulders roll smoothly at \(t)")
            previous = lift
        }
    }

    private static func testTwistFollowsTheStep() {
        TestSupport.expect(TeddyDougie.pose(atLoopFraction: 0).twist > 0.35, "The chest turns right with the step on count 1")
        TestSupport.expect(TeddyDougie.pose(atLoopFraction: 0.25).twist > 0.35, "And holds through count 2")
        TestSupport.expect(TeddyDougie.pose(atLoopFraction: 0.5).twist < -0.35, "It turns left on count 3")
        TestSupport.expect(TeddyDougie.pose(atLoopFraction: 0.75).twist < -0.35, "And holds through count 4")
        for i in 0..<200 {
            TestSupport.expect(abs(TeddyDougie.pose(atLoopFraction: Double(i) / 200).twist) <= 0.45, "Twist stays within range")
        }
    }

    /// Elbows pinned at the sides; the raised forearm sits by the shoulder while the other
    /// drops across the belly, and they swap through the "&".
    private static func testElbowsStayTuckedAndForearmsSwap() {
        var t = 0.0
        while t < 1 {
            let pose = TeddyDougie.pose(atLoopFraction: t)
            TestSupport.expect(abs(pose.leftArm.angle) < 0.2 && abs(pose.rightArm.angle) < 0.2, "Upper arms stay at the sides at \(t)")
            t += 0.01
        }
        let one = TeddyDougie.pose(atLoopFraction: 0)
        let fist = TeddyDougie.leftPaw(in: one)
        TestSupport.expect(fist.x < 12.6 && abs(fist.y - 27) < 4, "Count 1: left fist by the shoulder, just outside it (\(fist))")
        TestSupport.expect(one.leftForearm.map { $0.angle < -2.6 } ?? false, "The forearm is folded up")
        let belly = TeddyDougie.rightPaw(in: one)
        TestSupport.expect(belly.x > 17 && belly.x < 24 && belly.y > 30 && belly.y < 38, "Count 1: right paw in front of the belly (\(belly))")
        let three = TeddyDougie.pose(atLoopFraction: 0.5)
        let rightFist = TeddyDougie.rightPaw(in: three)
        let leftBelly = TeddyDougie.leftPaw(in: three)
        TestSupport.expect(rightFist.x > 27.4 && abs(rightFist.y - 27) < 4, "Count 3: right fist by the shoulder")
        TestSupport.expect(leftBelly.x > 16 && leftBelly.x < 23 && leftBelly.y > 30, "Count 3: left paw across the belly")
        // Count 2: the raised forearm pumps on the beat.
        let beatBend = TeddyDougie.pose(atLoopFraction: 0.25).leftForearm?.angle ?? 0
        let offBeatBend = TeddyDougie.pose(atLoopFraction: 0.125).leftForearm?.angle ?? 0
        TestSupport.expect(abs(beatBend - offBeatBend) > 0.15, "The raised forearm bounces on the beat")
        // Through the "&" the arms swap: the left forearm goes from folded up to across.
        let before = TeddyDougie.pose(atLoopFraction: 0.3).leftForearm?.angle ?? 0
        let after = TeddyDougie.pose(atLoopFraction: 0.45).leftForearm?.angle ?? 0
        TestSupport.expect(before < -2 && after > 1, "The forearms swap through the & (\(before) to \(after))")
    }

    private static func testSecondHalfMirrorsFirst() {
        for i in 0..<64 {
            let t = Double(i) / 64
            let early = TeddyDougie.pose(atLoopFraction: t)
            let late = TeddyDougie.pose(atLoopFraction: t + 0.5)
            TestSupport.expect(isClose(late, TeddyDougie.mirrored(early)), "Mirror symmetry at \(t)")
            TestSupport.expect(isClose(TeddyDougie.mirrored(TeddyDougie.mirrored(early)), early), "Mirroring twice restores at \(t)")
        }
    }

    private static func testLoopIsContinuous() {
        TestSupport.expect(
            isClose(TeddyDougie.pose(atLoopFraction: 0), TeddyDougie.pose(atLoopFraction: 1)),
            "A loop ends where it begins"
        )
        // Nothing jumps between frames at 60 fps, including the elbows.
        var previous = TeddyDougie.pose(atDanceTime: 0)
        var time = 1.0 / 60
        while time <= TeddyDougie.loopSeconds * 2 {
            let pose = TeddyDougie.pose(atDanceTime: time)
            for (a, b) in [(previous.leftArm, pose.leftArm), (previous.rightArm, pose.rightArm)] {
                TestSupport.expect(abs(TeddyDougie.normalized(a.angle - b.angle)) < 0.5, "Arm moves smoothly at \(time)")
            }
            for (a, b) in [(previous.leftForearm, pose.leftForearm), (previous.rightForearm, pose.rightForearm)] {
                if let a, let b {
                    TestSupport.expect(abs(a.angle - b.angle) < 0.5, "Forearm moves smoothly at \(time)")
                }
            }
            TestSupport.expect(abs(pose.rightFootShift - previous.rightFootShift) < 1.2, "Feet move smoothly at \(time)")
            previous = pose
            time += 1.0 / 60
        }
    }

    /// On count 1 of every fourth loop the raised arm goes up over the side of the head with a
    /// bent elbow and back down; other loops keep the elbow-at-the-side pattern.
    private static func testHairBrushFlourishOnEveryFourthLoop() {
        func highestPaw(loop: Int) -> (paw: CGPoint, bend: Double) {
            var best = (paw: CGPoint(x: 0, y: 99), bend: 0.0)
            var t = 0.0
            while t < 0.3 {
                let pose = TeddyDougie.pose(atLoopFraction: Double(loop) + t)
                let paw = TeddyDougie.leftPaw(in: pose)
                if paw.y < best.paw.y { best = (paw, pose.leftForearm?.angle ?? 0) }
                t += 0.005
            }
            return best
        }
        for loop in [3, 7] {
            let top = highestPaw(loop: loop)
            TestSupport.expect(top.paw.y < 17 && abs(top.paw.x - 20) < 12, "Loop \(loop + 1): the paw goes over the head (\(top.paw))")
            TestSupport.expect(abs(top.bend) > 0.5, "...with a bent elbow (\(top.bend) rad)")
        }
        for loop in [0, 1, 2, 4, 5, 6] {
            TestSupport.expect(highestPaw(loop: loop).paw.y > 24, "Loop \(loop + 1) keeps the fist by the shoulder")
        }
        // It comes back to the elbow pattern: by count 2 the fist is at the shoulder again.
        let back = TeddyDougie.leftPaw(in: TeddyDougie.pose(atLoopFraction: 3.4))
        TestSupport.expect(back.y > 24, "The flourish returns to the elbow pattern")
        // The paw is computed through both segments: the upper arm alone would not reach.
        let pose = TeddyDougie.pose(atLoopFraction: 3.15)
        let upperOnly = TeddyDougie.pawTip(upper: pose.leftArm, forearm: nil,
                                           shoulder: CGPoint(x: 12.6, y: 28.5 - pose.leftShoulderLift))
        TestSupport.expect(TeddyDougie.leftPaw(in: pose).y < upperOnly.y, "The forearm adds the reach over the head")
    }

    /// Ragdoll: on each weight shift the head lags behind the choreography, swings past it
    /// (follow-through) and settles, and it stays in a sane range for the whole dance.
    private static func testRagdollHeadLagsAndSettles() {
        let loop = TeddyDougie.loopSeconds
        // The weight shifts back to the right through the "&" at 0.875 of a loop.
        let shift = loop * 2.8
        let target = TeddyDougie.pose(atLoopFraction: 0.125).headTiltDegrees
        var time = shift
        while TeddyDougie.pose(atLoopFraction: time / loop).headTiltDegrees < 0 { time += 0.002 }
        // When the choreographed head crosses upright, the floppy head is still tipped the old way...
        let lagging = TeddyDougie.pose(atDanceTime: time).headTiltDegrees
        TestSupport.expect(lagging < -1, "The head lags the weight shift (\(lagging)°)")
        // ...then swings past the pose (follow-through)...
        var peak = -Double.infinity
        time = shift
        while time < shift + loop * 0.35 { peak = max(peak, TeddyDougie.pose(atDanceTime: time).headTiltDegrees); time += 0.002 }
        TestSupport.expect(peak > target + 1, "The head swings past the pose (\(peak)° vs \(target)°)")
        // ...and settles back near it before the next shift.
        let settled = TeddyDougie.pose(atDanceTime: loop * 3.35).headTiltDegrees
        TestSupport.expect(abs(settled - target) < 2.5, "Then it settles (\(settled)°)")
    }

    /// The forearm that drops across the belly overshoots and settles instead of stopping dead.
    private static func testRagdollForearmsFollowThrough() {
        let loop = TeddyDougie.loopSeconds
        var largest = 0.0
        var time = loop * 2.3
        while time <= loop * 2.7 {
            let simulated = TeddyDougie.pose(atDanceTime: time).leftForearm?.angle ?? 0
            let choreographed = TeddyDougie.pose(atLoopFraction: time / loop).leftForearm?.angle ?? 0
            largest = max(largest, abs(simulated - choreographed))
            time += 0.005
        }
        TestSupport.expect(largest > 0.1 && largest < 2.5, "The forearm lags and follows through (\(largest) rad)")
        // The shoulders overshoot a little too.
        var overshoot = 0.0
        time = loop * 2.0
        while time <= loop * 3.0 {
            let simulated = Double(TeddyDougie.pose(atDanceTime: time).leftShoulderLift)
            let choreographed = Double(TeddyDougie.pose(atLoopFraction: time / loop).leftShoulderLift)
            overshoot = max(overshoot, abs(simulated - choreographed))
            time += 0.005
        }
        TestSupport.expect(overshoot > 0.05 && overshoot < 1.5, "Shoulders lag with a little overshoot (\(overshoot))")
    }

    private static func testRagdollKeepsTheFlourishOnTheHead() {
        let loop = TeddyDougie.loopSeconds
        var best = 99.0
        var time = loop * 3
        while time <= loop * 3.35 {
            best = min(best, Double(TeddyDougie.leftPaw(in: TeddyDougie.pose(atDanceTime: time)).y))
            time += 0.01
        }
        TestSupport.expect(best < 18, "With physics, the paw still reaches the head on the flourish (y \(best))")
    }

    /// Whatever the tempo, the simulation stays finite and in range, and is deterministic.
    private static func testRagdollIsStableAtAnyTempo() {
        for bpm in [50.0, 85, 128, 180] {
            let frames = TeddyDougie.ragdollFrames(bpm: bpm)
            TestSupport.expect(frames == TeddyDougie.ragdollFrames(bpm: bpm), "Deterministic at \(bpm) BPM")
            for frame in frames {
                TestSupport.expect(frame.headTiltDegrees.isFinite && abs(frame.headTiltDegrees) < 30, "Head stays in range at \(bpm) BPM")
                TestSupport.expect(frame.bob > -8 && frame.bob < 5, "Bounce stays in range at \(bpm) BPM")
                TestSupport.expect(frame.leftArm.angle.isFinite && frame.rightArm.angle.isFinite, "Arms stay finite")
                TestSupport.expect(abs(frame.leftArm.angle) < 3.3 && abs(frame.rightArm.angle) < 3.3, "Upper arms stay in range")
                for forearm in [frame.leftForearm, frame.rightForearm] {
                    TestSupport.expect(forearm.map { $0.angle.isFinite && abs($0.angle) < 4.6 } ?? false, "Elbows stay in range at \(bpm) BPM")
                }
                TestSupport.expect(abs(frame.leftShoulderLift) < 4 && abs(frame.rightShoulderLift) < 4, "Shoulders stay in range")
            }
        }
    }

    private static func testBlinkIsOccasional() {
        var blinking = 0
        var time = 0.0
        while time < TeddyDougie.danceSeconds {
            if TeddyDougie.pose(atDanceTime: time).face.isBlinking { blinking += 1 }
            time += 1.0 / 60
        }
        TestSupport.expect(blinking > 0, "Blinks at least once")
        TestSupport.expect(Double(blinking) / 60 < 2.5, "Blinks only now and then")
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

    /// Run to the middle, walk towards the viewer (scale 1 to danceScale), dance, walk back (danceScale to 1).
    private static func testRoutineWalksInDancesAndWalksBack() {
        let routine = TeddyDougie.routine(screenSize: screen, home: home, margin: margin)
        guard let window = routine.beatWindow else {
            TestSupport.expect(false, "The routine exposes the dance window")
            return
        }
        TestSupport.expectApproximatelyEqual(window.upperBound - window.lowerBound, TeddyDougie.danceSeconds)
        let landing = TeddyRoutine.landing(for: home, screenSize: screen, margin: margin)
        let middle = TeddyWiggle.middle(landing: landing, screenSize: screen)
        let runOut = Double(hypot(middle.x - landing.x, middle.y - landing.y) / TeddyRoutine.runPointsPerSecond)
        let approachStart = TeddyRoutine.jumpSeconds + runOut

        // The approach starts at normal size and grows to danceScale over about 0.8 s, walking in place.
        TestSupport.expectApproximatelyEqual(window.lowerBound - approachStart, TeddyDougie.approachSeconds)
        TestSupport.expectEqual(routine.pose(at: approachStart - 0.01).action, .running)
        TestSupport.expectEqual(routine.pose(at: approachStart - 0.01).scale, 1)
        let first = routine.pose(at: approachStart + 0.001)
        TestSupport.expectEqual(first.center, middle)
        TestSupport.expect(abs(first.scale - 1) < 0.01, "The approach starts at scale 1")
        var previousScale = first.scale
        var liftedFeet = 0
        var time = approachStart + 0.001
        while time < window.lowerBound {
            let pose = routine.pose(at: time)
            TestSupport.expect(pose.scale >= previousScale - 1e-9, "The approach only grows")
            previousScale = pose.scale
            if case let .posed(body) = pose.action, body.leftFootLift > 0.3 || body.rightFootLift > 0.3 { liftedFeet += 1 }
            TestSupport.expectEqual(pose.center, middle)
            time += 0.01
        }
        TestSupport.expect(liftedFeet > 20, "He walks in place while growing")
        let mid = routine.pose(at: approachStart + TeddyDougie.approachSeconds / 2).scale
        TestSupport.expect(mid > 1.2 && mid < TeddyDougie.danceScale - 0.3, "Halfway through the approach he is partly grown (\(mid))")

        // The dance happens at danceScale times the size.
        TestSupport.expect(abs(routine.pose(at: window.lowerBound).scale - TeddyDougie.danceScale) < 0.001, "Dance starts at full dance size")
        TestSupport.expectEqual(routine.pose(at: (window.lowerBound + window.upperBound) / 2).scale, TeddyDougie.danceScale)
        TestSupport.expectEqual(routine.pose(at: window.upperBound - 0.001).center, middle)
        for pose in [routine.pose(at: window.lowerBound + 0.001), routine.pose(at: (window.lowerBound + window.upperBound) / 2)] {
            guard case .posed = pose.action else {
                TestSupport.expect(false, "Dancing uses posed frames")
                return
            }
        }

        // Then he walks back to normal size and runs home.
        TestSupport.expect(abs(routine.pose(at: window.upperBound + 0.001).scale - TeddyDougie.danceScale) < 0.01, "The walk back starts at full dance size")
        let walkEnd = window.upperBound + TeddyDougie.walkBackSeconds
        TestSupport.expectApproximatelyEqual(TeddyDougie.walkBackSeconds, 0.6)
        TestSupport.expect(abs(routine.pose(at: walkEnd - 0.001).scale - 1) < 0.01, "The walk back ends at scale 1")
        TestSupport.expectEqual(routine.pose(at: walkEnd + 0.01).action, .running)
        TestSupport.expectEqual(routine.pose(at: walkEnd + 0.01).scale, 1)
        TestSupport.expectApproximatelyEqual(routine.duration - window.upperBound, TeddyDougie.walkBackSeconds + runOut + TeddyRoutine.jumpSeconds)
        TestSupport.expect(routine.pose(at: window.lowerBound - 0.05).scale < TeddyDougie.danceScale, "Still approaching just before the beat")
        for trick in [TeddyTrick.wiggle, .goCrazy] {
            TestSupport.expect(
                TeddyRoutine.make(trick, screenSize: screen, home: home, margin: margin).beatWindow == nil,
                "Other tricks have no music"
            )
        }
    }

    private static func testRoutineFollowsTheTempo() {
        let slow = TeddyDougie.routine(screenSize: screen, home: home, margin: margin, bpm: 60)
        let fast = TeddyDougie.routine(screenSize: screen, home: home, margin: margin, bpm: 120)
        guard let slowWindow = slow.beatWindow, let fastWindow = fast.beatWindow else {
            TestSupport.expect(false, "Both routines expose the dance window")
            return
        }
        TestSupport.expectApproximatelyEqual(slowWindow.upperBound - slowWindow.lowerBound, TeddyDougie.danceSeconds(bpm: 60))
        TestSupport.expectApproximatelyEqual(fastWindow.upperBound - fastWindow.lowerBound, 16)
        TestSupport.expectApproximatelyEqual(slowWindow.lowerBound, fastWindow.lowerBound)
        TestSupport.expectApproximatelyEqual(slow.duration - fast.duration, TeddyDougie.danceSeconds(bpm: 60) - 16)
        TestSupport.expectApproximatelyEqual(
            TeddyDougie.routine(screenSize: screen, home: home, margin: margin).duration,
            TeddyDougie.routine(screenSize: screen, home: home, margin: margin, bpm: 85).duration
        )
    }

    private static func testSongStartTime() {
        let (defaults, suite) = TestScratchDefaults.make("TeddyDougieSong")
        defer { TestScratchDefaults.remove(suite) }
        TestSupport.expect(TeddyDougieSong.fileURL(defaults: defaults) == nil, "No song: the built-in beat plays")
        defaults.set("/nonexistent/song.m4a", forKey: TeddyDougieSong.pathKey)
        TestSupport.expect(TeddyDougieSong.fileURL(defaults: defaults) == nil, "A missing file falls back to the beat")
        defaults.set(22.0, forKey: TeddyDougieSong.startSecondsKey)
        TestSupport.expectEqual(TeddyDougieSong.startTime(clampedTo: 230, defaults: defaults), 22)
        TestSupport.expectEqual(TeddyDougieSong.startTime(clampedTo: 15, defaults: defaults), 0)
        defaults.set(-5.0, forKey: TeddyDougieSong.startSecondsKey)
        TestSupport.expectEqual(TeddyDougieSong.startTime(clampedTo: 230, defaults: defaults), 0)
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
