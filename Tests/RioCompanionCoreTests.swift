import CoreGraphics
import Foundation

/// The corner bear's pure cores: state machine and timeouts, Dock-run timing, Dock item
/// matching and corner layout. Synthetic data only; no AppKit, no Accessibility, no clock.
enum RioCompanionCoreTests {
    static func run() {
        testDockClickHitTest()
        testStyleDefaultsToCorner()
        testStartsAsleepAndSleepsAgainAfterIdle()
        testDictationWakesThenTalks()
        testActionKeyIsAlertInstantlyWithNoWake()
        testActionPhasesMapToPoses()
        testMomentReplacesRestAndLapses()
        testNewRecordingClearsMoment()
        testTrickHidesTheBearAndComesBackAwake()
        testRunSequenceOrderAndReturn()
        testRunRefusedWhenBusy()
        testRunStartsInstantlyFromSleep()
        testSprintNeverExceedsMaxRunDuration()
        testSprintScalesSpeedWithDistance()
        testSprintPositionAndImpact()
        testDockMatchByURL()
        testDockMatchByTitleAndNoFuzzy()
        testDockMatchSkipsNonAppItems()
        testDockPreferences()
        testDockRunTargetGeometry()
        testSnapshotFreshness()
        testCornerLayout()
        testDayMoods()
        testGrumpyDetector()
        testFidgetSchedule()
        testTimerText()
        testCounterWatcher()
        testSpeakingAndHelpAndCelebrate()
        testTimerAndRinging()
        testGrumpyWake()
    }

    private typealias Machine = RioCompanionMachine

    private static func testStyleDefaultsToCorner() {
        TestSupport.expectEqual(RioStyle.resolve(rawValue: nil), .corner)
        TestSupport.expectEqual(RioStyle.resolve(rawValue: "pill"), .pill)
        TestSupport.expectEqual(RioStyle.resolve(rawValue: "corner"), .corner)
        TestSupport.expectEqual(RioStyle.resolve(rawValue: "garbage"), .corner)
    }

    private static func testStartsAsleepAndSleepsAgainAfterIdle() {
        var machine = Machine()
        TestSupport.expectEqual(machine.mode(at: 0), .asleep)
        machine.voiceChanged(.recording, at: 10)
        machine.voiceChanged(.none, at: 12)
        TestSupport.expectEqual(machine.mode(at: 12.5), .resting)
        TestSupport.expectEqual(machine.mode(at: 12 + Machine.idleTimeout - 0.01), .resting)
        TestSupport.expectEqual(machine.mode(at: 12 + Machine.idleTimeout + 0.01), .asleep)
        TestSupport.expectApproximatelyEqual(Machine.idleTimeout, 20)
    }

    private static func testDictationWakesThenTalks() {
        var machine = Machine()
        machine.voiceChanged(.starting, at: 5)
        TestSupport.expectEqual(machine.mode(at: 5.01), .waking)
        TestSupport.expectEqual(machine.mode(at: 5 + Machine.wakeDuration + 0.01), .talking)
        TestSupport.expectApproximatelyEqual(Machine.wakeDuration, 0.3)
        machine.voiceChanged(.transcribing, at: 8)
        TestSupport.expectEqual(machine.mode(at: 8.1), .thinking)
        // Already awake: no second wake-up stretch.
        machine.voiceChanged(.recording, at: 9)
        TestSupport.expectEqual(machine.mode(at: 9.01), .talking)
    }

    private static func testActionKeyIsAlertInstantlyWithNoWake() {
        var machine = Machine()
        machine.actionPhaseChanged(.listening, at: 3)
        TestSupport.expectEqual(machine.mode(at: 3), .alert)
        // The recording pipeline starts a beat later; alert still wins over talking.
        machine.voiceChanged(.recording, at: 3.05)
        TestSupport.expectEqual(machine.mode(at: 3.1), .alert)
    }

