import Foundation

/// Synthetic trackpad frames; never touches the real trackpad.
enum TapGestureDetectorTests {
    private typealias Finger = (id: Int, x: Float, y: Float)

    private static func frame(_ t: TimeInterval, _ fingers: [Finger], size: Float = 0.5) -> TouchFrame {
        TouchFrame(
            timestamp: t,
            touches: fingers.map { TouchPoint(id: $0.id, x: $0.x, y: $0.y, size: size) }
        )
    }

    private static let three: [Finger] = [(1, 0.3, 0.5), (2, 0.5, 0.5), (3, 0.7, 0.5)]

    /// Feeds frames and returns every time a tap fired.
    private static func fire(_ frames: [TouchFrame], detector: inout TapGestureDetector) -> [TimeInterval] {
        var taps: [TimeInterval] = []
        for f in frames where detector.process(f) { taps.append(f.timestamp) }
        return taps
    }

    private static func offset(_ fingers: [Finger], dx: Float = 0, dy: Float = 0) -> [Finger] {
        fingers.map { ($0.id, $0.x + dx, $0.y + dy) }
    }

    static func run() {
        testCleanTap()
        testTapFiresOnlyWhenAllLift()
        testSlowTap()
        testStaggeredLanding()
        testSwipe()
        testJitterIsStillATap()
        testTapThatBecomesDrag()
        testWrongFingerCounts()
        testFourthFingerArrives()
        testPalm()
        testDebounce()
        testRecoveryAfterInvalidGesture()
        testStaggeredLift()
        testIdleNoise()
        testReset()
    }

    private static func testCleanTap() {
        var d = TapGestureDetector()
        let taps = fire([
            frame(0.00, three), frame(0.03, three), frame(0.06, three), frame(0.10, three),
            frame(0.12, []),
        ], detector: &d)
        TestSupport.expectEqual(taps, [0.12])
    }

    private static func testTapFiresOnlyWhenAllLift() {
        var d = TapGestureDetector()
        var taps = fire([
            frame(0.00, three), frame(0.08, three),
            frame(0.10, Array(three.prefix(2))),
        ], detector: &d)
        TestSupport.expectEqual(taps, [])
        taps = fire([frame(0.11, [])], detector: &d)
        TestSupport.expectEqual(taps, [0.11])
    }

    private static func testSlowTap() {
        var d = TapGestureDetector()
        let taps = fire([
            frame(0.00, three), frame(0.20, three), frame(0.45, three), frame(0.50, []),
        ], detector: &d)
        TestSupport.expectEqual(taps, [])
    }

    private static func testStaggeredLanding() {
        // Fingers land over 90 ms: still one tap.
        var d = TapGestureDetector()
        var taps = fire([
            frame(0.00, [three[0]]),
            frame(0.04, Array(three.prefix(2))),
            frame(0.09, three),
            frame(0.15, three),
            frame(0.18, []),
        ], detector: &d)
        TestSupport.expectEqual(taps, [0.18])

        // Third finger lands 200 ms after the first: not a deliberate three-finger tap.
        d = TapGestureDetector()
        taps = fire([
            frame(0.00, [three[0]]),
            frame(0.05, Array(three.prefix(2))),
            frame(0.20, three),
            frame(0.25, three),
            frame(0.28, []),
        ], detector: &d)
        TestSupport.expectEqual(taps, [])
    }

    private static func testSwipe() {
        // Spaces / Mission Control swipe: three fingers travel across the pad quickly.
        var d = TapGestureDetector()
        let taps = fire([
            frame(0.00, three),
            frame(0.03, offset(three, dx: 0.03)),
            frame(0.06, offset(three, dx: 0.09)),
            frame(0.09, offset(three, dx: 0.18)),
            frame(0.12, offset(three, dx: 0.30)),
            frame(0.15, []),
        ], detector: &d)
        TestSupport.expectEqual(taps, [])

        // Vertical swipe (Mission Control).
        d = TapGestureDetector()
        let vertical = fire([
            frame(0.00, three),
            frame(0.05, offset(three, dy: 0.08)),
            frame(0.10, offset(three, dy: 0.25)),
            frame(0.14, []),
        ], detector: &d)
        TestSupport.expectEqual(vertical, [])
    }

    private static func testJitterIsStillATap() {
        var d = TapGestureDetector()
        let taps = fire([
            frame(0.00, three),
            frame(0.04, offset(three, dx: 0.008, dy: -0.006)),
            frame(0.08, offset(three, dx: -0.005, dy: 0.01)),
            frame(0.12, []),
        ], detector: &d)
        TestSupport.expectEqual(taps, [0.12])
    }

