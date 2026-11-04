import Foundation

enum RioConversationCoreTests {
    private static let t0 = Date(timeIntervalSince1970: 1_000_000)
    private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    static func run() {
        testStartsOff()
        testTurnOnAndOff()
        testChordToggles()
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
        testPanickedAndSilenceStops()
        testArabicStops()
        testStopKinds()
        testDeclineWords()
        testQuickReplies()
        testBargeInOnlyTakesStops()
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

    private static func testChordToggles() {
        var core = RioConversationCore()
        TestSupport.expectEqual(core.toggle(now: at(0), offReason: .chord), [.announceOn])
        TestSupport.expect(core.isOn, "first tap on")
        TestSupport.expectEqual(core.toggle(now: at(5), offReason: .chord), [.announceOff(.chord)])
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
        for reason in [RioConversationCore.OffReason.chord, .menu, .stopListening, .idleTimeout, .unavailable, .settings] {
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
        _ = core.turnOff(.chord)
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

    private static func testPanickedAndSilenceStops() {
        let stops = [
            "Rio stop stop stop", "Rio no stop", "Rio cancel cancel", "Rio wait", "Rio hold on", "Rio forget it",
            "Rio scratch that", "Rio no no no", "Rio shut up", "Rio stop talking", "Rio be quiet", "Rio quiet",
            "Rio enough", "Rio that's enough", "Rio okay okay stop", "Rio stop please", "Rio stop it", "Rio cancel",
            "Rio, stop it stop it", "hey Rio stop now"
        ]
        for text in stops {
            TestSupport.expect(RioConversationCommands.isBareStop(text), "bare stop: \(text)")
        }
        let notStops = [
            "Rio stop the timer", "Rio stop music", "Rio stop listening", "Rio no", "Rio okay", "Rio",
            "Rio wait for the download", "Rio shut down the computer", "Rio quiet mode on", "Rio please open chrome"
        ]
        for text in notStops {
            TestSupport.expect(!RioConversationCommands.isBareStop(text), "not a bare stop: \(text)")
        }
    }

    private static func testArabicStops() {
        for text in ["بس", "ريو بس", "ريو خلاص", "ريو اسكت", "ريو كفاية", "ريو وقف", "ريو بس خلاص", "يا ريو بس",
                     "Rio بس", "ريو وَقِّف", "ريو لا لا بس"] {
            TestSupport.expect(RioConversationCommands.isBareStop(text), "Arabic bare stop: \(text)")
        }
        for text in ["ريو افتح كروم", "ريو", "ريو بس افتح سفاري"] {
            TestSupport.expect(!RioConversationCommands.isBareStop(text), "not a bare stop: \(text)")
        }
    }

    private static func testStopKinds() {
        TestSupport.expectEqual(RioConversationCommands.bareStop("Rio stop"), .stop)
        TestSupport.expectEqual(RioConversationCommands.bareStop("Rio shut up"), .stop)
        TestSupport.expectEqual(RioConversationCommands.bareStop("ريو بس"), .stop)
        TestSupport.expectEqual(RioConversationCommands.bareStop("Rio okay okay stop"), .stop)
        // These only interrupt what is running; with nothing running they do nothing.
        TestSupport.expectEqual(RioConversationCommands.bareStop("Rio forget it"), .abort)
        TestSupport.expectEqual(RioConversationCommands.bareStop("Rio cancel"), .abort)
        TestSupport.expectEqual(RioConversationCommands.bareStop("Rio no no no"), .abort)
        TestSupport.expectEqual(RioConversationCommands.bareStop("Rio wait"), .abort)
        TestSupport.expectEqual(RioConversationCommands.bareStop("Rio open chrome"), nil)
    }

    private static func testDeclineWords() {
        for text in ["ريو لا", "لا", "لا لا", "لأ", "Rio no no", "Rio nah", "Rio don't", "Rio no thank you"] {
            TestSupport.expect(RioConversationCommands.declinesBySpeech(text), "\(text) declines")
        }
        for text in ["Rio yeah do it", "نعم", "Rio sure"] {
            TestSupport.expectEqual(RioConversationCommands.spokenAnswer(text), .yes)
        }
        TestSupport.expectEqual(RioConversationCommands.spokenAnswer("Rio open chrome"), nil)
    }

    private static func testQuickReplies() {
        let welcome = RioConversationCommands.welcomeLine
        let nothing = RioConversationCommands.nothingToConfirmLine
        for text in ["Rio thank you", "Rio thanks", "Rio thank you so much", "thanks Rio", "Rio thanks a lot"] {
            TestSupport.expectEqual(RioConversationCommands.quickReply(text, isConfirmationShowing: false), welcome)
        }
        // Arabic thanks get an Arabic answer (round 3, finding 59).
        TestSupport.expectEqual(
            RioConversationCommands.quickReply("ريو شكرا", isConfirmationShowing: false), RioConversationCommands.arabicWelcomeLine
        )
        for text in ["Rio yes", "Rio no", "Rio nah", "Rio yeah do it"] {
            TestSupport.expectEqual(RioConversationCommands.quickReply(text, isConfirmationShowing: false), nothing)
            TestSupport.expectEqual(RioConversationCommands.quickReply(text, isConfirmationShowing: true), nil)
        }
        // Stop words and real commands are not answered here.
        for text in ["Rio cancel", "Rio no no no", "Rio open chrome", "Rio thank you for the help with the email",
                     "Rio hi, open Chrome", "Rio good morning, what's on my calendar", "Rio hear me out", "ريو هلا افتح كروم"] {
            TestSupport.expectEqual(RioConversationCommands.quickReply(text, isConfirmationShowing: false), nil)
        }
        // Greetings and presence checks: answered locally, no model call (findings 58, 76).
        let greetings: [(String, String)] = [
            ("Rio hi", "Hey"), ("Rio, hello!", "Hey"), ("Rio good morning", "Good morning"), ("Rio, are you there?", "I'm here"),
            ("Rio can you hear me", "I'm here"), ("hear me", "I'm here"), ("Rio what's your name", "I'm Rio"),
            ("Thank you, Rio.", RioConversationCommands.welcomeLine), ("thank you Rio", RioConversationCommands.welcomeLine),
            ("ريو هلا", "هلا والله"), ("ريو هلا والله", "هلا والله"), ("ريو السلام عليكم", "وعليكم السلام"),
            ("ريو السلام عليكم ورحمة الله وبركاته", "وعليكم السلام"), ("ريو صباح الخير", "صباح النور"),
            ("ريو كيفك", "بخير، الحمد لله"), ("ريو وش اسمك", "أنا ريو"), ("يا ريو مساء الخير", "مساء النور"),
        ]
        for (text, reply) in greetings {
            TestSupport.expectEqual(RioConversationCommands.quickReply(text, isConfirmationShowing: false), reply)
            TestSupport.expectEqual(RioConversationCommands.quickReply(text, isConfirmationShowing: true), reply)
        }
    }

    private static func testBargeInOnlyTakesStops() {
        let policy = RioConversationBargeIn.self
        TestSupport.expect(policy.accepts("stop", isRioSpeaking: true, secondsSinceRioSpoke: nil), "a stop interrupts him")
        TestSupport.expect(policy.accepts("shut up", isRioSpeaking: true, secondsSinceRioSpoke: nil), "so does shut up")
        TestSupport.expect(!policy.accepts("open chrome", isRioSpeaking: true, secondsSinceRioSpoke: nil), "his own voice runs nothing")
        TestSupport.expect(!policy.accepts("delete the file", isRioSpeaking: false, secondsSinceRioSpoke: 1), "nor its echo tail")
        TestSupport.expect(policy.accepts("open chrome", isRioSpeaking: false, secondsSinceRioSpoke: 10), "later, anything goes")
        TestSupport.expect(policy.accepts("open chrome", isRioSpeaking: false, secondsSinceRioSpoke: nil), "he hasn't spoken")
    }
}
