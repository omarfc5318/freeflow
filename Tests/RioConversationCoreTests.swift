import Foundation

enum RioConversationCoreTests {
    private static let t0 = Date(timeIntervalSince1970: 1_000_000)
    private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    static func run() {
        testStartsOff()
        testTurnOnAndOff()
        testTapToggles()
        testTurnOnTwiceAnnouncesOnce()
        testTurnOffWhileOffDoesNothing()
        testOffReasonsAreReported()
        testPauseWhileOtherAppUsesMic()
        testPauseWhileDictating()
        testPauseNeedsBothReasonsCleared()
        testPauseDoesNothingWhenOff()
        testTurnOnWhileCallAlreadyRunningIsPaused()
        testIdleTimeoutAfterFiveMinutes()
        testCommandResetsIdleClock()
        testIdleClockPausesDuringCallAndRestartsOnResume()
        testIdleDoesNothingWhenOff()
        testCommandWhilePausedIsIgnoredForIdle()
        testTurnOffClearsPauseState()
        testMicUsageMonitorDecisionDebounce()
        testStopListeningDetection()
    }

    private static func testStartsOff() {
        let core = RioConversationCore()
        TestSupport.expect(!core.isOn, "starts off")
        TestSupport.expect(!core.isPaused, "starts unpaused")
        TestSupport.expectEqual(core.idleDeadline, nil)
    }

    private static func testTurnOnAndOff() {
        var core = RioConversationCore()
        TestSupport.expectEqual(core.turnOn(now: at(0)), [.announceOn])
        TestSupport.expect(core.isOn, "on")
        TestSupport.expectEqual(core.turnOff(.menu), [.announceOff(.menu)])
        TestSupport.expect(!core.isOn, "off")
    }

    private static func testTapToggles() {
        var core = RioConversationCore()
        TestSupport.expectEqual(core.toggle(now: at(0), offReason: .tap), [.announceOn])
        TestSupport.expect(core.isOn, "first tap on")
        TestSupport.expectEqual(core.toggle(now: at(5), offReason: .tap), [.announceOff(.tap)])
        TestSupport.expect(!core.isOn, "second tap off")
        TestSupport.expectEqual(core.toggle(now: at(9), offReason: .menu), [.announceOn])
        TestSupport.expectEqual(core.toggle(now: at(10), offReason: .menu), [.announceOff(.menu)])
    }

    private static func testTurnOnTwiceAnnouncesOnce() {
        var core = RioConversationCore()
        _ = core.turnOn(now: at(0))
        TestSupport.expectEqual(core.turnOn(now: at(1)), [])
    }

    private static func testTurnOffWhileOffDoesNothing() {
        var core = RioConversationCore()
        TestSupport.expectEqual(core.turnOff(.stopListening), [])
    }

    private static func testOffReasonsAreReported() {
        for reason in [RioConversationCore.OffReason.tap, .menu, .stopListening, .idleTimeout, .unavailable, .settings] {
            var core = RioConversationCore()
            _ = core.turnOn(now: at(0))
            TestSupport.expectEqual(core.turnOff(reason), [.announceOff(reason)])
        }
    }

    private static func testPauseWhileOtherAppUsesMic() {
        var core = RioConversationCore()
        _ = core.turnOn(now: at(0))
        core.setOtherAppUsingMic(true, now: at(10))
        TestSupport.expect(core.isOn, "stays on during a call")
        TestSupport.expect(core.isPaused, "paused during a call")
        core.setOtherAppUsingMic(false, now: at(100))
        TestSupport.expect(!core.isPaused, "resumes when the call ends")
        TestSupport.expect(core.isOn, "still on after the call")
    }

    private static func testPauseWhileDictating() {
        var core = RioConversationCore()
        _ = core.turnOn(now: at(0))
        core.setDictationActive(true, now: at(10))
        TestSupport.expect(core.isPaused, "paused while Fn is in use")
        core.setDictationActive(false, now: at(15))
        TestSupport.expect(!core.isPaused, "resumed after Fn")
    }

    private static func testPauseNeedsBothReasonsCleared() {
        var core = RioConversationCore()
        _ = core.turnOn(now: at(0))
        core.setOtherAppUsingMic(true, now: at(1))
        core.setDictationActive(true, now: at(2))
        core.setDictationActive(false, now: at(3))
        TestSupport.expect(core.isPaused, "still paused: the call continues")
        core.setOtherAppUsingMic(false, now: at(4))
        TestSupport.expect(!core.isPaused, "resumed once both are clear")
    }

    private static func testPauseDoesNothingWhenOff() {
        var core = RioConversationCore()
        core.setOtherAppUsingMic(true, now: at(0))
        TestSupport.expect(!core.isPaused, "off is never reported as paused")
        TestSupport.expect(!core.isOn, "pause input never turns it on")
    }

