import CoreGraphics
import Foundation

enum RioScreenFollowTests {
    // Cocoa space: origin bottom left of the primary display. Primary is 1440x900; the second
    // display sits to its right and hangs 180 points lower, 1920x1080.
    private static let primary = RioScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
    private static let second = RioScreenInfo(id: 2, frame: CGRect(x: 1440, y: -180, width: 1920, height: 1080))
    private static let screens = [primary, second]
    private static let primaryHeight: CGFloat = 900

    static func run() {
        testWindowOnEachScreen()
        testStraddlingWindowPicksLargestOverlap()
        testFallsBackToMouse()
        testFrontmostWindowSelection()
        testDebounce()
        testDockAndTimings()
    }

    private static func testWindowOnEachScreen() {
        // CG space: origin top left of the primary display, y down.
        let onSecond = CGRect(x: 1500, y: 100, width: 800, height: 600)
        TestSupport.expectEqual(
            RioScreenChoice.screenID(windowBounds: onSecond, mouse: CGPoint(x: 10, y: 10), screens: screens, primaryHeight: primaryHeight), 2)
        let onPrimary = CGRect(x: 100, y: 100, width: 800, height: 600)
        TestSupport.expectEqual(
            RioScreenChoice.screenID(windowBounds: onPrimary, mouse: CGPoint(x: 2000, y: 10), screens: screens, primaryHeight: primaryHeight), 1)
    }

    private static func testStraddlingWindowPicksLargestOverlap() {
        // 1000 wide starting at x=1200: 240 on the primary, 760 on the second.
        let straddle = CGRect(x: 1200, y: 100, width: 1000, height: 500)
        TestSupport.expectEqual(
            RioScreenChoice.screenID(windowBounds: straddle, mouse: .zero, screens: screens, primaryHeight: primaryHeight), 2)
        let mostlyPrimary = CGRect(x: 600, y: 100, width: 1000, height: 500)
        TestSupport.expectEqual(
            RioScreenChoice.screenID(windowBounds: mostlyPrimary, mouse: CGPoint(x: 2000, y: 0), screens: screens, primaryHeight: primaryHeight), 1)
    }

    private static func testFallsBackToMouse() {
        TestSupport.expectEqual(
            RioScreenChoice.screenID(windowBounds: nil, mouse: CGPoint(x: 2000, y: 100), screens: screens, primaryHeight: primaryHeight), 2)
        TestSupport.expectEqual(
            RioScreenChoice.screenID(windowBounds: .zero, mouse: CGPoint(x: 50, y: 100), screens: screens, primaryHeight: primaryHeight), 1)
        let offscreen = CGRect(x: 9000, y: 9000, width: 400, height: 400)
        TestSupport.expectEqual(
            RioScreenChoice.screenID(windowBounds: offscreen, mouse: CGPoint(x: 50, y: 100), screens: screens, primaryHeight: primaryHeight), 1)
        TestSupport.expectEqual(
            RioScreenChoice.screenID(windowBounds: nil, mouse: CGPoint(x: -5000, y: 100), screens: screens, primaryHeight: primaryHeight), nil)
        TestSupport.expectEqual(
            RioScreenChoice.screenID(windowBounds: nil, mouse: .zero, screens: [], primaryHeight: primaryHeight), nil)
    }