    private static func testActionPhasesMapToPoses() {
        var machine = Machine()
        machine.actionPhaseChanged(.working("Opening Google Chrome"), at: 1)
        TestSupport.expectEqual(machine.mode(at: 1.1), .thinking)
        TestSupport.expectEqual(machine.bubbleText(at: 1.1), "Opening Google Chrome")
        machine.actionPhaseChanged(.succeeded("Opened Google Chrome"), at: 2)
        TestSupport.expectEqual(machine.mode(at: 2.1), .happy)
        TestSupport.expectEqual(machine.bubbleText(at: 2.1), "Opened Google Chrome")
        machine.actionPhaseChanged(.failed("I couldn't find Crome"), at: 3)
        TestSupport.expectEqual(machine.mode(at: 3.1), .shrug)
        TestSupport.expectEqual(machine.bubbleText(at: 3.1), "I couldn't find Crome")
        machine.actionPhaseChanged(.idle, at: 5.5)
        TestSupport.expectEqual(machine.mode(at: 5.6), .resting)
        TestSupport.expectEqual(machine.bubbleText(at: 5.6), nil)
        TestSupport.expectEqual(machine.mode(at: 5.5 + Machine.idleTimeout + 1), .asleep)
    }

    private static func testMomentReplacesRestAndLapses() {
        var machine = Machine()
        machine.voiceChanged(.recording, at: 0)
        machine.voiceChanged(.none, at: 1)
        machine.showMoment(.didntCatchThat, at: 1)
        TestSupport.expectEqual(machine.mode(at: 1.5), .moment)
        TestSupport.expectEqual(machine.activeMoment(at: 1.5), .didntCatchThat)
        TestSupport.expectEqual(machine.mode(at: 1 + TeddyMoment.didntCatchThat.seconds + 0.01), .resting)
        TestSupport.expectEqual(machine.activeMoment(at: 10), nil)
        // Rest time counts from when the moment ends.
        let end = 1 + TeddyMoment.didntCatchThat.seconds
        TestSupport.expectEqual(machine.mode(at: end + Machine.idleTimeout - 0.1), .resting)
        TestSupport.expectEqual(machine.mode(at: end + Machine.idleTimeout + 0.1), .asleep)
    }

    private static func testNewRecordingClearsMoment() {
        var machine = Machine()
        machine.showMoment(.milestone("1,000 words"), at: 0)
        machine.voiceChanged(.starting, at: 0.5)
        TestSupport.expectEqual(machine.activeMoment(at: 0.6), nil)
        TestSupport.expect(machine.mode(at: 0.6) != .moment, "A new recording replaces the moment at once")
    }

    private static func testTrickHidesTheBearAndComesBackAwake() {
        var machine = Machine()
        machine.voiceChanged(.recording, at: 0)
        machine.voiceChanged(.none, at: 1.5)
        machine.trickChanged(isAway: true, at: 2)
        TestSupport.expectEqual(machine.mode(at: 3), .away)
        TestSupport.expect(!machine.canRun(at: 3), "No Dock run mid-trick")
        machine.trickChanged(isAway: false, at: 6)
        TestSupport.expectEqual(machine.mode(at: 6.1), .resting)
        TestSupport.expectEqual(machine.mode(at: 6 + Machine.idleTimeout + 0.5), .asleep)
    }

    private static func testRunSequenceOrderAndReturn() {
        var machine = Machine()
        machine.actionPhaseChanged(.listening, at: 0)
        let plan = RioDockRunPlan.make(distance: 800)
        TestSupport.expect(machine.startRun(plan, at: 1), "Run starts when the bear is free")
        TestSupport.expectEqual(machine.mode(at: 1 + plan.sprintDuration * 0.5), .sprint)
        TestSupport.expectEqual(machine.mode(at: 1 + plan.sprintDuration + 0.01), .punch)
        TestSupport.expectEqual(machine.mode(at: 1 + plan.totalDuration + 0.01), .returning)
        let back = 1 + plan.totalDuration + RioDockRunPlan.returnDuration
        machine.actionPhaseChanged(.idle, at: 1.2)
        TestSupport.expect(machine.mode(at: back + 0.01) != .returning, "Return jog ends")
        TestSupport.expectEqual(machine.mode(at: back + Machine.idleTimeout + 0.5), .asleep)
    }

