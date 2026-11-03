import Foundation

/// Pure tests for Rio's spoken lines. The seed, hour and day are injected, so nothing is random.
enum RioPersonalityTests {
    private static func line(
        _ outcome: RioActionOutcome, hour: Int = 14, day: Int = 20_261_103, seed: UInt64,
        state: inout RioPersonalityState
    ) -> String? {
        RioPersonality.line(for: outcome, hour: hour, day: day, seed: seed, state: &state)
    }

    static func run() {
        testSilentOutcomes()
        testSuccessLines()
        testNeverRepeatsTwiceInARow()
        testDeterministicForASeed()
        testFailureAndUnknownLines()
        testAnswersAreSpokenVerbatim()
        testRegisteredVerbatimText()
        testGreetingOncePerDay()
        testMilestones()
        testLinesStayShort()
        testPunsAreRare()
        testSpeechTextPreparation()
        testSharedEntryPoint()
    }

    private static func testSilentOutcomes() {
        var state = RioPersonalityState()
        TestSupport.expect(line(.nothing, seed: 1, state: &state) == nil, "nothing stays quiet")
        TestSupport.expectEqual(state, RioPersonalityState())
    }

    private static func testSuccessLines() {
        var state = RioPersonalityState()
        for seed in 0..<60 {
            guard let spoken = line(.succeeded("Opened Google Chrome"), seed: UInt64(seed), state: &state) else {
                TestSupport.expect(false, "a success always has a line")
                return
            }
            TestSupport.expect(!spoken.isEmpty, "non-empty")
            TestSupport.expect(!spoken.contains("Opened Google Chrome.Opened"), "summary spoken once")
            let mentions = spoken.components(separatedBy: "Opened Google Chrome").count - 1
            TestSupport.expect(mentions <= 1, "summary never spoken twice: \(spoken)")
        }
        var seen = Set<String>()
        var other = RioPersonalityState()
        for seed in 0..<80 { seen.insert(line(.succeeded("Volume 40 percent"), seed: UInt64(seed), state: &other) ?? "") }
        TestSupport.expect(seen.count >= 6, "success lines should have variety, got \(seen.count)")
        TestSupport.expect(
            seen.contains { $0.hasPrefix("On it!") || $0.hasPrefix("Done!") || $0.hasPrefix("Ta-da") },
            "classic openers present"
        )
    }

    private static func testNeverRepeatsTwiceInARow() {
        for outcome in [RioActionOutcome.succeeded("Done"), .failed("I couldn't find an app called Crome"), .unknown, .cancelled] {
            var state = RioPersonalityState()
            var previous: String?
            for seed in 0..<300 {
                let spoken = line(outcome, seed: UInt64(seed % 7), state: &state)
                TestSupport.expect(spoken != previous, "repeated \(String(describing: spoken)) for \(outcome)")
                previous = spoken
            }
        }
    }

    private static func testDeterministicForASeed() {
        for seed in [0, 1, 42, 9_999] as [UInt64] {
            var a = RioPersonalityState(), b = RioPersonalityState()
            TestSupport.expectEqual(
                line(.succeeded("Muted"), seed: seed, state: &a),
                line(.succeeded("Muted"), seed: seed, state: &b)
            )
        }
    }

    private static func testFailureAndUnknownLines() {
        var state = RioPersonalityState()
        for seed in 0..<40 {
            let failed = line(.failed("I couldn't find an app called Crome"), seed: UInt64(seed), state: &state) ?? ""
            TestSupport.expect(failed.contains("couldn't find an app called Crome"), "failure keeps the reason: \(failed)")
            let unknown = line(.unknown, seed: UInt64(seed), state: &state) ?? ""
            TestSupport.expect(!unknown.isEmpty && unknown.count < 90, "unknown shrug line: \(unknown)")
            let cancelled = line(.cancelled, seed: UInt64(seed), state: &state) ?? ""
            TestSupport.expect(!cancelled.isEmpty && cancelled.count < 60, "cancel line: \(cancelled)")
        }
        var gentle = Set<String>()
        var other = RioPersonalityState()
        for seed in 0..<60 { gentle.insert(line(.unknown, seed: UInt64(seed), state: &other) ?? "") }
        TestSupport.expect(gentle.contains { $0.contains("try again") }, "some shrugs offer another try")
    }

    private static func testAnswersAreSpokenVerbatim() {
        var state = RioPersonalityState()
        let answer = "The capital of Qatar is Doha. It sits on the east coast of the peninsula."
        TestSupport.expectEqual(line(.succeeded(answer), seed: 5, state: &state), answer)
        let agenda = "You've got 3 things today. Next: Call with Ali at 3 PM."
        TestSupport.expectEqual(line(.succeeded(agenda), seed: 6, state: &state), agenda)
        // A morning greeting never gets bolted onto an answer.
        var morning = RioPersonalityState()
        TestSupport.expectEqual(line(.succeeded(answer), hour: 8, seed: 1, state: &morning), answer)
        TestSupport.expect(morning.lastGreetingDay == nil, "greeting not used up by an answer")
        // Very long text is trimmed at a sentence so he never rambles.
        let long = String(repeating: "This is a sentence. ", count: 60)
        let trimmed = line(.succeeded(long), seed: 3, state: &state) ?? ""
        TestSupport.expect(trimmed.count <= RioSpeechText.maxLength, "long answers are capped")
        TestSupport.expect(trimmed.hasSuffix("."), "cap lands on a sentence")
        TestSupport.expect(RioPersonality.isLongAnswer(answer), "two sentences count as an answer")
        TestSupport.expect(!RioPersonality.isLongAnswer("Opened Google Chrome"), "a summary is not an answer")
        TestSupport.expect(!RioPersonality.isLongAnswer("Moved Google Chrome to the other screen"), "window summary")
    }

