import Foundation

/// Speech gate, milestones and moment text. Synthetic numbers only.
enum TeddyMomentTests {
    static func run() {
        testSpeechGate()
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
        func skip(_ seconds: Double, _ heard: Double, _ peak: Float, command: Bool = false) -> Bool {
            TeddyShrug.shouldSkipTranscription(
                isCommandMode: command, recordedSeconds: seconds, heardSpeechSeconds: heard, peakDB: peak
            )
        }
        TestSupport.expect(skip(0.16, 0, -30), "A quick tap is skipped")
        TestSupport.expect(skip(3, 0, -70), "Silence is skipped")
        TestSupport.expect(!skip(3, 1.2, -20), "Speech is sent")
        TestSupport.expect(!skip(3, 0, -30), "Loud audio without detected speech is sent")
        TestSupport.expect(!skip(0.16, 0, -90, command: true), "Edit Mode always sends")
    }

    private static func testErrorShrug() {
        TestSupport.expect(TeddyShrug.shouldShrugOnError(recordedSeconds: 0.5), "Short recording shrugs")
        TestSupport.expect(!TeddyShrug.shouldShrugOnError(recordedSeconds: 1.0), "One second shows the error")
        TestSupport.expect(!TeddyShrug.shouldShrugOnError(recordedSeconds: 8), "Long recording shows the error")
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