    private static func testRunRefusedWhenBusy() {
        var machine = Machine()
        let plan = RioDockRunPlan.make(distance: 500)
        TestSupport.expect(machine.startRun(plan, at: 0), "Expectation failed")
        TestSupport.expect(!machine.canRun(at: 0.05), "A run is already going")
        TestSupport.expect(!machine.startRun(plan, at: 0.05), "Second run refused")
        // A new run is fine once the first, and its jog home, are over.
        let later = plan.totalDuration + RioDockRunPlan.returnDuration + 0.1
        TestSupport.expect(machine.canRun(at: later), "Expectation failed")
    }

    private static func testRunStartsInstantlyFromSleep() {
        var machine = Machine()
        TestSupport.expectEqual(machine.mode(at: 0), .asleep)
        TestSupport.expect(machine.startRun(RioDockRunPlan.make(distance: 400), at: 0), "Expectation failed")
        TestSupport.expectEqual(machine.mode(at: 0), .sprint)
    }

    private static func testSprintNeverExceedsMaxRunDuration() {
        let distances: [CGFloat] = [-500, 0, 1, 40, 120, 500, 900, 1500, 3000, 6000, 20_000, 1_000_000,
                                    .infinity, -.infinity, .nan]
        for distance in distances {
            let plan = RioDockRunPlan.make(distance: distance)
            TestSupport.expect(plan.totalDuration <= RioCompanionTiming.maxRunDuration,
                               "Run for distance \(distance) took \(plan.totalDuration) s")
            TestSupport.expect(plan.impactTime <= plan.totalDuration, "Impact is inside the run")
            TestSupport.expect(plan.impactTime > plan.sprintDuration, "Impact comes after the sprint")
            TestSupport.expect(plan.sprintDuration > 0 && plan.punchDuration > 0, "Both phases take time")
            TestSupport.expect(plan.sprintDuration + plan.punchDuration == plan.totalDuration, "Phases add up")
        }
    }

    private static func testSprintScalesSpeedWithDistance() {
        let short = RioDockRunPlan.make(distance: 200)
        let long = RioDockRunPlan.make(distance: 2000)
        TestSupport.expect(long.sprintDuration > short.sprintDuration, "Longer run takes longer")
        TestSupport.expect(long.distance / CGFloat(long.sprintDuration) > short.distance / CGFloat(short.sprintDuration),
                           "Long runs are faster, not slower")
        TestSupport.expect(RioDockRunPlan.make(distance: 100_000).totalDuration <= 0.4, "Expectation failed")
    }

    private static func testSprintPositionAndImpact() {
        let plan = RioDockRunPlan.make(distance: 600)
        TestSupport.expectApproximatelyEqual(Double(plan.runFraction(at: 0)), 0)
        TestSupport.expectApproximatelyEqual(Double(plan.runFraction(at: plan.totalDuration)), 1)
        var previous: CGFloat = -1
        for step in 0...20 {
            let t = plan.totalDuration * Double(step) / 20
            let f = plan.runFraction(at: t)
            TestSupport.expect(f >= previous - 0.000_001, "The bear never moves backwards")
            TestSupport.expect(f >= 0 && f <= 1, "Fraction stays on the track")
            previous = f
        }
        TestSupport.expect(plan.hasImpacted(at: plan.impactTime + 0.001), "Expectation failed")
        TestSupport.expect(!plan.hasImpacted(at: plan.impactTime - 0.001), "Expectation failed")
        TestSupport.expect(plan.leapHeight(at: 0) == 0, "On the ground while sprinting")
        TestSupport.expect(plan.leapHeight(at: plan.impactTime) > 0, "Airborne at the punch")
    }

