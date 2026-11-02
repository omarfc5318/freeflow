import CoreGraphics
import Foundation

/// The bear's voice tricks and their trips around the screen. Synthetic inputs only.
enum TeddyBearTests {
    static func run() {
        testGoCrazyMatchesOnlyTheWholePhrase()
        testWiggleMatchesOnlyTheWholePhrase()
        testTripStartsAndEndsInThePill()
        testTripLandsBelowThePillAndRunsTheLoop()
        testTripDurationCoversJumpsAndLoop()
        testWiggleRoutineOrder()
        testWiggleRoutineEndsInThePill()
    }

    private static func testGoCrazyMatchesOnlyTheWholePhrase() {
        for phrase in ["Teddy, go crazy!", "teddy go crazy.", "Teddie goes crazy", "  TEDDY GO CRAZY  "] {
            TestSupport.expectEqual(TeddyCommand.trick(in: phrase), .goCrazy)
        }
        for phrase in ["Teddy go crazy now", "I told Teddy to go crazy", "go crazy teddy", "", "Teddy"] {
            TestSupport.expect(TeddyCommand.trick(in: phrase) == nil, "Typed normally: \"\(phrase)\"")
        }
    }

    private static func testWiggleMatchesOnlyTheWholePhrase() {
        for phrase in ["Teddy, do a wiggle.", "teddy do the wiggle", "Teddy wiggle!", "Teddy, do wiggles", "Teddie do your wiggle"] {
            TestSupport.expectEqual(TeddyCommand.trick(in: phrase), .wiggle)
        }
        for phrase in ["Do a wiggle", "Teddy, do a little wiggle", "Teddy can you do a wiggle", "wiggle teddy"] {
            TestSupport.expect(TeddyCommand.trick(in: phrase) == nil, "Typed normally: \"\(phrase)\"")
        }
    }

    /// 1000 x 800 screen, bear sitting in the pill at (500, 20), 40 pt margin.
    private static let screen = CGSize(width: 1000, height: 800)
    private static let home = CGPoint(x: 500, y: 20)
    private static let track = TeddyLap.track(screenSize: screen, home: home, margin: 40)

    private static func testTripStartsAndEndsInThePill() {
        let start = TeddyLap.pose(at: 0, on: track)
        TestSupport.expectEqual(start.center, home)
        TestSupport.expectEqual(start.scale, TeddyRoutine.homeScale)
        TestSupport.expect(start.isJumping, "It leaves the pill with a jump")

        let end = TeddyLap.pose(at: TeddyLap.duration(of: track) + 1, on: track)
        TestSupport.expectEqual(end.center, home)
        TestSupport.expectEqual(end.scale, TeddyRoutine.homeScale)
        TestSupport.expect(!end.isJumping, "It ends sitting in the pill")
    }

    private static func testTripLandsBelowThePillAndRunsTheLoop() {
        TestSupport.expectEqual(track.landing, CGPoint(x: 500, y: 20 + TeddyRoutine.landingDrop))

        let landed = TeddyLap.pose(at: TeddyRoutine.jumpSeconds, on: track)
        TestSupport.expectEqual(landed.center, track.landing)
        TestSupport.expectEqual(landed.scale, 1)
        TestSupport.expect(!landed.isJumping && landed.facesRight, "Lands and runs right")

        // Top right (460) + right side (630) + 460 along the bottom = halfway along the bottom.
        let seconds = TeddyRoutine.jumpSeconds + TimeInterval((460 + 630 + 460) / TeddyRoutine.runPointsPerSecond)
        let bottom = TeddyLap.pose(at: seconds, on: track)
        TestSupport.expect(abs(bottom.center.x - 500) < 0.01 && abs(bottom.center.y - 760) < 0.01, "Runs along the bottom")
        TestSupport.expect(!bottom.facesRight, "Faces left along the bottom")
    }

    private static func testTripDurationCoversJumpsAndLoop() {
        // Loop: 460 + 630 + 920 + 630 + 460 = 3100 pt.
        let expected = TeddyRoutine.jumpSeconds * 2 + TimeInterval(3100 / TeddyRoutine.runPointsPerSecond)
        TestSupport.expect(abs(TeddyLap.duration(of: track) - expected) < 0.0001, "One lap plus two jumps")
    }

    // Wiggle: lands at (500, 130), runs 270 pt down to the middle (500, 400).
    private static let wiggle = TeddyWiggle.routine(screenSize: screen, home: home, margin: 40)
    private static let runToMiddle = TimeInterval(270 / TeddyRoutine.runPointsPerSecond)
    private static let reachesMiddle = TeddyRoutine.jumpSeconds + runToMiddle
    private static let wiggleSeconds = TeddyWiggle.secondsPerWiggle * Double(TeddyWiggle.wiggleCount)

    private static func testWiggleRoutineOrder() {
        let middle = CGPoint(x: 500, y: 400)
        TestSupport.expectEqual(wiggle.pose(at: TeddyRoutine.jumpSeconds + runToMiddle / 2).action, .running)

        let turning = wiggle.pose(at: reachesMiddle + TeddyWiggle.turnSeconds / 2)
        TestSupport.expectEqual(turning.center, middle)
        if case let .turning(towardBack, progress) = turning.action {
            TestSupport.expect(towardBack && abs(progress - 0.5) < 0.0001, "Halfway through turning its back")
        } else {
            TestSupport.expect(false, "Turns around in the middle")
        }

        let wiggling = wiggle.pose(at: reachesMiddle + TeddyWiggle.turnSeconds + TeddyWiggle.secondsPerWiggle * 1.5)
        TestSupport.expectEqual(wiggling.center, middle)
        if case let .wiggling(phase) = wiggling.action {
            TestSupport.expect(abs(phase - 1.5) < 0.0001, "Halfway through the second wiggle")
        } else {
            TestSupport.expect(false, "Wiggles with its back turned")
        }

        let thumbs = wiggle.pose(at: reachesMiddle + TeddyWiggle.turnSeconds * 2 + wiggleSeconds + 0.5)
        TestSupport.expectEqual(thumbs.action, .thumbsUp)
        TestSupport.expectEqual(thumbs.center, middle)
    }

    private static func testWiggleRoutineEndsInThePill() {
        let expected = TeddyRoutine.jumpSeconds * 2 + runToMiddle * 2
            + TeddyWiggle.turnSeconds * 2 + wiggleSeconds + TeddyWiggle.thumbsUpSeconds
        TestSupport.expect(abs(wiggle.duration - expected) < 0.0001, "Jumps, runs, turns, wiggles and thumbs up")
        let end = wiggle.pose(at: wiggle.duration + 1)
        TestSupport.expectEqual(end.center, home)
        TestSupport.expectEqual(end.scale, TeddyRoutine.homeScale)
    }
}