    private static func testRegisteredVerbatimText() {
        // The journal registers the text of answer-like actions, so even a one-word answer is
        // spoken as itself instead of getting an opener.
        var state = RioPersonalityState()
        state.verbatim = ["Yes"]
        TestSupport.expectEqual(line(.succeeded("Yes"), seed: 1, state: &state), "Yes")
        TestSupport.expect(state.verbatim.isEmpty, "registered text is used once")
        state.verbatim = ["64 percent"]
        TestSupport.expectEqual(line(.succeeded("Opened Notes, 64 percent"), seed: 1, state: &state), "64 percent")
        state.verbatim = ["stale"]
        _ = line(.succeeded("Opened Notes"), seed: 2, state: &state)
        TestSupport.expect(state.verbatim.isEmpty, "stale text is dropped")
    }

    private static func testGreetingOncePerDay() {
        var state = RioPersonalityState()
        let first = line(.succeeded("Opened Notes"), hour: 8, day: 100, seed: 0, state: &state) ?? ""
        TestSupport.expect(first.hasPrefix("Good morning!"), "first morning command greets: \(first)")
        TestSupport.expectEqual(state.lastGreetingDay, 100)
        let second = line(.succeeded("Opened Safari"), hour: 8, day: 100, seed: 0, state: &state) ?? ""
        TestSupport.expect(!second.contains("Good morning"), "no second greeting the same day")
        let nextDay = line(.succeeded("Opened Safari"), hour: 9, day: 101, seed: 4, state: &state) ?? ""
        TestSupport.expect(nextDay.hasPrefix("Good morning!"), "greets again the next morning")

        var afternoon = RioPersonalityState()
        let pm = line(.succeeded("Opened Notes"), hour: 15, day: 7, seed: 0, state: &afternoon) ?? ""
        TestSupport.expect(!pm.contains("Good morning"), "afternoon is not morning")
        var late = RioPersonalityState()
        let night = line(.succeeded("Opened Notes"), hour: 2, day: 8, seed: 0, state: &late) ?? ""
        TestSupport.expect(night.lowercased().contains("late") || night.lowercased().contains("up"), "night owl line: \(night)")
        // Failures never carry a greeting.
        var failing = RioPersonalityState()
        let failed = line(.failed("Nope"), hour: 8, day: 3, seed: 0, state: &failing) ?? ""
        TestSupport.expect(!failed.contains("Good morning"), "no greeting on failure")
    }

    private static func testMilestones() {
        for count in [10, 25, 50, 100, 250, 500, 1000, 2000, 5000] {
            TestSupport.expect(RioPersonality.isMilestone(count), "\(count) is a milestone")
        }
        for count in [0, 1, 9, 11, 99, 101, 999, 1001, 1500] {
            TestSupport.expect(!RioPersonality.isMilestone(count), "\(count) is not a milestone")
        }
        var state = RioPersonalityState()
        state.pendingMilestone = 100
        let spoken = line(.succeeded("Opened Notes"), seed: 2, state: &state) ?? ""
        TestSupport.expect(spoken.contains("100"), "milestone is announced: \(spoken)")
        TestSupport.expect(state.pendingMilestone == nil, "milestone is announced once")
    }

    private static func testLinesStayShort() {
        var state = RioPersonalityState()
        for seed in 0..<200 {
            let spoken = line(.succeeded("Opened Google Chrome"), hour: 8, day: seed, seed: UInt64(seed), state: &state) ?? ""
            TestSupport.expect(spoken.count <= 70, "too long (\(spoken.count)): \(spoken)")
        }
    }

    private static func testPunsAreRare() {
        var puns = 0
        let total = 400
        var state = RioPersonalityState()
        for seed in 0..<total {
            let spoken = line(.succeeded("Opened Notes"), day: 1, seed: UInt64(seed), state: &state) ?? ""
            if RioPersonality.punLines.contains(where: { spoken.contains($0) }) { puns += 1 }
        }
        TestSupport.expect(puns > 0, "puns do appear")
        TestSupport.expect(puns * 5 < total, "puns stay rare (\(puns) of \(total))")
    }

    private static func testSpeechTextPreparation() {
        TestSupport.expectEqual(RioSpeechText.prepare("  Opened   Chrome \n now "), "Opened Chrome now")
        TestSupport.expect(RioSpeechText.prepare("   ") == nil, "blank is nothing to say")
        TestSupport.expectEqual(RioSpeechText.prepare("**Done** and `ready`"), "Done and ready")
        TestSupport.expectEqual(
            RioSpeechText.prepare("See https://example.com/a/b?c=d for more"), "See a link for more"
        )
        TestSupport.expectEqual(RioSpeechText.prepare("Wait… ok"), "Wait. ok")
        TestSupport.expectEqual(RioSpeechText.prepare("# Heading\n- one\n- two"), "Heading. one. two")
    }

    private static func testSharedEntryPoint() {
        // The pinned API AppState calls: it must work without any injected state.
        TestSupport.expect(RioPersonality.spokenLine(for: .nothing, hour: 12) == nil, "nothing is silent")
        TestSupport.expect(RioPersonality.spokenLine(for: .unknown, hour: 12) != nil, "shrug is spoken")
    }
}
