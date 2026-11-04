import Foundation

/// Pure tests for spoken timers: phrase parsing, duration parsing and countdown math with an
/// injected clock. Nothing here sleeps, plays audio or touches a real timer.
enum RioTimerCoreTests {
    private static func parse(_ raw: String) -> RioAction? {
        RioVoicePhrases.parse(raw: raw, simplified: RioText.simplify(raw))
    }

    static func run() {
        testDurationParsing()
        testStartPhrases()
        testLabels()
        testNotClaimed()
        testCancelAndStatusPhrases()
        testProtectingDurations()
        testCountdownMath()
        testSpokenDurations()
        testRealParserKeepsTimerPhrases()
        testStopKinds()
        testStopPlan()
    }

    /// F14/K52/F20: only words naming the timer cancel a countdown; silence words only quiet Rio.
    private static func testStopKinds() {
        let cases: [(String, RioStopKind?)] = [
            ("cancel the timer", .timer), ("stop the alarm", .timer), ("never mind the timer", .timer), ("stop ringing", .timer),
            ("stop", .bare), ("stop it", .bare), ("Stop that.", .bare), ("cancel", .bare), ("okay okay stop", .bare),
            ("please stop", .bare),
            ("stop talking", .silence), ("be quiet", .silence), ("quiet", .silence), ("hush", .silence), ("enough", .silence),
            ("that's enough", .silence), ("shut up", .silence), ("shush", .silence), ("stop speaking", .silence),
            ("stop the music", nil), ("stop listening", nil), ("open Chrome", nil), ("stop recording", nil),
        ]
        for (text, kind) in cases {
            ETest.eq(RioTimerPhrases.stopKind(RioText.simplify(text)), kind, "stop kind of \"\(text)\"")
        }
        for text in ["shut up", "okay okay stop", "stop speaking", "be silent"] {
            ETest.eq(parse(text), .cancelTimer, "\"\(text)\" stays local (never the brain's mute)")
        }
    }

    private static func testStopPlan() {
        let running = RioStopState(hasCountdown: true)
        // A bare stop or a silence word never cancels a running countdown.
        ETest.eq(RioStopPlan.step(kind: .bare, state: running), .nothing)
        ETest.eq(RioStopPlan.step(kind: .silence, state: running), .nothing)
        ETest.eq(RioStopPlan.step(kind: .silence, state: RioStopState(hasCountdown: true, isSpeaking: true)), .stopSpeaking)
        ETest.eq(RioStopPlan.step(kind: .timer, state: running), .cancelCountdown)
        // The bare stop order: ringing, task, speech, translator, music.
        ETest.eq(RioStopPlan.step(kind: .bare, state: RioStopState(isRinging: true, isTaskRunning: true)), .stopRinging)
        ETest.eq(RioStopPlan.step(kind: .bare, state: RioStopState(isTaskRunning: true, isSpeaking: true)), .stopTask)
        ETest.eq(RioStopPlan.step(kind: .bare, state: RioStopState(isSpeaking: true, isTranslating: true)), .stopSpeaking)
        ETest.eq(RioStopPlan.step(kind: .bare, state: RioStopState(isTranslating: true, isMediaPlaying: true)), .stopTranslator)
        ETest.eq(RioStopPlan.step(kind: .bare, state: RioStopState(hasCountdown: true, isMediaPlaying: true)), .pauseMedia)
        ETest.eq(RioStopPlan.step(kind: .silence, state: RioStopState(isMediaPlaying: true)), .nothing, "be quiet leaves the music")
        ETest.eq(RioStopPlan.step(kind: .silence, state: RioStopState(isRinging: true)), .stopRinging)
        // A planned cancelTimer (no words to go by) still cancels the timer.
        ETest.eq(RioStopPlan.step(kind: nil, state: running), .cancelCountdown)
        ETest.eq(RioStopPlan.step(kind: nil, state: RioStopState(hasCountdown: true, isTaskRunning: true)), .stopTask)
        ETest.eq(RioStopPlan.nothingMessage(kind: .silence), nil, "nothing to quiet: say nothing")
        ETest.eq(RioStopPlan.nothingMessage(kind: .bare), "There's nothing to stop")
        ETest.eq(RioStopPlan.nothingMessage(kind: .timer), "There's no timer running")
    }

