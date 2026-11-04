import Foundation

/// Fixer D regression tests: crash-loop marker, deferred unregister, redraw scheduling and
/// wakeup counts, Dock-run throttle, bear defaults snapshot, voice token and watchdog, clipboard
/// own-change pruning.
enum RioFixDTests {
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private static func tempMarker() -> (RioCrashMarker, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rio-fd-\(UUID().uuidString)")
        return (RioCrashMarker(url: dir.appendingPathComponent("rio-running")), dir)
    }

    private static func eq<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", line: UInt = #line) {
        TestSupport.expect(actual == expected, "\(message) expected \(expected), got \(actual)", line: line)
    }

    private static func approx(_ actual: Double, _ expected: Double, _ message: String, line: UInt = #line) {
        TestSupport.expect(abs(actual - expected) < 0.000_001, "\(message) expected \(expected), got \(actual)", line: line)
    }

    static func run() {
        testDeferredUnregister()
        testCrashLoopStopsAfterThree()
        testSlowCrashesNeverLoop()
        testManualLaunchNeverExitsAndShowsNoticeOnce()
        testCleanQuitForgetsHistory()
        testLegacyEmptyMarker()
        testMemoReturnsFirstAnswer()
        testSchedules()
        testWakeupBudget()
        testGate()
        testDockRunThrottle()
        testBearDefaultsSnapshot()
        testUtteranceTracker()
        testSpeechWatchdog()
        testOwnChangeCounts()
    }

    // MARK: Launch

    private static func testDeferredUnregister() {
        typealias Plan = RioLaunchMigration.Plan
        eq(
            RioLaunchMigration.plan(wantsEnabled: false, mainAppEnabled: false, agentEnabled: true, runningUnderAgent: true),
            Plan(unregisterMainApp: false, registerAgent: false, unregisterAgent: false, deferAgentUnregister: true)
        )
        eq(
            RioLaunchMigration.plan(wantsEnabled: false, mainAppEnabled: false, agentEnabled: true, runningUnderAgent: false),
            Plan(unregisterMainApp: false, registerAgent: false, unregisterAgent: true)
        )
        eq(
            RioLaunchMigration.plan(wantsEnabled: false, mainAppEnabled: false, agentEnabled: false, runningUnderAgent: true),
            Plan(unregisterMainApp: false, registerAgent: false, unregisterAgent: false)
        )
        eq(
            RioLaunchMigration.plan(wantsEnabled: true, mainAppEnabled: false, agentEnabled: false, runningUnderAgent: true),
            Plan(unregisterMainApp: false, registerAgent: true, unregisterAgent: false)
        )
    }

    /// Simulates `count` launchd restarts after crashes, `gap` seconds apart.
    private static func crashRestarts(_ marker: RioCrashMarker, count: Int, gap: TimeInterval) -> [RioLaunchStart] {
        var results: [RioLaunchStart] = []
        _ = marker.begin(now: t0, startedByLaunchd: true)   // first launch, never crashed yet
        for index in 1...count {
            results.append(marker.begin(now: t0.addingTimeInterval(gap * Double(index)), startedByLaunchd: true))
        }
        return results
    }

    private static func testCrashLoopStopsAfterThree() {
        let (marker, dir) = tempMarker()
        defer { try? FileManager.default.removeItem(at: dir) }
        let starts = crashRestarts(marker, count: 3, gap: 6)
        TestSupport.expect(starts[0].recoveredFromCrash && !starts[0].stopForCrashLoop, "First crash relaunches")
        TestSupport.expect(!starts[1].stopForCrashLoop, "Second crash still relaunches")
        TestSupport.expect(starts[2].stopForCrashLoop, "Third crash within two minutes gives up before the app is built")
        TestSupport.expect(marker.readState()?.running == false, "A given-up launch leaves no run marker")
        TestSupport.expect(marker.readState()?.stoppedForLoop == true, "The give-up is remembered for the next manual launch")
    }

    private static func testSlowCrashesNeverLoop() {
        let (marker, dir) = tempMarker()
        defer { try? FileManager.default.removeItem(at: dir) }
        let starts = crashRestarts(marker, count: 6, gap: 90)
        TestSupport.expect(starts.allSatisfy { !$0.stopForCrashLoop }, "Crashes 90 s apart are never a loop (3 within 120 s needed)")
        eq(marker.readState()?.crashes.count, 2, "Only crashes inside the window are kept")
    }

    private static func testManualLaunchNeverExitsAndShowsNoticeOnce() {
        let (marker, dir) = tempMarker()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = crashRestarts(marker, count: 3, gap: 6)
        let manual = marker.begin(now: t0.addingTimeInterval(500), startedByLaunchd: false)
        TestSupport.expect(!manual.stopForCrashLoop, "A manual launch never exits")
        TestSupport.expect(manual.showLoopNotice, "The next manual launch reports the give-up")
        TestSupport.expect(manual.recoveredFromCrash == false, "The give-up left no run marker, so it is not a crash recovery")
        marker.endRun()
        let again = marker.begin(now: t0.addingTimeInterval(900), startedByLaunchd: false)
        TestSupport.expect(!again.showLoopNotice, "The notice shows once")
        // Crashes during manual runs never trigger a give-up.
        for index in 0..<4 {
            let start = marker.begin(now: t0.addingTimeInterval(1000 + Double(index)), startedByLaunchd: false)
            TestSupport.expect(!start.stopForCrashLoop, "Manual copies are never stopped")
        }
    }

    private static func testCleanQuitForgetsHistory() {
        let (marker, dir) = tempMarker()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = marker.begin(now: t0, startedByLaunchd: true)
        _ = marker.begin(now: t0.addingTimeInterval(5), startedByLaunchd: true)   // one crash recorded
        marker.endRun()
        TestSupport.expect(marker.readState() == nil, "A clean quit removes the file and the history")
        let next = marker.begin(now: t0.addingTimeInterval(10), startedByLaunchd: true)
        TestSupport.expect(!next.recoveredFromCrash, "Normal start after a clean quit")
    }

    private static func testLegacyEmptyMarker() {
        let (marker, dir) = tempMarker()
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker.url.path, contents: Data())
        let start = marker.begin(now: t0, startedByLaunchd: true)
        TestSupport.expect(start.recoveredFromCrash, "An old empty marker still means the last run crashed")
    }

    private static func testMemoReturnsFirstAnswer() {
        let (plain, dir) = tempMarker()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = RioCrashMarker(url: plain.url, memo: RioCrashMarker.Memo())
        let first = marker.begin(now: t0, startedByLaunchd: false)
        let second = marker.begin(now: t0.addingTimeInterval(1), startedByLaunchd: false)
        eq(first, second, "A second begin in one process must not see its own marker as a crash")
        TestSupport.expect(!second.recoveredFromCrash, "Not a recovery")
    }

    // MARK: Redraw scheduling (M7)

    private typealias Mode = RioCompanionMachine.Mode
    private static let open = RioRedrawGate()

    private static func schedule(_ mode: Mode, timer: Bool = false, error: Bool = false, gate: RioRedrawGate = open) -> RioRedrawSchedule {
        RioRedrawPolicy.schedule(mode: mode, hasTimer: timer, hasErrorCard: error, gate: gate)
    }

    private static func testSchedules() {
        eq(schedule(.asleep), .periodic(0.5), "Asleep is a 2 Hz periodic tick")
        eq(schedule(.resting, timer: true), .periodic(1), "Resting with a timer running ticks once a second")
        eq(schedule(.resting), .animation(minimumInterval: 0.1), "Plain resting blinks at 10 fps")
        eq(schedule(.talking), .animation(minimumInterval: 1.0 / 30), "Acting is smooth")
        eq(schedule(.sprint), .animation(minimumInterval: 1.0 / 60), "A run is 60 fps")
        eq(schedule(.asleep, error: true), .animation(minimumInterval: 1.0 / 30), "An error card needs smooth frames")
        eq(schedule(.away), .periodic(0.5), "Away (trick) barely redraws")
        TestSupport.expect(RioRedrawPolicy.sleepyInterval >= 0.5, "Asleep never exceeds 2 redraws a second")
    }

    private static func testWakeupBudget() {
        func wakeups(_ mode: Mode, timer: Bool = false, pending: Bool = false) -> Double {
            RioRedrawPolicy.wakeupsPerSecond(schedule: schedule(mode, timer: timer), hasPendingExpiry: pending)
        }
        // Before the fix: asleep 4 redraws/s (0.25 s); a running timer 10 redraws/s plus a 5/s
        // housekeeping timer = 15 wakeups/s. After:
        approx(wakeups(.asleep), 2, "Asleep: 2 wakeups/s, no housekeeping timer")
        TestSupport.expect(wakeups(.resting, timer: true) <= 2, "A running timer costs at most 2 wakeups/s")
        TestSupport.expect(wakeups(.asleep) < 4, "Better than the old sleeping tier of 4 redraws/s")
        let paused = RioRedrawGate(displayAsleep: true)
        approx(
            RioRedrawPolicy.wakeupsPerSecond(schedule: schedule(.asleep, gate: paused), hasPendingExpiry: false), 0,
            "A sleeping display costs 0 wakeups/s"
        )
        TestSupport.expect(
            RioRedrawPolicy.housekeepingInterval(schedule: schedule(.asleep), hasPendingExpiry: false) == nil,
            "No housekeeping timer while asleep"
        )
        eq(
            RioRedrawPolicy.housekeepingInterval(schedule: schedule(.resting, timer: true), hasPendingExpiry: false), 1,
            "A timer countdown's housekeeping runs at 1 s, not 0.2 s"
        )
    }

    private static func testGate() {
        for gate in [RioRedrawGate(displayAsleep: true), RioRedrawGate(sessionActive: false), RioRedrawGate(panelVisible: false)] {
            TestSupport.expect(gate.isPaused, "Any of display asleep, session inactive or panel covered pauses drawing")
            for mode in [Mode.asleep, .resting, .talking, .sprint] {
                eq(schedule(mode, timer: true, error: true, gate: gate), .paused, "Paused beats every mode")
            }
        }
        TestSupport.expect(!RioRedrawGate().isPaused, "Visible and awake draws")
    }

    // MARK: Dock run throttle

    private static func testDockRunThrottle() {
        var throttle = RioDockRunThrottle()
        TestSupport.expect(throttle.allows(at: 100), "The first run is allowed")
        throttle.record(at: 100)
        TestSupport.expect(!throttle.allows(at: 100.3), "A second run inside 0.5 s is refused")
        TestSupport.expect(throttle.allows(at: 100.5), "0.5 s later is fine")
        TestSupport.expect(throttle.allows(at: 99), "A clock that went backwards never locks the bear out")
    }

    private static func testBearDefaultsSnapshot() {
        let suite = "rio-fd-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defer { defaults.removePersistentDomain(forName: suite) }
        func read() -> RioBearDefaults {
            RioBearDefaults.read(from: defaults, styleKey: "style", capturesKey: "captures", dockRunKey: "dock")
        }
        let before = read()
        defaults.set("something unrelated", forKey: "other_key")
        eq(read(), before, "An unrelated write does not change the bear's snapshot")
        defaults.set("pill", forKey: "style")
        TestSupport.expect(read() != before, "The style key does")
        defaults.set(true, forKey: "captures")
        defaults.set(false, forKey: "dock")
        TestSupport.expect(read().showInCaptures && !read().dockRunEnabled, "Captures and Dock-run keys are read")
        TestSupport.expect(before.dockRunEnabled, "Dock run defaults on")
    }

    // MARK: Voice

    private static func testUtteranceTracker() {
        var tracker = RioUtteranceTracker()
        let first = tracker.begin()
        TestSupport.expect(tracker.isCurrent(first), "A new utterance is current")
        let second = tracker.begin()
        TestSupport.expect(!tracker.isCurrent(first), "The old one stops counting")
        TestSupport.expect(!tracker.end(first), "A late callback for the old one is ignored")
        TestSupport.expect(tracker.isCurrent(second), "...and does not end the new one")
        TestSupport.expect(!tracker.isCurrent(nil), "A missing token never matches")
        TestSupport.expect(tracker.end(second), "The current one ends")
        TestSupport.expect(!tracker.end(second), "Only once")
        tracker.cancel()
        TestSupport.expect(tracker.current == nil, "Cancel clears")
    }

    private static func testSpeechWatchdog() {
        typealias W = RioSpeechWatchdog
        let max = W.maxDuration(characterCount: 40)
        TestSupport.expect(!W.shouldForceFinish(synthesizerIsSpeaking: true, secondsSinceWord: 0.3, secondsSinceStart: 2, maxDuration: max), "Speaking normally")
        TestSupport.expect(W.shouldForceFinish(synthesizerIsSpeaking: false, secondsSinceWord: 2, secondsSinceStart: 3, maxDuration: max), "Synthesizer idle and no didFinish: unstick")
        TestSupport.expect(!W.shouldForceFinish(synthesizerIsSpeaking: false, secondsSinceWord: 0.5, secondsSinceStart: 3, maxDuration: max), "A short gap is fine")
        TestSupport.expect(W.shouldForceFinish(synthesizerIsSpeaking: true, secondsSinceWord: 9, secondsSinceStart: 12, maxDuration: max), "A frozen synthesizer is cut off")
        TestSupport.expect(W.shouldForceFinish(synthesizerIsSpeaking: true, secondsSinceWord: 0.1, secondsSinceStart: max + 1, maxDuration: max), "Hard cap")
        TestSupport.expect(W.maxDuration(characterCount: 400) > W.maxDuration(characterCount: 40), "Longer text gets longer")
    }

    // MARK: Clipboard

    private static func testOwnChangeCounts() {
        var counts = RioOwnChangeCounts()
        counts.insert(10)
        counts.insert(12)
        TestSupport.expect(counts.consume(10), "Rio's own change is recognised")
        eq(counts.counts, [12], "Consuming drops it")
        TestSupport.expect(!counts.consume(11), "Someone else's copy is not ours")
        var stale = RioOwnChangeCounts()
        stale.insert(5)
        stale.insert(6)
        TestSupport.expect(!stale.consume(20), "A later count is not ours")
        TestSupport.expect(stale.counts.isEmpty, "Entries the poller has passed are pruned")
        var flood = RioOwnChangeCounts()
        for index in 0..<100 { flood.insert(index) }
        TestSupport.expect(flood.counts.count <= RioOwnChangeCounts.capacity, "Capped as a backstop")
        TestSupport.expect(flood.counts.contains(99), "The newest survive the cap")
    }
}
