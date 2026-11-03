import Foundation

/// Tests for the Wispr-parity features: replacements, snippets, styles, usage stats and whisper boost.
/// All inputs are synthetic.
enum FeatureCoreTests {
    static func run() {
        testReplacementsMatchWholeWordsIgnoringCase()
        testReplacementsAdaptSentenceCase()
        testReplacementsDoNotChain()
        testLongerPhraseWins()
        testSnippetsExpandMidSentenceVerbatim()
        testPhraseSeparators()
        testStyleCategories()
        testStyleInstructions()
        testUsageTotalsAndSpeed()
        testUsageStreaks()
        testWordCount()
        testWhisperBoostRaisesQuietAudio()
        testWhisperBoostLeavesLoudAudio()
        testWhisperBoostCapsGainAndLimits()
        testRulesNeverApplyTwice()
        testPercentilePeakMatchesSortedRank()
    }

    /// Regression: "John" → "John Smith" once produced "John Smith Smith".
    private static func testRulesNeverApplyTwice() {
        let rules = DictationTextRules(
            replacements: TextExpansionCore.replacementRules([
                WordReplacement(heard: "john", replacement: "John Smith"),
                WordReplacement(heard: "clawed", replacement: "Claude")
            ]),
            snippets: [TextExpansionRule(phrase: "my link", output: "https://link.example", adaptsCase: false)],
            systemPrompt: ""
        )
        let before = rules.beforeCleanup("ask john and clawed for my link")
        TestSupport.expectEqual(before, "ask John Smith and Claude for my link")
        // Cleanup kept the text but reintroduced "clawed": only the idempotent rule runs again.
        TestSupport.expectEqual(
            rules.afterCleanup("Ask John Smith and clawed for my link.", cleanupRan: true),
            "Ask John Smith and Claude for https://link.example."
        )
        // Without cleanup (exact wording, or a failed request) replacements don't run twice.
        TestSupport.expectEqual(rules.afterCleanup(before, cleanupRan: false), "ask John Smith and Claude for https://link.example")
        TestSupport.expect(!TextExpansionRule(phrase: "john", output: "John Smith", adaptsCase: true).isIdempotent, "Self-containing rule")
        TestSupport.expect(TextExpansionRule(phrase: "clawed", output: "Claude", adaptsCase: true).isIdempotent, "Plain rule")
        TestSupport.expectEqual(DictationTextRules.none.afterCleanup("unchanged", cleanupRan: true), "unchanged")
    }

    private static func testPercentilePeakMatchesSortedRank() {
        let samples: [Int16] = (0..<5000).map { Int16(truncatingIfNeeded: ($0 * 7919) % 20000 - 10000) }
        let sorted = samples.map { abs(Double($0)) }.sorted()
        let expected = sorted[Int(Double(sorted.count - 1) * WhisperBoostCore.peakPercentile)] / 32768
        TestSupport.expectApproximatelyEqual(WhisperBoostCore.percentilePeak(samples), expected)
        TestSupport.expectEqual(WhisperBoostCore.percentilePeak([]), 0)
        TestSupport.expectApproximatelyEqual(WhisperBoostCore.percentilePeak([Int16.min]), 1)
    }

    private static func replace(_ text: String, _ pairs: [(String, String)]) -> String {
        TextExpansionCore.apply(
            TextExpansionCore.replacementRules(pairs.map { WordReplacement(heard: $0.0, replacement: $0.1) }),
            to: text
        )
    }

    // MARK: Replacements and snippets

    private static func testReplacementsMatchWholeWordsIgnoringCase() {
        TestSupport.expectEqual(replace("ask clawed about it", [("clawed", "Claude")]), "ask Claude about it")
        TestSupport.expectEqual(replace("ask CLAWED, then", [("clawed", "Claude")]), "ask Claude, then")
        TestSupport.expectEqual(replace("the clawedge stays", [("clawed", "Claude")]), "the clawedge stays")
        TestSupport.expectEqual(replace("no rules here", []), "no rules here")
        TestSupport.expectEqual(replace("", [("a", "b")]), "")
    }

    private static func testReplacementsAdaptSentenceCase() {
        TestSupport.expectEqual(replace("Gonna ship. I'm gonna rest", [("gonna", "going to")]), "Going to ship. I'm going to rest")
        TestSupport.expectEqual(replace("ping super base now", [("super base", "Supabase")]), "ping Supabase now")
    }