    private static func testDurationParsing() {
        let cases: [(String, Int?)] = [
            ("10 minute timer", 600),
            ("set a timer for 2 and a half minutes", 150),
            ("set a timer for ten minutes", 600),
            ("start a 5 minute timer", 300),
            ("set a timer for an hour", 3600),
            ("set a timer for half an hour", 1800),
            ("timer for 1 hour and 30 minutes", 5400),
            ("set a timer for an hour and a half", 5400),
            ("set a 90 second timer", 90),
            ("set a timer for one and a half hours", 5400),
            ("two minute timer", 120),
            ("set a timer for forty five seconds", 45),
            ("set a timer for 1.5 minutes", 90),
            ("10 min timer", 600),
            ("10min timer", 600),
            ("30s timer", nil),
            ("set a timer for a quarter of an hour", 900),
            ("timer for a minute", 60),
            ("set a timer for twenty minutes", 1200),
            ("set a timer for 1 hour 15 minutes", 4500),
            ("set a timer for 25 hours", nil),
            ("set a timer for 0 minutes", nil),
            ("set a timer", nil),
            ("start a timer", nil),
        ]
        for (text, expected) in cases {
            TestSupport.expectEqualNamed(RioTimerDuration.parse(text), expected, "duration of \"\(text)\"")
        }
    }

    private static func testStartPhrases() {
        func timer(_ seconds: Int, _ label: String? = nil) -> RioAction? { .startTimer(seconds: seconds, label: label) }
        let cases: [(String, RioAction?)] = [
            ("10 minute timer", timer(600)),
            ("Set a timer for ten minutes.", timer(600)),
            ("start a 5 minute timer", timer(300)),
            ("timer 30 seconds called pasta", timer(30, "pasta")),
            ("set me a timer for 3 minutes please", timer(180)),
            ("set a 10-minute timer", timer(600)),
            ("timer for an hour", timer(3600)),
            ("start a countdown for 5 minutes", timer(300)),
        ]
        for (text, expected) in cases {
            TestSupport.expectEqualNamed(parse(text), expected, "timer phrase \"\(text)\"")
        }
    }

    private static func testLabels() {
        let cases: [(String, String?)] = [
            ("timer 30 seconds called pasta", "pasta"),
            ("set a timer for 20 minutes called laundry", "laundry"),
            ("set a timer for 20 minutes named green tea", "green tea"),
            ("set a pasta timer for 10 minutes", "pasta"),
            ("set a timer for 10 minutes for the pasta", "pasta"),
            ("set a 20 minute timer for the tea", "tea"),
            ("pasta timer 10 minutes", "pasta"),
            ("set a timer for 10 minutes", nil),
            ("set a 5 minute timer", nil),
        ]
        for (text, expected) in cases {
            guard case .startTimer(_, let label)? = parse(text) else {
                TestSupport.expect(false, "\"\(text)\" should be a timer")
                continue
            }
            TestSupport.expectEqualNamed(label, expected, "label of \"\(text)\"")
        }
    }

    private static func testNotClaimed() {
        let nothing = [
            "start a timer", "set a timer", "open timer", "open the timer app", "quit timer",
            "set an alarm for 7 am", "remind me in 10 minutes", "open Chrome", "open YouTube",
            "close Spotify", "set the volume to 40", "what time is it", "set a timer for 25 hours",
            "put Chrome on the left", "search for 10 minute timer", "type timer for 10 minutes",
        ]
        for text in nothing {
            let claimed = parse(text)
            TestSupport.expect(claimed == nil, "\"\(text)\" must not be claimed, got \(String(describing: claimed))")
        }
    }

    private static func testCancelAndStatusPhrases() {
        let cancel = [
            "cancel the timer", "cancel timer", "stop the timer", "delete the timer", "clear my timer",
            "cancel the pasta timer", "cancel the 10 minute timer", "turn off the timer", "dismiss the timer",
            "stop the alarm", "silence the alarm", "stop ringing", "never mind the timer", "forget the timer",
            "stop", "stop it", "stop that", "be quiet", "quiet", "hush", "stop talking", "that's enough", "enough",
            "silence", "shush",
        ]
        for text in cancel {
            TestSupport.expectEqualNamed(parse(text), .cancelTimer, "cancel phrase \"\(text)\"")
        }
        let status = [
            "how much time is left", "how much time is left on the timer", "how long is left",
            "how long is left on my timer", "how much longer", "what's left on the timer", "time left",
            "timer status", "check the timer", "is my timer still running", "how much time do I have left",
            "how long until the timer goes off", "when does my timer go off",
        ]
        for text in status {
            TestSupport.expectEqualNamed(parse(text), .timerStatus, "status phrase \"\(text)\"")
        }
        for text in ["how long is the flight", "how much is this", "what's left of my battery", "stop listening"] {
            let claimed = parse(text)
            TestSupport.expect(claimed != .timerStatus && claimed != .cancelTimer, "\"\(text)\" wrongly claimed")
        }
    }

    private static func testProtectingDurations() {
        // The parser splits clauses on "and" before any phrase layer runs, so a duration like
        // "2 and a half minutes" is rewritten to plain seconds first (only when a timer is meant).
        let cases: [(String, String)] = [
            ("set a timer for 2 and a half minutes", "set a timer for 150 seconds"),
            ("timer for 1 hour and 30 minutes", "timer for 5400 seconds"),
            ("set a timer for an hour and a half", "set a timer for 5400 seconds"),
            ("open Chrome and Spotify", "open Chrome and Spotify"),
            ("search for 2 and a half men", "search for 2 and a half men"),
            ("start a 5 minute timer and open Chrome", "start a 5 minute timer and open Chrome"),
            ("set a timer for 2 and a half minutes and open Chrome", "set a timer for 150 seconds and open Chrome"),
        ]
        for (text, expected) in cases {
            TestSupport.expectEqualNamed(RioTimerPhrases.protectingDurations(in: text), expected, "protect \"\(text)\"")
        }
    }

