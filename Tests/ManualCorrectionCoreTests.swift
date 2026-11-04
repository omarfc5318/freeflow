import Foundation

enum ManualCorrectionCoreTests {
    /// Synthetic dictionary standing in for NSSpellChecker.
    private static let knownWords: Set<String> = [
        "we", "ship", "today", "the", "team", "is", "deploying", "to", "meet", "with", "at", "noon",
        "send", "it", "there", "their", "i", "think", "its", "ready", "and", "call", "me",
        "hello", "from", "john", "using", "for", "data", "sync", "app", "in", "terminal", "production"
    ]

    static func run() {
        testLearnsNameFix()
        testLearnsSuperBaseToSupabase()
        testLearnsMultipleFixesInOneEdit()
        testUnchangedTextLearnsNothing()
        testGrammarOnlyEditLearnsNothing()
        testEmptyOriginalLearnsNothing()
        testEmptyEditLearnsNothing()
        testIgnoresSurroundingWhitespaceChanges()
        testIgnoresRewrite()
        testDeduplicatesRepeatedFix()
        testFixAtEndOfText()
        testLearnsVocabularyTermOverKnownWord()
    }

    private static func testLearnsVocabularyTermOverKnownWord() {
        let result = ManualCorrectionCore.corrections(
            original: "the hollow app", edited: "the Hala app",
            isKnownWord: { (knownWords.union(["hollow", "hala"])).contains($0.lowercased()) },
            isVocabularyTerm: { $0.lowercased() == "hala" }
        )
        TestSupport.expectEqual(result, [fix("hollow", "Hala")])
    }

    private static func learn(_ original: String, _ edited: String) -> [LearnedCorrection] {
        ManualCorrectionCore.corrections(
            original: original, edited: edited, isKnownWord: { knownWords.contains($0.lowercased()) }
        )
    }

    private static func fix(_ original: String, _ corrected: String) -> LearnedCorrection {
        LearnedCorrection(original: original, corrected: corrected)
    }

    private static func testLearnsNameFix() {
        TestSupport.expectEqual(
            learn("Hello from halla in the app", "Hello from Hala in the app"),
            [fix("halla", "Hala")]
        )
    }

    private static func testLearnsSuperBaseToSupabase() {
        TestSupport.expectEqual(
            learn("the team is deploying to super base", "the team is deploying to Supabase"),
            [fix("super base", "Supabase")]
        )
    }

    private static func testLearnsMultipleFixesInOneEdit() {
        TestSupport.expectEqual(
            learn(
                "we ship to super base today and call halla",
                "we ship to Supabase today and call Hala"
            ),
            [fix("super base", "Supabase"), fix("halla", "Hala")]
        )
    }

    private static func testUnchangedTextLearnsNothing() {
        TestSupport.expectEqual(learn("we ship today", "we ship today"), [])
    }

    private static func testGrammarOnlyEditLearnsNothing() {
        TestSupport.expectEqual(learn("I think there ready", "I think their ready"), [])
        TestSupport.expectEqual(learn("send it, and call me", "Send it and call me"), [])
    }

    private static func testEmptyOriginalLearnsNothing() {
        TestSupport.expectEqual(learn("", "Hala"), [])
        TestSupport.expectEqual(learn("   \n", "Hala"), [])
    }

    private static func testEmptyEditLearnsNothing() {
        TestSupport.expectEqual(learn("hello from halla", ""), [])
    }

    private static func testIgnoresSurroundingWhitespaceChanges() {
        TestSupport.expectEqual(learn("hello from halla\n", "  hello from Hala "), [fix("halla", "Hala")])
        TestSupport.expectEqual(learn("we ship today", "we ship today \n"), [])
    }

    private static func testIgnoresRewrite() {
        TestSupport.expectEqual(learn("we ship today", "the team is deploying to production"), [])
    }

    private static func testDeduplicatesRepeatedFix() {
        TestSupport.expectEqual(
            learn("call halla and halla is ready", "call Hala and Hala is ready"),
            [fix("halla", "Hala")]
        )
    }

    private static func testFixAtEndOfText() {
        TestSupport.expectEqual(learn("sync wispr flo", "sync Wispr Flow"), [fix("wispr flo", "Wispr Flow")])
    }
}
