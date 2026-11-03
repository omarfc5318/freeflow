import Foundation

enum MishearingTallyCoreTests {
    private static func fix(_ original: String, _ corrected: String) -> LearnedCorrection {
        LearnedCorrection(original: original, corrected: corrected)
    }

    static func run() {
        testFirstFixOnlyCounts()
        testSecondFixCreatesReplacement()
        testKeyIsCaseInsensitive()
        testNoRuleWhenOneAlreadyExistsForHeard()
        testEmptyOrIdenticalOriginalIsNeverCounted()
        testDifferentPairsCountSeparately()
        testPairStartsOverAfterPromotion()
        testCapDropsOldest()
        testRoundTripsThroughJSON()
    }

    private static func testFirstFixOnlyCounts() {
        var tally = MishearingTally()
        TestSupport.expect(tally.record(fix("super base", "Supabase"), existingRules: []) == nil, "One fix is not enough")
        TestSupport.expectEqual(tally.entries.count, 1)
    }

    private static func testSecondFixCreatesReplacement() {
        var tally = MishearingTally()
        _ = tally.record(fix("super base", "Supabase"), existingRules: [])
        let rule = tally.record(fix("super base", "Supabase"), existingRules: [])
        TestSupport.expectEqual(rule?.heard, "super base")
        TestSupport.expectEqual(rule?.replacement, "Supabase")
        TestSupport.expectEqual(tally.entries.count, 0)
    }

    private static func testKeyIsCaseInsensitive() {
        var tally = MishearingTally()
        _ = tally.record(fix("Super Base", "Supabase"), existingRules: [])
        let rule = tally.record(fix("super base", "SUPABASE"), existingRules: [])
        TestSupport.expect(rule != nil, "Case differences count as the same mishearing")
    }

    private static func testNoRuleWhenOneAlreadyExistsForHeard() {
        var tally = MishearingTally()
        let existing = [WordReplacement(heard: "Super Base", replacement: "Superbase")]
        _ = tally.record(fix("super base", "Supabase"), existingRules: existing)
        let rule = tally.record(fix("super base", "Supabase"), existingRules: existing)
        TestSupport.expect(rule == nil, "A user's rule for the same phrase is never overridden")
        TestSupport.expectEqual(tally.entries.count, 0)
    }

    private static func testEmptyOrIdenticalOriginalIsNeverCounted() {
        var tally = MishearingTally()
        for _ in 0..<3 {
            TestSupport.expect(tally.record(fix("", "Supabase"), existingRules: []) == nil, "Empty original")
            TestSupport.expect(tally.record(fix("supabase", "Supabase"), existingRules: []) == nil, "Case-only")
        }
        TestSupport.expectEqual(tally.entries.count, 0)
    }

    private static func testDifferentPairsCountSeparately() {
        var tally = MishearingTally()
        _ = tally.record(fix("clawed", "Claude"), existingRules: [])
        TestSupport.expect(tally.record(fix("cloud", "Claude"), existingRules: []) == nil, "Different mishearing")
        TestSupport.expectEqual(tally.entries.count, 2)
    }

    private static func testPairStartsOverAfterPromotion() {
        var tally = MishearingTally()
        _ = tally.record(fix("clawed", "Claude"), existingRules: [])
        _ = tally.record(fix("clawed", "Claude"), existingRules: [])
        TestSupport.expect(tally.record(fix("clawed", "Claude"), existingRules: []) == nil, "Starts a new count")
    }

    private static func testCapDropsOldest() {
        var tally = MishearingTally()
        for index in 0..<(MishearingTally.maxEntries + 5) {
            _ = tally.record(fix("heard\(index)", "Word\(index)"), existingRules: [])
        }
        TestSupport.expectEqual(tally.entries.count, MishearingTally.maxEntries)
        TestSupport.expectEqual(tally.entries.first?.original, "heard5")
    }

    private static func testRoundTripsThroughJSON() {
        var tally = MishearingTally()
        _ = tally.record(fix("clawed", "Claude"), existingRules: [])
        let data = try? JSONEncoder().encode(tally)
        let decoded = data.flatMap { try? JSONDecoder().decode(MishearingTally.self, from: $0) }
        TestSupport.expectEqual(decoded, tally)
    }
}