    private static func testCountdownMath() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let timer = RioTimerCountdown(seconds: 600, label: "pasta", start: start)
        TestSupport.expectEqual(timer.remaining(at: start), 600)
        TestSupport.expectEqual(timer.remaining(at: start.addingTimeInterval(100)), 500)
        TestSupport.expectEqual(timer.remaining(at: start.addingTimeInterval(599.5)), 0.5)
        TestSupport.expect(!timer.isFinished(at: start.addingTimeInterval(599.9)), "not finished yet")
        TestSupport.expect(timer.isFinished(at: start.addingTimeInterval(600)), "finished at zero")
        TestSupport.expectEqual(timer.remaining(at: start.addingTimeInterval(9_999)), 0)
        // A clock that jumps backwards never shows more than the full length.
        TestSupport.expectEqual(timer.remaining(at: start.addingTimeInterval(-50)), 600)
        TestSupport.expectEqual(timer.endDate, start.addingTimeInterval(600))

        TestSupport.expectEqual(timer.spokenRemaining(at: start.addingTimeInterval(100)), "8 minutes and 20 seconds left")
        TestSupport.expectEqual(timer.spokenRemaining(at: start.addingTimeInterval(541)), "59 seconds left")
        TestSupport.expectEqual(timer.spokenRemaining(at: start.addingTimeInterval(599)), "1 second left")
        TestSupport.expectEqual(timer.spokenRemaining(at: start.addingTimeInterval(600)), "No time left")
        TestSupport.expectEqual(timer.doneLine, "Your pasta timer is done!")
        TestSupport.expectEqual(RioTimerCountdown(seconds: 60, label: nil, start: start).doneLine, "Your timer is done!")
        TestSupport.expectEqual(timer.startedSummary, "Pasta timer set for 10 minutes")
        TestSupport.expectEqual(RioTimerCountdown(seconds: 90, label: nil, start: start).startedSummary, "Timer set for 1 minute and 30 seconds")

        // Ceiling for the display: 0.2 s left still shows as one second.
        TestSupport.expectEqual(RioTimerCountdown.displaySeconds(0.2), 1)
        TestSupport.expectEqual(RioTimerCountdown.displaySeconds(0), 0)
        TestSupport.expectEqual(RioTimerCountdown.displaySeconds(61.0), 61)
    }

    private static func testSpokenDurations() {
        TestSupport.expectEqual(RioTimerDuration.spoken(1), "1 second")
        TestSupport.expectEqual(RioTimerDuration.spoken(45), "45 seconds")
        TestSupport.expectEqual(RioTimerDuration.spoken(60), "1 minute")
        TestSupport.expectEqual(RioTimerDuration.spoken(150), "2 minutes and 30 seconds")
        TestSupport.expectEqual(RioTimerDuration.spoken(3600), "1 hour")
        TestSupport.expectEqual(RioTimerDuration.spoken(5400), "1 hour and 30 minutes")
        TestSupport.expectEqual(RioTimerDuration.spoken(3661), "1 hour, 1 minute and 1 second")
    }

    private static func testRealParserKeepsTimerPhrases() {
        let parser = RioActionParser(installedApps: [])
        let cases: [(String, RioActionParse)] = [
            ("10 minute timer", .actions([.startTimer(seconds: 600, label: nil)])),
            ("Rio, set a timer for 20 minutes called laundry", .actions([.startTimer(seconds: 1200, label: "laundry")])),
            ("timer 30 seconds called pasta", .actions([.startTimer(seconds: 30, label: "pasta")])),
            // An Arabic label survives the word scanner (round 1: "...للشاي").
            ("set a timer for 20 minutes called الشاي", .actions([.startTimer(seconds: 1200, label: "الشاي")])),
            ("cancel the timer", .actions([.cancelTimer])),
            ("how much time is left", .actions([.timerStatus])),
            ("stop", .actions([.cancelTimer])),
            ("Start a timer", .unknown("Start a timer")),
        ]
        for (text, expected) in cases {
            TestSupport.expectEqualNamed(parser.parse(text), expected, "parser on \"\(text)\"")
        }
        // The lead's one-line patch: protect durations before the clause split.
        let protected = RioTimerPhrases.protectingDurations(in: "set a timer for 2 and a half minutes")
        TestSupport.expectEqual(parser.parse(protected), .actions([.startTimer(seconds: 150, label: nil)]))
    }
}