    private static func testReplacementsDoNotChain() {
        TestSupport.expectEqual(replace("a then b", [("a", "b"), ("b", "c")]), "b then c")
    }

    private static func testLongerPhraseWins() {
        TestSupport.expectEqual(
            replace("open next js docs", [("next", "NEXT"), ("next js", "Next.js")]),
            "open Next.js docs"
        )
    }

    private static func testSnippetsExpandMidSentenceVerbatim() {
        let rules = [TextExpansionRule(phrase: "my calendar link", output: "https://cal.example/omar", adaptsCase: false)]
        TestSupport.expectEqual(
            TextExpansionCore.apply(rules, to: "Sure, here's My calendar link. Pick any time."),
            "Sure, here's https://cal.example/omar. Pick any time."
        )
        TestSupport.expectEqual(TextExpansionCore.apply(rules, to: "my calendar"), "my calendar")
    }

    private static func testPhraseSeparators() {
        TestSupport.expectEqual(replace("use e-mail please", [("e mail", "email")]), "use email please")
        TestSupport.expectEqual(replace("C++ rocks", [("c++", "C++ (cpp)")]), "C++ (cpp) rocks")
    }

    // MARK: Styles

    private static func testStyleCategories() {
        typealias Core = DictationStyleCore
        TestSupport.expectEqual(Core.category(bundleIdentifier: "com.apple.MobileSMS", windowTitle: nil), .personal)
        TestSupport.expectEqual(Core.category(bundleIdentifier: "com.tinyspeck.slackmacgap", windowTitle: "x"), .work)
        TestSupport.expectEqual(Core.category(bundleIdentifier: "com.apple.mail", windowTitle: nil), .email)
        TestSupport.expectEqual(Core.category(bundleIdentifier: "com.google.Chrome", windowTitle: "Inbox (3) - someone - Gmail"), .email)
        TestSupport.expectEqual(Core.category(bundleIdentifier: "com.apple.Safari", windowTitle: "(2) WhatsApp"), .personal)
        TestSupport.expectEqual(Core.category(bundleIdentifier: "com.apple.Safari", windowTitle: "Slackware history - Wikipedia"), .other)
        TestSupport.expectEqual(Core.category(bundleIdentifier: "com.apple.Notes", windowTitle: "Gmail ideas"), .other)
        TestSupport.expectEqual(Core.category(bundleIdentifier: nil, windowTitle: "Gmail"), .other)
    }

    private static func testStyleInstructions() {
        TestSupport.expect(DictationStyleCore.instruction(for: .standard) == nil, "Standard adds nothing")
        TestSupport.expectEqual(DictationStyleCore.systemPrompt(base: "BASE", style: .standard), "BASE")
        let formal = DictationStyleCore.systemPrompt(base: "BASE", style: .formal)
        TestSupport.expect(formal.hasPrefix("BASE\n\nWRITING STYLE"), "Style is appended to the full base prompt")
        for style in DictationStyle.allCases where style != .standard {
            TestSupport.expect(
                DictationStyleCore.instruction(for: style)?.contains("Never add greetings") == true,
                "Every style forbids adding content"
            )
        }
    }

    // MARK: Usage stats

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func day(_ key: String) -> Date { UsageStatsCore.date(fromKey: key, calendar: utc)! }

    private static func testUsageTotalsAndSpeed() {
        var days: [String: DailyUsage] = [:]
        days = UsageStatsCore.recording(words: 60, seconds: 30, on: day("2026-11-01"), into: days, calendar: utc)
        days = UsageStatsCore.recording(words: 90, seconds: 30, on: day("2026-11-01"), into: days, calendar: utc)
        days = UsageStatsCore.recording(words: 0, seconds: 5, on: day("2026-11-01"), into: days, calendar: utc)
        days = UsageStatsCore.recording(words: 50, seconds: 60, on: day("2026-10-20"), into: days, calendar: utc)
        TestSupport.expectEqual(days["2026-11-01"], DailyUsage(words: 150, seconds: 60, sessions: 2))

        let summary = UsageStatsCore.summary(of: days, today: day("2026-11-01"), calendar: utc)
        TestSupport.expectEqual(summary.totalWords, 200)
        TestSupport.expectEqual(summary.totalSessions, 3)
        TestSupport.expectEqual(summary.wordsToday, 150)
        TestSupport.expectEqual(summary.wordsThisWeek, 150)
        TestSupport.expectEqual(summary.wordsPerMinute, 100)
        // 200 words typed at 40 wpm = 300 s, spoken in 120 s.
        TestSupport.expectApproximatelyEqual(summary.timeSavedSeconds, 180)

        let empty = UsageStatsCore.summary(of: [:], today: day("2026-11-01"), calendar: utc)
        TestSupport.expectEqual(empty.wordsPerMinute, 0)
        TestSupport.expectEqual(empty.currentStreak, 0)
    }

