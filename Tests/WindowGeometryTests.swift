import CoreGraphics
import Foundation

/// Pure window-placement math on synthetic displays. All screen frames here use AppKit
/// coordinates (origin bottom-left of the main display, y up).
enum WindowGeometryTests {
    /// Main display: 1440x900, menu bar 25 pt on top, Dock 70 pt at the bottom.
    private static let main = ScreenInfo(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 805)
    )
    /// Secondary display directly above the main one.
    private static let above = ScreenInfo(
        frame: CGRect(x: 0, y: 900, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 0, y: 900, width: 1920, height: 1080)
    )
    /// Secondary display to the left of the main one (taller, bottoms aligned).
    private static let left = ScreenInfo(
        frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    )

    static func run() {
        testAXConversion()
        testHalves()
        testMaximizeAndCenter()
        testHalvesOnSecondaryAbove()
        testHalvesOnSecondaryLeft()
        testScreenSelection()
        testScreenOrder()
        testNextScreen()
        testMinimizeHasNoFrame()
        testSummaries()
        testAppNameResolver()
    }

    private static func testAXConversion() {
        // AX origin is the top-left of the main display, y down.
        let appKit = CGRect(x: 100, y: 100, width: 800, height: 600)
        let ax = WindowGeometry.axRect(fromAppKit: appKit, primaryScreenHeight: 900)
        TestSupport.expectEqual(ax, CGRect(x: 100, y: 200, width: 800, height: 600))
        TestSupport.expectEqual(WindowGeometry.appKitRect(fromAX: ax, primaryScreenHeight: 900), appKit)

        // A window on the display above the main one has a negative AX y.
        let onAbove = CGRect(x: 0, y: 1000, width: 800, height: 600)
        let axAbove = WindowGeometry.axRect(fromAppKit: onAbove, primaryScreenHeight: 900)
        TestSupport.expectEqual(axAbove, CGRect(x: 0, y: -700, width: 800, height: 600))
        TestSupport.expectEqual(WindowGeometry.appKitRect(fromAX: axAbove, primaryScreenHeight: 900), onAbove)

        // A window on the left display keeps its negative x in both systems.
        let onLeft = CGRect(x: -1500, y: 50, width: 400, height: 300)
        let axLeft = WindowGeometry.axRect(fromAppKit: onLeft, primaryScreenHeight: 900)
        TestSupport.expectEqual(axLeft, CGRect(x: -1500, y: 550, width: 400, height: 300))
    }

    private static func target(
        _ placement: WindowPlacement, window: CGRect, screens: [ScreenInfo]
    ) -> CGRect? {
        WindowGeometry.targetFrame(for: placement, window: window, screens: screens)
    }

    private static func testHalves() {
        let win = CGRect(x: 300, y: 200, width: 600, height: 400)
        let screens = [main]
        TestSupport.expectEqual(
            target(.leftHalf, window: win, screens: screens),
            CGRect(x: 0, y: 70, width: 720, height: 805)
        )
        TestSupport.expectEqual(
            target(.rightHalf, window: win, screens: screens),
            CGRect(x: 720, y: 70, width: 720, height: 805)
        )
        // Odd visible height: halves must tile with no gap or overlap.
        let top = target(.topHalf, window: win, screens: screens)
        let bottom = target(.bottomHalf, window: win, screens: screens)
        TestSupport.expectEqual(top, CGRect(x: 0, y: 472, width: 1440, height: 403))
        TestSupport.expectEqual(bottom, CGRect(x: 0, y: 70, width: 1440, height: 402))
        TestSupport.expectEqual(bottom?.maxY, top?.minY)
        TestSupport.expectEqual(top?.maxY, main.visibleFrame.maxY)
    }

    private static func testMaximizeAndCenter() {
        let win = CGRect(x: 300, y: 200, width: 600, height: 400)
        TestSupport.expectEqual(
            target(.maximize, window: win, screens: [main]),
            main.visibleFrame
        )
        TestSupport.expectEqual(
            target(.center, window: win, screens: [main]),
            CGRect(x: 420, y: 272, width: 600, height: 400)
        )
        // A window larger than the screen is clamped to the visible area.
        let huge = CGRect(x: 0, y: 0, width: 2000, height: 1000)
        TestSupport.expectEqual(
            target(.center, window: huge, screens: [main]),
            main.visibleFrame
        )
    }

    private static func testHalvesOnSecondaryAbove() {
        // Window sits on the display above; frames come from that display, not the main one.
        let win = CGRect(x: 400, y: 1200, width: 600, height: 400)
        let screens = [main, above]
        TestSupport.expectEqual(
            target(.leftHalf, window: win, screens: screens),
            CGRect(x: 0, y: 900, width: 960, height: 1080)
        )
        TestSupport.expectEqual(
            target(.rightHalf, window: win, screens: screens),
            CGRect(x: 960, y: 900, width: 960, height: 1080)
        )
        TestSupport.expectEqual(
            target(.maximize, window: win, screens: screens),
            above.visibleFrame
        )
    }

    private static func testHalvesOnSecondaryLeft() {
        let win = CGRect(x: -1500, y: 100, width: 600, height: 400)
        let screens = [main, left]
        TestSupport.expectEqual(
            target(.rightHalf, window: win, screens: screens),
            CGRect(x: -960, y: 0, width: 960, height: 1080)
        )
        TestSupport.expectEqual(
            target(.topHalf, window: win, screens: screens),
            CGRect(x: -1920, y: 540, width: 1920, height: 540)
        )
    }

    private static func testScreenSelection() {
        let screens = [main, above, left]
        TestSupport.expectEqual(
            WindowGeometry.screenIndex(containing: CGRect(x: 100, y: 100, width: 300, height: 300), in: screens),
            0
        )
        TestSupport.expectEqual(
            WindowGeometry.screenIndex(containing: CGRect(x: 100, y: 1100, width: 300, height: 300), in: screens),
            1
        )
        // Straddling main and above: 100 pt of height on main, 200 pt on above.
        TestSupport.expectEqual(
            WindowGeometry.screenIndex(containing: CGRect(x: 100, y: 800, width: 300, height: 300), in: screens),
            1
        )
        // Fully off every display: the nearest one wins.
        TestSupport.expectEqual(
            WindowGeometry.screenIndex(containing: CGRect(x: 1700, y: 100, width: 300, height: 300), in: screens),
            0
        )
        TestSupport.expectEqual(
            WindowGeometry.screenIndex(containing: CGRect(x: 0, y: 0, width: 10, height: 10), in: []),
            nil
        )
    }

    private static func testScreenOrder() {
        // Left to right, ties broken bottom to top.
        TestSupport.expectEqual(WindowGeometry.orderedScreenIndices([main, above, left]), [2, 0, 1])
        TestSupport.expectEqual(WindowGeometry.orderedScreenIndices([main]), [0])
        TestSupport.expectEqual(WindowGeometry.orderedScreenIndices([]), [])
    }

    private static func testNextScreen() {
        // Right half of main keeps its relative frame on the display above.
        let win = CGRect(x: 720, y: 70, width: 720, height: 805)
        TestSupport.expectEqual(
            target(.nextScreen, window: win, screens: [main, above]),
            CGRect(x: 960, y: 900, width: 960, height: 1080)
        )
        // Wraps from the last display back to the first.
        let onAbove = CGRect(x: 960, y: 900, width: 960, height: 1080)
        TestSupport.expectEqual(
            target(.nextScreen, window: onAbove, screens: [main, above]),
            win
        )
        // Three displays cycle left -> main -> above -> left.
        let onMain = CGRect(x: 0, y: 70, width: 720, height: 805)
        TestSupport.expectEqual(
            WindowGeometry.nextScreenIndex(after: 2, in: [main, above, left]), 0
        )
        TestSupport.expectEqual(
            WindowGeometry.nextScreenIndex(after: 0, in: [main, above, left]), 1
        )
        TestSupport.expectEqual(
            WindowGeometry.nextScreenIndex(after: 1, in: [main, above, left]), 2
        )
        _ = onMain
        // One display: nothing to move to.
        TestSupport.expectEqual(target(.nextScreen, window: win, screens: [main]), nil)
        // A fixed-size window keeps its size and is clamped into the next display.
        let small = CGRect(x: 1300, y: 70, width: 140, height: 100)
        let moved = target(.nextScreen, window: small, screens: [main, above])
        TestSupport.expect(moved != nil, "nextScreen gives a frame")
        if let moved {
            TestSupport.expect(above.visibleFrame.contains(moved), "result stays inside the display")
        }
    }

    private static func testMinimizeHasNoFrame() {
        TestSupport.expectEqual(
            target(.minimize, window: CGRect(x: 0, y: 0, width: 100, height: 100), screens: [main]),
            nil
        )
    }

    private static func testSummaries() {
        TestSupport.expectEqual(
            WindowGeometry.summary(for: .leftHalf, appName: "Google Chrome"),
            "Moved Google Chrome to the left"
        )
        TestSupport.expectEqual(
            WindowGeometry.summary(for: .rightHalf, appName: "Warp"), "Moved Warp to the right"
        )
        TestSupport.expectEqual(
            WindowGeometry.summary(for: .topHalf, appName: "Warp"), "Moved Warp to the top"
        )
        TestSupport.expectEqual(
            WindowGeometry.summary(for: .bottomHalf, appName: "Warp"), "Moved Warp to the bottom"
        )
        TestSupport.expectEqual(
            WindowGeometry.summary(for: .maximize, appName: "Safari"), "Maximized Safari"
        )
        TestSupport.expectEqual(
            WindowGeometry.summary(for: .center, appName: "Safari"), "Centered Safari"
        )
        TestSupport.expectEqual(
            WindowGeometry.summary(for: .minimize, appName: "Safari"), "Minimized Safari"
        )
        TestSupport.expectEqual(
            WindowGeometry.summary(for: .nextScreen, appName: "Safari"),
            "Moved Safari to the other screen"
        )
    }

    private static func testAppNameResolver() {
        let names = ["Google Chrome", "Safari", "Visual Studio Code", "Warp", "Messages", "Mail", "Maps"]
        func idx(_ spoken: String) -> Int? { WindowAppNameResolver.bestMatchIndex(for: spoken, in: names) }
        TestSupport.expectEqual(idx("Google Chrome"), 0)
        TestSupport.expectEqual(idx("chrome"), 0)
        TestSupport.expectEqual(idx("Chrome."), 0)
        TestSupport.expectEqual(idx("the safari"), 1)
        TestSupport.expectEqual(idx("vscode"), 2)
        TestSupport.expectEqual(idx("VS Code"), 2)
        TestSupport.expectEqual(idx("code"), 2)
        TestSupport.expectEqual(idx("warp"), 3)
        TestSupport.expectEqual(idx("mail"), 5)
        TestSupport.expectEqual(idx("maps"), 6)
        TestSupport.expectEqual(idx("mes"), nil)
        TestSupport.expectEqual(idx("Photoshop"), nil)
        TestSupport.expectEqual(idx(""), nil)
        TestSupport.expectEqual(idx("   "), nil)
        // Alias only resolves when the real app is running.
        TestSupport.expectEqual(
            WindowAppNameResolver.bestMatchIndex(for: "chrome", in: ["Chromium", "Safari"]), nil
        )
        // Deterministic: the shortest name wins an ambiguous token match.
        TestSupport.expectEqual(
            WindowAppNameResolver.bestMatchIndex(for: "studio", in: ["Android Studio Preview", "Pro Studio"]), 1
        )
    }
}