    private static func testFrontmostWindowSelection() {
        let entries = [
            RioWindowEntry(pid: 99, layer: 0, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 500, height: 500)),
            RioWindowEntry(pid: 42, layer: 25, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 1440, height: 24)),
            RioWindowEntry(pid: 42, layer: 0, alpha: 0, bounds: CGRect(x: 10, y: 10, width: 600, height: 600)),
            RioWindowEntry(pid: 42, layer: 0, alpha: 1, bounds: CGRect(x: 5, y: 5, width: 20, height: 20)),
            RioWindowEntry(pid: 42, layer: 0, alpha: 1, bounds: CGRect(x: 1500, y: 100, width: 700, height: 500)),
            RioWindowEntry(pid: 42, layer: 0, alpha: 1, bounds: CGRect(x: 100, y: 100, width: 700, height: 500)),
        ]
        TestSupport.expectEqual(
            RioScreenChoice.frontmostWindowBounds(in: entries, pid: 42), CGRect(x: 1500, y: 100, width: 700, height: 500))
        TestSupport.expectEqual(RioScreenChoice.frontmostWindowBounds(in: entries, pid: 7), nil)
        TestSupport.expectEqual(RioScreenChoice.frontmostWindowBounds(in: [], pid: 42), nil)
    }

    private static func testDebounce() {
        var debounce = RioScreenFollowDebounce(current: 1)
        // Same screen: nothing to do.
        TestSupport.expectEqual(debounce.observe(target: 1, now: 0, isBlocked: false), nil)
        // A new target must hold for 1.5 s.
        TestSupport.expectEqual(debounce.observe(target: 2, now: 10, isBlocked: false), nil)
        TestSupport.expectEqual(debounce.observe(target: 2, now: 11.4, isBlocked: false), nil)
        TestSupport.expectEqual(debounce.observe(target: 2, now: 11.5, isBlocked: false), 2)
        TestSupport.expectEqual(debounce.current, 2)
        TestSupport.expectEqual(debounce.observe(target: 2, now: 20, isBlocked: false), nil)

        // Flipping back and forth never settles.
        debounce.observe(target: 1, now: 30, isBlocked: false)
        debounce.observe(target: 2, now: 31, isBlocked: false)
        TestSupport.expectEqual(debounce.observe(target: 1, now: 31.6, isBlocked: false), nil)
        TestSupport.expectEqual(debounce.observe(target: 1, now: 32.5, isBlocked: false), nil)
        TestSupport.expectEqual(debounce.observe(target: 1, now: 33.2, isBlocked: false), 1)

        // Blocked (Dock run, trick, speaking, confirmation, help): never moves, then moves once free.
        var blocked = RioScreenFollowDebounce(current: 1)
        blocked.observe(target: 2, now: 0, isBlocked: true)
        TestSupport.expectEqual(blocked.observe(target: 2, now: 5, isBlocked: true), nil)
        TestSupport.expectEqual(blocked.current, 1)
        TestSupport.expectEqual(blocked.observe(target: 2, now: 6, isBlocked: false), 2)

        // An unknown target (no screens) changes nothing.
        var unknown = RioScreenFollowDebounce(current: 1)
        TestSupport.expectEqual(unknown.observe(target: nil, now: 0, isBlocked: false), nil)
        TestSupport.expectEqual(unknown.observe(target: nil, now: 9, isBlocked: false), nil)

        // First placement (no current screen) is immediate: nothing to poof away from.
        var fresh = RioScreenFollowDebounce(current: nil)
        TestSupport.expectEqual(fresh.observe(target: 2, now: 0, isBlocked: false), 2)
    }

    private static func testDockAndTimings() {
        TestSupport.expectEqual(RioScreenChoice.dockScreenID(screens: screens), 1)
        TestSupport.expectEqual(RioScreenChoice.dockScreenID(screens: []), nil)
        TestSupport.expect(RioScreenChoice.canRunDockRun(bearScreen: 1, screens: screens), "Bear on the Dock screen may run")
        TestSupport.expect(!RioScreenChoice.canRunDockRun(bearScreen: 2, screens: screens), "Bear on another screen never runs")
        TestSupport.expect(RioScreenChoice.canRunDockRun(bearScreen: nil, screens: screens), "Unplaced bear sits on the primary screen")
        TestSupport.expect(RioScreenFollowDebounce.holdTime == 1.5, "Debounce is 1.5 s")
        TestSupport.expect(RioScreenFollow.poofDuration <= 0.25, "The poof is at most 0.25 s")
        TestSupport.expect(RioScreenFollow.pollInterval >= 1, "Polling is at most 1 Hz")
    }
}