    private static func testUsageStreaks() {
        let active: Set<String> = ["2026-10-28", "2026-10-29", "2026-10-30", "2026-10-31", "2026-10-10", "2026-10-11"]
        TestSupport.expectEqual(UsageStatsCore.currentStreak(activeKeys: active, today: day("2026-10-31"), calendar: utc), 4)
        TestSupport.expectEqual(UsageStatsCore.currentStreak(activeKeys: active, today: day("2026-11-01"), calendar: utc), 4)
        TestSupport.expectEqual(UsageStatsCore.currentStreak(activeKeys: active, today: day("2026-11-02"), calendar: utc), 0)
        TestSupport.expectEqual(UsageStatsCore.longestStreak(activeKeys: active, calendar: utc), 4)
        TestSupport.expectEqual(UsageStatsCore.longestStreak(activeKeys: ["2026-12-31", "2027-01-01"], calendar: utc), 2)
    }

    private static func testWordCount() {
        TestSupport.expectEqual(UsageStatsCore.wordCount("Hi there, it's 5 o'clock — ok?"), 6)
        TestSupport.expectEqual(UsageStatsCore.wordCount("   "), 0)
    }

    // MARK: Whisper boost

    private static func sine(amplitude: Double, count: Int = 1600) -> [Int16] {
        (0..<count).map { Int16((amplitude * 32767 * sin(Double($0) * 0.2)).rounded()) }
    }

    private static func peak(_ samples: [Int16]) -> Double {
        Double(samples.map { abs(Int($0)) }.max() ?? 0) / 32767
    }

    private static func testWhisperBoostRaisesQuietAudio() {
        let result = WhisperBoostCore.boost(sine(amplitude: 0.05))
        TestSupport.expect(result.gainDecibels > 20 && result.gainDecibels < 26, "Quiet audio is raised by about 25 dB")
        TestSupport.expect(peak(result.samples) > 0.8 && peak(result.samples) < 1.0, "Peaks land near full scale without clipping")
    }

    private static func testWhisperBoostLeavesLoudAudio() {
        let loud = sine(amplitude: 0.9)
        let result = WhisperBoostCore.boost(loud)
        TestSupport.expectEqual(result.gainDecibels, 0)
        TestSupport.expectEqual(result.samples, loud)
        TestSupport.expectEqual(WhisperBoostCore.boost([]).samples, [])
        TestSupport.expectEqual(WhisperBoostCore.boost([0, 0, 0]).gainDecibels, 0)
    }

    private static func testWhisperBoostCapsGainAndLimits() {
        let nearSilence = WhisperBoostCore.boost(sine(amplitude: 0.0005))
        TestSupport.expectApproximatelyEqual(nearSilence.gainDecibels, 20 * log10(WhisperBoostCore.maxGain))
        TestSupport.expect(peak(nearSilence.samples) < 0.03, "Near-silence stays quiet")

        // One loud click among quiet speech is ignored when measuring, then softly limited.
        var withClick = sine(amplitude: 0.05, count: 4000)
        withClick[100] = 30000
        let limited = WhisperBoostCore.boost(withClick)
        TestSupport.expect(limited.gainDecibels > 20, "A single click does not prevent the boost")
        TestSupport.expect(limited.samples.allSatisfy { abs(Int($0)) < 32767 }, "Nothing hard-clips")
        TestSupport.expectApproximatelyEqual(WhisperBoostCore.softLimit(0.5), 0.5)
        TestSupport.expect(WhisperBoostCore.softLimit(-3) > -1, "Limiter never reaches full scale")
    }
}
