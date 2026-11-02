import CoreGraphics
import Foundation

/// The "Teddy go crazy" trigger and the bear's trip around the screen. Synthetic inputs only.
enum TeddyBearTests {
    static func run() {
        testGoCrazyMatchesOnlyTheWholePhrase()
        testTripStartsAndEndsInThePill()
        testTripLandsBelowThePillAndRunsTheLoop()
        testTripDurationCoversJumpsAndLoop()
    }

    private static func testGoCrazyMatchesOnlyTheWholePhrase() {
        for phrase in ["Teddy, go crazy!", "teddy go crazy.", "Teddie goes crazy", "  TEDDY GO CRAZY  "] {
            TestSupport.expect(TeddyCommand.isGoCrazy(phrase), "Triggers on \"\(phrase)\"")
        }
        for phrase in ["Teddy go crazy now", "I told Teddy to go crazy", "go crazy teddy", "", "Teddy"] {
            TestSupport.expect(!TeddyCommand.isGoCrazy(phrase), "Typed normally: \"\(phrase)\"")
        }
    }

    /// 1000 x 800 screen, bear sitting in the pill at (500, 20), 40 pt margin.
    private static let track = TeddyLap.track(
        screenSize: CGSize(width: 1000, height: 800), home: CGPoint(x: 500, y: 20), margin: 40
    )

    private static func testTripStartsAndEndsInThePill() {
        let start = TeddyLap.pose(at: 0, on: track)
        TestSupport.expectEqual(start.center, CGPoint(x: 500, y: 20))
        TestSupport.expectEqual(start.scale, TeddyLap.homeScale)
        TestSupport.expect(start.isJumping, "It leaves the pill with a jump")

        let end = TeddyLap.pose(at: TeddyLap.duration(of: track) + 1, on: track)
        TestSupport.expectEqual(end.center, CGPoint(x: 500, y: 20))
        TestSupport.expectEqual(end.scale, TeddyLap.homeScale)
        TestSupport.expect(!end.isJumping, "It ends sitting in the pill")
    }

    private static func testTripLandsBelowThePillAndRunsTheLoop() {
        TestSupport.expectEqual(track.landing, CGPoint(x: 500, y: 20 + TeddyLap.landingDrop))

        let landed = TeddyLap.pose(at: TeddyLap.jumpSeconds, on: track)
        TestSupport.expectEqual(landed.center, track.landing)
        TestSupport.expectEqual(landed.scale, 1)
        TestSupport.expect(!landed.isJumping && landed.facesRight, "Lands and runs right")

        // Top right (460) + right side (630) + 460 along the bottom = halfway along the bottom.
        let seconds = TeddyLap.jumpSeconds + TimeInterval((460 + 630 + 460) / TeddyLap.runPointsPerSecond)
        let bottom = TeddyLap.pose(at: seconds, on: track)
        TestSupport.expect(abs(bottom.center.x - 500) < 0.01 && abs(bottom.center.y - 760) < 0.01, "Runs along the bottom")
        TestSupport.expect(!bottom.facesRight, "Faces left along the bottom")
    }

    private static func testTripDurationCoversJumpsAndLoop() {
        // Loop: 460 + 630 + 920 + 630 + 460 = 3100 pt.
        let expected = TeddyLap.jumpSeconds * 2 + TimeInterval(3100 / TeddyLap.runPointsPerSecond)
        TestSupport.expect(abs(TeddyLap.duration(of: track) - expected) < 0.0001, "One lap plus two jumps")
    }
}
