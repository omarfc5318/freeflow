import Foundation

/// Speech gate, milestones and moment text. Synthetic numbers only.
enum TeddyMomentTests {
    static func run() {
        testSpeechGate()
        testModeSwitchKeepsHeardSpeech()
        testErrorShrug()
        testWordMilestones()
        testStreakMilestones()
        testWordsBeatStreak()
        testMomentText()
    }

    private static func summary(words: Int = 0, streak: Int = 0) -> UsageSummary {
        UsageSummary(
            totalWords: words, totalSessions: 0, wordsThisWeek: 0, wordsToday: 0,
            wordsPerMinute: 0, currentStreak: streak, longestStreak: streak, timeSavedSeconds: 0
        )
    }

    private static func testSpeechGate() {
        func skip(_ seconds: Double, _ heard: Double, _ peak: Float, command: Bool = false, whisper: Bool = false) -> Bool {
            TeddyShrug.shouldSkipTranscription(
                isCommandMode: command, recordedSeconds: seconds, heardSpeechSeconds: heard, peakDB: peak,
                whisperMode: whisper
            )
        }
        TestSupport.expect(skip(0.16, 0, -30), "A quick tap is skipped")
        TestSupport.expect(skip(3, 0, -70), "Silence is skipped")
        TestSupport.expect(!skip(3, 1.2, -20), "Speech is sent")
        TestSupport.expect(!skip(3, 0, -30), "Loud audio without detected speech is sent")
        TestSupport.expect(!skip(0.16, 0, -90, command: true), "Edit Mode always sends")
        // Review regressions: whispers and low-gain mics are never dropped as silence.
        TestSupport.expect(!skip(0.8, 0, -55), "A quiet phrase above the room floor is sent")
        TestSupport.expect(!skip(2, 0, -75, whisper: true), "Whisper mode never skips a real recording")
        TestSupport.expect(skip(0.16, 0, -30, whisper: true), "Whisper mode still skips a tap")
    }

    /// Review regression: switching from hold to tap mode mid-recording used to replace the
    /// detector, forgetting the speech said while holding, so the dictation was skipped.
    private static func testModeSwitchKeepsHeardSpeech() {
        var detector = SilenceAutoStop(delay: 5)
        for _ in 0..<50 { _ = detector.shouldStop(afterBufferWithRMS: powf(10, -62 / 20), duration: 0.02) }
        for _ in 0..<75 { _ = detector.shouldStop(afterBufferWithRMS: powf(10, -25 / 20), duration: 0.02) }
        let heard = detector.heardSpeechSeconds
        TestSupport.expect(heard > 1, "Speech while holding is heard")
        detector.restartCountdown()
        var stopped = false
        for _ in 0..<300 { stopped = stopped || detector.shouldStop(afterBufferWithRMS: powf(10, -62 / 20), duration: 0.02) }
        TestSupport.expect(!stopped, "After the switch, new speech is needed before auto-stop")
        TestSupport.expect(detector.heardSpeechSeconds == heard, "The speech heard before the switch is kept")
        TestSupport.expect(
            !TeddyShrug.shouldSkipTranscription(
                isCommandMode: false, recordedSeconds: 9, heardSpeechSeconds: detector.heardSpeechSeconds,
                peakDB: detector.peakDB
            ),
            "So the dictation is still sent"
        )
    }

    private static func testErrorShrug() {
        let rejected = "Submission failed: Provider rejected the request (HTTP 400). Check your model name."
        TestSupport.expect(TeddyShrug.shouldShrugOnError(recordedSeconds: 0.5, errorDescription: rejected), "Short rejected recording shrugs")
        TestSupport.expect(!TeddyShrug.shouldShrugOnError(recordedSeconds: 1.0, errorDescription: rejected), "One second shows the error")
        TestSupport.expect(!TeddyShrug.shouldShrugOnError(recordedSeconds: 8, errorDescription: rejected), "Long recording shows the error")
        // Review regression: real setup problems on short recordings still show their error.
        for other in ["Submission failed: Invalid API key (HTTP 401)", "Submission failed: Rate limited (HTTP 429)", "Upload failed: The network connection was lost."] {
            TestSupport.expect(!TeddyShrug.shouldShrugOnError(recordedSeconds: 0.5, errorDescription: other), "Shows: \(other)")
        }
    }

    private static func testWordMilestones() {
        TestSupport.expectEqual(
            TeddyMilestoneCore.crossed(before: summary(words: 990), after: summary(words: 1_010))?.label, "1,000 words"
        )
        TestSupport.expectEqual(
            TeddyMilestoneCore.crossed(before: summary(words: 999_990), after: summary(words: 1_000_000))?.label,
            "1,000,000 words"
        )
        TestSupport.expectEqual(
            TeddyMilestoneCore.crossed(before: summary(words: 4_990), after: summary(words: 5_000))?.label, "5,000 words"
        )
        TestSupport.expect(
            TeddyMilestoneCore.crossed(before: summary(words: 1_000), after: summary(words: 1_050)) == nil,
            "Already past a threshold does not repeat"
        )
        TestSupport.expect(
            TeddyMilestoneCore.crossed(before: summary(words: 10), after: summary(words: 900)) == nil,
            "No threshold, no milestone"
        )
        TestSupport.expectEqual(
            TeddyMilestoneCore.crossed(before: summary(words: 900), after: summary(words: 30_000))?.label, "25,000 words"
        )
    }

    private static func testStreakMilestones() {
        for (days, label) in [(3, "3-day streak"), (7, "7-day streak"), (365, "365-day streak")] {
            TestSupport.expectEqual(
                TeddyMilestoneCore.crossed(before: summary(streak: days - 1), after: summary(streak: days))?.label, label
            )
        }
        TestSupport.expect(
            TeddyMilestoneCore.crossed(before: summary(streak: 7), after: summary(streak: 7)) == nil,
            "Same day does not repeat"
        )
        TestSupport.expect(
            TeddyMilestoneCore.crossed(before: summary(streak: 5), after: summary(streak: 6)) == nil,
            "Between thresholds is quiet"
        )
        TestSupport.expect(
            TeddyMilestoneCore.crossed(before: summary(streak: 9), after: summary(streak: 1)) == nil,
            "A reset streak is not a milestone"
        )
    }

    private static func testWordsBeatStreak() {
        TestSupport.expectEqual(
            TeddyMilestoneCore.crossed(before: summary(words: 990, streak: 6), after: summary(words: 1_010, streak: 7))?.label,
            "1,000 words"
        )
    }

    private static func testMomentText() {
        TestSupport.expectEqual(TeddyMoment.didntCatchThat.text, "Didn't catch that")
        TestSupport.expectEqual(TeddyMoment.undone.text, "Undone")
        TestSupport.expectEqual(TeddyMoment.sent.text, "Sent")
        TestSupport.expectEqual(TeddyMoment.sent.caption, "Pressed Enter")
        TestSupport.expectEqual(TeddyMoment.milestone("7-day streak").text, "7-day streak")
        TestSupport.expectEqual(TeddyMoment.learned("Siobhan").caption, "Learned")
        for moment in [TeddyMoment.learned("x"), .didntCatchThat, .undone, .sent, .milestone("x")] {
            TestSupport.expect(moment.seconds > 0 && moment.seconds <= 5, "Sensible duration for \(moment.caption)")
        }
    }
}