    private static func item(
        _ title: String, url: String?, subrole: String? = "AXApplicationDockItem", x: CGFloat = 100
    ) -> DockItemSnapshot {
        DockItemSnapshot(title: title, urlString: url, subrole: subrole, frame: CGRect(x: x, y: 900, width: 56, height: 56))
    }

    private static func testDockMatchByURL() {
        let items = [
            item("Safari", url: "file:///Applications/Safari.app/", x: 100),
            item("Google Chrome", url: "file:///Applications/Google%20Chrome.app/", x: 200),
            item("Chrome Beta", url: "file:///Applications/Chrome%20Beta.app/", x: 300),
        ]
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        TestSupport.expectEqual(DockItemMatcher.match(items, appURL: chrome)?.frame.minX, 200)
        // URL beats a title that points to another bundle.
        let tricky = [
            item("Google Chrome", url: "file:///Users/test/Downloads/Google%20Chrome.app/", x: 50),
            item("Chrome", url: "file:///Applications/Google%20Chrome.app", x: 400),
        ]
        TestSupport.expectEqual(DockItemMatcher.match(tricky, appURL: chrome)?.frame.minX, 400)
    }

    private static func testDockMatchByTitleAndNoFuzzy() {
        let items = [item("Maps", url: nil), item("Spotify", url: nil, x: 220)]
        let spotify = URL(fileURLWithPath: "/Applications/Spotify.app")
        TestSupport.expectEqual(DockItemMatcher.match(items, appURL: spotify)?.frame.minX, 220)
        let mail = URL(fileURLWithPath: "/System/Applications/Mail.app")
        TestSupport.expect(DockItemMatcher.match(items, appURL: mail) == nil, "Never Maps for Mail")
        let upper = [item("SPOTIFY", url: nil, x: 77)]
        TestSupport.expectEqual(DockItemMatcher.match(upper, appURL: spotify)?.frame.minX, 77)
        TestSupport.expect(DockItemMatcher.match([], appURL: spotify) == nil, "Expectation failed")
    }

    private static func testDockMatchSkipsNonAppItems() {
        let items = [
            item("Downloads", url: "file:///Users/test/Downloads/", subrole: "AXFolderDockItem", x: 600),
            item("Trash", url: nil, subrole: "AXTrashDockItem", x: 700),
            item("Applications", url: "file:///Applications.app/", subrole: "AXFolderDockItem", x: 650),
        ]
        let fake = URL(fileURLWithPath: "/Applications.app")
        TestSupport.expect(DockItemMatcher.match(items, appURL: fake) == nil, "Folders are never an app")
        let trash = URL(fileURLWithPath: "/Applications/Trash.app")
        TestSupport.expect(DockItemMatcher.match(items, appURL: trash) == nil, "Trash is never an app")
    }

    private static func testDockPreferences() {
        TestSupport.expect(DockPreferences(orientation: nil, autohide: false).allowsRun, "Default Dock is bottom")
        TestSupport.expect(DockPreferences(orientation: "bottom", autohide: false).allowsRun, "Dock orientation")
        TestSupport.expect(!DockPreferences(orientation: "left", autohide: false).allowsRun, "Dock orientation")
        TestSupport.expect(!DockPreferences(orientation: "right", autohide: false).allowsRun, "Dock orientation")
        TestSupport.expect(!DockPreferences(orientation: "bottom", autohide: true).allowsRun, "Auto-hidden Dock")
        TestSupport.expect(!DockPreferences(orientation: "weird", autohide: false).allowsRun, "Dock orientation")
    }