    private static func testTurnOnWhileCallAlreadyRunningIsPaused() {
        var core = RioConversationCore()
        core.setOtherAppUsingMic(true, now: at(0))
        _ = core.turnOn(now: at(1))
        TestSupport.expect(core.isOn && core.isPaused, "on but paused straight away")
        core.setOtherAppUsingMic(false, now: at(50))
        TestSupport.expect(!core.isPaused, "resumes")
    }

    private static func testIdleTimeoutAfterFiveMinutes() {
        var core = RioConversationCore()
        _ = core.turnOn(now: at(0))
        TestSupport.expectEqual(RioConversationCore.idleTimeout, 300)
        TestSupport.expectEqual(core.idleDeadline, at(300))
        TestSupport.expectEqual(core.tick(now: at(299)), [])
        TestSupport.expect(core.isOn, "still on at 4:59")
        TestSupport.expectEqual(core.tick(now: at(300)), [.announceOff(.idleTimeout)])
        TestSupport.expect(!core.isOn, "off at 5:00")
    }

    private static func testCommandResetsIdleClock() {
        var core = RioConversationCore()
        _ = core.turnOn(now: at(0))
        core.commandHeard(now: at(200))
        TestSupport.expectEqual(core.tick(now: at(400)), [])
        TestSupport.expect(core.isOn, "a command at 200 s keeps it alive past 300 s")
        TestSupport.expectEqual(core.tick(now: at(500)), [.announceOff(.idleTimeout)])
    }

    private static func testIdleClockPausesDuringCallAndRestartsOnResume() {
        var core = RioConversationCore()
        _ = core.turnOn(now: at(0))
        core.setOtherAppUsingMic(true, now: at(100))
        TestSupport.expectEqual(core.tick(now: at(3_000)), [])
        TestSupport.expect(core.isOn, "a long call never trips the idle timeout")
        TestSupport.expectEqual(core.idleDeadline, nil)
        core.setOtherAppUsingMic(false, now: at(3_000))
        TestSupport.expectEqual(core.idleDeadline, at(3_300))
        TestSupport.expectEqual(core.tick(now: at(3_200)), [])
        TestSupport.expectEqual(core.tick(now: at(3_300)), [.announceOff(.idleTimeout)])
    }

    private static func testIdleDoesNothingWhenOff() {
        var core = RioConversationCore()
        TestSupport.expectEqual(core.tick(now: at(10_000)), [])
    }

    private static func testCommandWhilePausedIsIgnoredForIdle() {
        var core = RioConversationCore()
        _ = core.turnOn(now: at(0))
        core.setDictationActive(true, now: at(10))
        core.commandHeard(now: at(20))
        core.setDictationActive(false, now: at(30))
        TestSupport.expectEqual(core.idleDeadline, at(330))
    }

    private static func testTurnOffClearsPauseState() {
        var core = RioConversationCore()
        _ = core.turnOn(now: at(0))
        core.setOtherAppUsingMic(true, now: at(1))
        _ = core.turnOff(.tap)
        _ = core.turnOn(now: at(2))
        TestSupport.expect(core.isOn && core.isPaused, "the call is still tracked across off/on")
        core.setOtherAppUsingMic(false, now: at(3))
        TestSupport.expect(!core.isPaused, "and it can end")
    }

    private static func testMicUsageMonitorDecisionDebounce() {
        // Two flapping polls must not flip pause on and off: a call is "over" only after
        // `MicUsageDebounce.pollsToClear` consecutive clear polls.
        var debounce = MicUsageDebounce()
        TestSupport.expect(debounce.update(otherAppUsing: true), "busy straight away")
        TestSupport.expect(debounce.update(otherAppUsing: false), "one clear poll is not enough")
        TestSupport.expect(debounce.update(otherAppUsing: true), "back to busy")
        var stillBusy = true
        for _ in 0..<MicUsageDebounce.pollsToClear { stillBusy = debounce.update(otherAppUsing: false) }
        TestSupport.expect(!stillBusy, "clear after enough clear polls")
    }

    private static func testStopListeningDetection() {
        for phrase in ["stop listening", "Rio, stop listening.", "rio stop listening", "Hey Rio, go to sleep",
                       "Rio that's all", "Stop conversation mode"] {
            TestSupport.expect(RioConversationCommands.isStopListening(phrase), "'\(phrase)' stops listening")
        }
        for phrase in ["open Chrome", "Rio open Spotify", "", "don't stop listening to music",
                       "stop listening to the podcast", "volume down"] {
            TestSupport.expect(!RioConversationCommands.isStopListening(phrase), "'\(phrase)' must not stop listening")
        }
    }
}