    private static func testTapThatBecomesDrag() {
        var d = TapGestureDetector()
        let taps = fire([
            frame(0.00, three),
            frame(0.08, three),
            frame(0.12, offset(three, dx: 0.10)),
            frame(0.16, []),
        ], detector: &d)
        TestSupport.expectEqual(taps, [])
    }

    private static func testWrongFingerCounts() {
        var d = TapGestureDetector()
        TestSupport.expectEqual(
            fire([frame(0.0, Array(three.prefix(2))), frame(0.05, Array(three.prefix(2))), frame(0.1, [])], detector: &d),
            [],
        )
        TestSupport.expectEqual(
            fire([frame(0.0, [three[0]]), frame(0.05, [three[0]]), frame(0.1, [])], detector: &d),
            [],
        )
        let four: [Finger] = three + [(4, 0.9, 0.5)]
        TestSupport.expectEqual(
            fire([frame(0.0, four), frame(0.05, four), frame(0.1, [])], detector: &d),
            [],
        )
        let five: [Finger] = four + [(5, 0.1, 0.5)]
        TestSupport.expectEqual(
            fire([frame(0.0, five), frame(0.05, five), frame(0.1, [])], detector: &d),
            [],
        )
    }

    private static func testFourthFingerArrives() {
        var d = TapGestureDetector()
        let four: [Finger] = three + [(4, 0.9, 0.5)]
        TestSupport.expectEqual(
            fire([frame(0.0, three), frame(0.05, four), frame(0.08, three), frame(0.12, [])], detector: &d),
            [],
        )
        // Four land, one lifts early leaving three: still not a three-finger tap.
        TestSupport.expectEqual(
            fire([frame(1.0, four), frame(1.04, three), frame(1.08, [])], detector: &d),
            []
        )
    }

    private static func testPalm() {
        var d = TapGestureDetector()
        let palm = frame(0.0, three, size: 9.0)
        TestSupport.expectEqual(
            fire([palm, frame(0.05, three, size: 9.0), frame(0.1, [])], detector: &d),
            [],
        )
        // One normal finger set where a single contact is huge.
        let mixed = TouchFrame(timestamp: 1.0, touches: [
            TouchPoint(id: 1, x: 0.3, y: 0.5, size: 0.5),
            TouchPoint(id: 2, x: 0.5, y: 0.5, size: 0.5),
            TouchPoint(id: 3, x: 0.7, y: 0.5, size: 9.0),
        ])
        TestSupport.expectEqual(
            fire([mixed, frame(1.1, [])], detector: &d),
            []
        )
    }

    private static func testDebounce() {
        var d = TapGestureDetector()
        let taps = fire([
            frame(0.00, three), frame(0.10, []),   // tap, fires at 0.10
            frame(0.40, three), frame(0.50, []),   // 0.40 s later: swallowed
            frame(0.90, three), frame(1.00, []),   // 0.90 s after the first: counts
        ], detector: &d)
        TestSupport.expectEqual(taps, [0.10, 1.00])
    }

    private static func testRecoveryAfterInvalidGesture() {
        var d = TapGestureDetector()
        let taps = fire([
            frame(0.0, three), frame(0.05, offset(three, dx: 0.3)), frame(0.1, []),  // swipe
            frame(1.0, three), frame(1.08, []),                                      // clean tap
        ], detector: &d)
        TestSupport.expectEqual(taps, [1.08])
    }

    private static func testStaggeredLift() {
        var d = TapGestureDetector()
        let taps = fire([
            frame(0.00, three),
            frame(0.10, Array(three.prefix(2))),
            frame(0.13, [three[0]]),
            frame(0.16, []),
        ], detector: &d)
        TestSupport.expectEqual(taps, [0.16])

        // Lift two fingers then touch down again with a new id: not a tap.
        d = TapGestureDetector()
        let again = fire([
            frame(0.00, three),
            frame(0.05, [three[0]]),
            frame(0.08, [three[0], (9, 0.4, 0.5), (10, 0.6, 0.5)]),
            frame(0.12, []),
        ], detector: &d)
        TestSupport.expectEqual(again, [])
    }

    private static func testIdleNoise() {
        var d = TapGestureDetector()
        TestSupport.expectEqual(fire([frame(0.0, []), frame(0.1, []), frame(0.2, [])], detector: &d), [])
    }

    private static func testReset() {
        var d = TapGestureDetector()
        _ = d.process(frame(0.0, three))
        d.reset()
        TestSupport.expectEqual(d.process(frame(0.05, [])), false)
        let taps = fire([frame(1.0, three), frame(1.05, [])], detector: &d)
        TestSupport.expectEqual(taps, [1.05])
    }
}