    private static func testDockRunTargetGeometry() {
        // Primary display 1512 x 982; Accessibility y grows downward from the top.
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let icon = CGRect(x: 700, y: 912, width: 56, height: 56)
        let target = DockRunGeometry.target(iconFrameAX: icon, primaryScreen: screen)
        TestSupport.expect(target != nil, "Icon on the primary display")
        TestSupport.expectApproximatelyEqual(Double(target?.centerX ?? 0), 728)
        TestSupport.expectApproximatelyEqual(Double(target?.iconRect.minY ?? -1), 982 - 968)
        TestSupport.expectApproximatelyEqual(Double(target?.iconRect.height ?? 0), 56)
        // Off the primary display: no run.
        TestSupport.expect(DockRunGeometry.target(iconFrameAX: CGRect(x: 1700, y: 912, width: 56, height: 56), primaryScreen: screen) == nil, "Expectation failed")
        // A Dock that is not near the bottom (left side) never qualifies.
        TestSupport.expect(DockRunGeometry.target(iconFrameAX: CGRect(x: 10, y: 300, width: 56, height: 56), primaryScreen: screen) == nil, "Expectation failed")
        // Empty frames are rejected.
        TestSupport.expect(DockRunGeometry.target(iconFrameAX: .zero, primaryScreen: screen) == nil, "Expectation failed")
    }

    private static func testSnapshotFreshness() {
        let snapshot = DockSnapshot(items: [], takenAt: 100)
        TestSupport.expect(snapshot.isFresh(at: 100 + DockSnapshot.timeToLive - 1), "Expectation failed")
        TestSupport.expect(!snapshot.isFresh(at: 100 + DockSnapshot.timeToLive + 1), "Expectation failed")
        TestSupport.expect(!snapshot.isFresh(at: 99), "A snapshot from the future is not trusted")
    }

    private static func testCornerLayout() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        // Dock at the bottom: the visible frame starts at the screen's left edge.
        let bottomDock = CGRect(x: 0, y: 70, width: 1512, height: 880)
        let a = RioCompanionLayout.anchor(screenFrame: frame, visibleFrame: bottomDock)
        TestSupport.expectApproximatelyEqual(Double(a.x), Double(RioCompanionLayout.edgeInset))
        TestSupport.expectApproximatelyEqual(Double(a.y), Double(RioCompanionLayout.groundInset))
        // Dock on the left: stay clear of it.
        let leftDock = CGRect(x: 80, y: 0, width: 1432, height: 950)
        let b = RioCompanionLayout.anchor(screenFrame: frame, visibleFrame: leftDock)
        TestSupport.expectApproximatelyEqual(Double(b.x), 80 + Double(RioCompanionLayout.edgeInset))
        // Offset screens keep their own origin.
        let other = CGRect(x: -1920, y: 100, width: 1920, height: 1080)
        let c = RioCompanionLayout.anchor(screenFrame: other, visibleFrame: other)
        TestSupport.expectApproximatelyEqual(Double(c.x), -1920 + Double(RioCompanionLayout.edgeInset))
        TestSupport.expectApproximatelyEqual(Double(c.y), 100 + Double(RioCompanionLayout.groundInset))
    }

    private static func testDayMoods() {
        for hour in [23, 0, 1, 4] { TestSupport.expectEqual(RioDayMood.mood(hour: hour), .lateNight) }
        for hour in [5, 10, 12, 18, 22] { TestSupport.expectEqual(RioDayMood.mood(hour: hour), .day) }
        for hour in [6, 7, 9] { TestSupport.expectEqual(RioDayMood.mood(hour: hour), .morning) }
        TestSupport.expectEqual(RioDayMood.mood(hour: 99), .day)
        TestSupport.expectEqual(RioDayMood.mood(hour: -3), .day)
        TestSupport.expect(RioDayMood.holdsCoffee(mood: .morning, restingElapsed: 3), "Mug right after waking")
        TestSupport.expect(!RioDayMood.holdsCoffee(mood: .morning, restingElapsed: RioDayMood.coffeeSeconds + 1), "Mug is put down")
        TestSupport.expect(!RioDayMood.holdsCoffee(mood: .day, restingElapsed: 1), "No coffee at noon")
        TestSupport.expect(RioDayMood.wearsNightcap(mood: .lateNight), "Nightcap at night")
        TestSupport.expect(!RioDayMood.wearsNightcap(mood: .morning), "No nightcap in the morning")
    }

    private static func testGrumpyDetector() {
        var detector = RioGrumpyDetector()
        TestSupport.expect(!detector.recordWake(at: 0), "First wake")
        TestSupport.expect(!detector.recordWake(at: 10), "Second wake")
        TestSupport.expect(detector.recordWake(at: 20), "Third wake inside 30 s is grumpy")
        var slow = RioGrumpyDetector()
        _ = slow.recordWake(at: 0)
        _ = slow.recordWake(at: 20)
        TestSupport.expect(!slow.recordWake(at: 40), "Spread out: not grumpy")
        var burst = RioGrumpyDetector()
        _ = burst.recordWake(at: 100)
        _ = burst.recordWake(at: 101)
        TestSupport.expect(burst.recordWake(at: 102), "Quick burst")
        TestSupport.expect(!burst.recordWake(at: 140), "Old wakes expire")
    }

    private static func testFidgetSchedule() {
        TestSupport.expect(RioFidget.at(restingElapsed: 0) == nil, "No fidget right away")
        TestSupport.expect(RioFidget.at(restingElapsed: RioFidget.period - 0.1) == nil, "Quiet before the next one")
        let first = RioFidget.at(restingElapsed: RioFidget.startOffset + 0.5)
        TestSupport.expect(first != nil, "Fidget plays inside its window")
        TestSupport.expect((first?.progress ?? -1) > 0 && (first?.progress ?? 2) < 1, "Progress is 0...1")
        var kinds = Set<RioFidget.Kind>()
        for cycle in 0..<3 {
            if let f = RioFidget.at(restingElapsed: Double(cycle) * RioFidget.period + RioFidget.startOffset + 0.2) { kinds.insert(f.kind) }
        }
        TestSupport.expectEqual(kinds.count, 3)
        TestSupport.expect(RioFidget.at(restingElapsed: -5) == nil, "Negative time")
    }

    private static func testTimerText() {
        TestSupport.expectEqual(RioTimerText.format(0), "0:00")
        TestSupport.expectEqual(RioTimerText.format(-4), "0:00")
        TestSupport.expectEqual(RioTimerText.format(59.2), "1:00")
        TestSupport.expectEqual(RioTimerText.format(65), "1:05")
        TestSupport.expectEqual(RioTimerText.format(600), "10:00")
        TestSupport.expectEqual(RioTimerText.format(1_000_000), "99:59")
        TestSupport.expectEqual(RioTimerText.format(.nan), "0:00")
    }

    private static func testCounterWatcher() {
        var watcher = RioCounterWatcher()
        TestSupport.expect(!watcher.didIncrement(5), "First reading is the baseline")
        TestSupport.expect(!watcher.didIncrement(5), "Unchanged")
        TestSupport.expect(watcher.didIncrement(6), "Incremented")
        TestSupport.expect(!watcher.didIncrement(6), "Seen once only")
        TestSupport.expect(!watcher.didIncrement(0), "A reset is not a celebration")
    }

    private static func testSpeakingAndHelpAndCelebrate() {
        var machine = Machine()
        machine.speakingChanged(true, at: 1)
        TestSupport.expectEqual(machine.mode(at: 1.5), .talking)
        machine.speakingChanged(false, at: 3)
        TestSupport.expectEqual(machine.mode(at: 3.1), .resting)
        machine.helpChanged(true, at: 4)
        TestSupport.expectEqual(machine.mode(at: 4.1), .help)
        machine.helpChanged(false, at: 6)
        TestSupport.expect(machine.mode(at: 6.1) != .help, "Help card put away")
        machine.celebrate(at: 10)
        TestSupport.expectEqual(machine.mode(at: 10.5), .celebrate)
        TestSupport.expectEqual(machine.mode(at: 10 + Machine.celebrateDuration + 0.01), .resting)
        TestSupport.expect(machine.isLively(at: 10.5), "Celebration needs smooth frames")
    }

    private static func testTimerAndRinging() {
        var machine = Machine()
        machine.timerChanged(remaining: 125, ringing: false, at: 0)
        TestSupport.expectEqual(machine.timerText(), "2:05")
        TestSupport.expectEqual(machine.mode(at: 500), .resting)
        machine.timerChanged(remaining: 0, ringing: true, at: 600)
        TestSupport.expectEqual(machine.mode(at: 601), .ringing)
        machine.timerChanged(remaining: nil, ringing: false, at: 620)
        TestSupport.expect(machine.timerText() == nil, "No clock once the timer is gone")
        TestSupport.expectEqual(machine.mode(at: 620 + Machine.idleTimeout + 1), .asleep)
        // A run still wins over a ringing clock, so the 0.4 s rule holds.
        var busy = Machine()
        busy.timerChanged(remaining: 0, ringing: true, at: 0)
        TestSupport.expect(busy.startRun(RioDockRunPlan.make(distance: 500), at: 1), "Run starts while ringing")
        TestSupport.expectEqual(busy.mode(at: 1.05), .sprint)
    }

    private static func testGrumpyWake() {
        var machine = Machine()
        machine.voiceChanged(.starting, at: 0)
        machine.voiceChanged(.none, at: 1)
        machine.voiceChanged(.starting, at: 5)
        TestSupport.expect(!machine.isGrumpy(at: 5.1), "Twice is fine")
        machine.voiceChanged(.none, at: 6)
        machine.actionPhaseChanged(.listening, at: 10)
        TestSupport.expect(machine.isGrumpy(at: 10.5), "Third wake in 30 s: grumpy")
        TestSupport.expect(!machine.isGrumpy(at: 10 + Machine.grumpyDuration + 0.1), "Grumpiness passes")
    }

    /// The owner's own Dock clicks make the bear run (2026-11-03): which app icon is under the
    /// pointer, in AX (top-left origin) coordinates; never folders, the Trash or a drag.
    private static func testDockClickHitTest() {
        let chrome = DockItemSnapshot(title: "Google Chrome", urlString: "file:///Applications/Google%20Chrome.app/",
                                      subrole: "AXApplicationDockItem", frame: CGRect(x: 600, y: 900, width: 56, height: 56))
        let downloads = DockItemSnapshot(title: "Downloads", urlString: "file:///Users/x/Downloads/",
                                         subrole: "AXFolderDockItem", frame: CGRect(x: 700, y: 900, width: 56, height: 56))
        let trash = DockItemSnapshot(title: "Trash", urlString: nil, subrole: "AXTrashDockItem",
                                     frame: CGRect(x: 760, y: 900, width: 56, height: 56))
        let items = [chrome, downloads, trash]
        TestSupport.expectEqual(DockClickHitTest.appItem(atAX: CGPoint(x: 620, y: 930), items: items), chrome)
        TestSupport.expect(DockClickHitTest.appItem(atAX: CGPoint(x: 720, y: 930), items: items) == nil, "folders don't count")
        TestSupport.expect(DockClickHitTest.appItem(atAX: CGPoint(x: 780, y: 930), items: items) == nil, "the Trash doesn't count")
        TestSupport.expect(DockClickHitTest.appItem(atAX: CGPoint(x: 620, y: 500), items: items) == nil, "a click off the Dock")
        // A click is a press and release in nearly the same spot; a drag (rearranging icons) isn't.
        TestSupport.expect(DockClickHitTest.isClick(down: CGPoint(x: 620, y: 930), up: CGPoint(x: 623, y: 932)), "small jitter is a click")
        TestSupport.expect(!DockClickHitTest.isClick(down: CGPoint(x: 620, y: 930), up: CGPoint(x: 680, y: 930)), "a drag is not")
        // AppKit (bottom-left) to AX (top-left) on a 1000-pt-tall primary screen.
        TestSupport.expectEqual(DockClickHitTest.axPoint(fromAppKit: CGPoint(x: 620, y: 70), primaryHeight: 1000), CGPoint(x: 620, y: 930))
    }
}
