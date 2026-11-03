import Foundation

enum CorrectionLearningCoreTests {
    /// Synthetic dictionary standing in for NSSpellChecker (which, like this one, knows "john").
    private static let knownWords: Set<String> = [
        "meet", "with", "at", "noon", "the", "team", "is", "deploying", "to", "there", "their",
        "send", "sent", "it", "glad", "happy", "so", "we", "ship", "today", "paris", "react",
        "john", "bob", "said", "hi", "and", "email", "call", "me", "hello", "i", "went", "left", "home",
        "yesterday", "dough", "he"
    ]

    static func run() {
        testLearnsNameFix()
        testLearnsLowercaseJargon()
        testLearnsMultiWordFix()
        testLearnsNetResultNotIntermediateTypos()
        testIgnoresGrammarAndRewrites()
        testIgnoresSentenceInitialKnownWord()
        testIgnoresFirstLetterCaseFix()
        testIgnoresPersonalData()
        testEditsOutsideSpanOnlyShiftIt()
        testAmbiguousEditBeforeSpanStaysOutside()
        testFinishedKeepsLastIntactState()
        testRequiresDictationAtCaret()
        testAllowsOnlyWhitespaceBeforeCaret()
        testExtendingLastWord()
        testDissimilarity()
        testFixThenImmediateClearIsLearned()
        testHalfTypedWordThenFocusChangeIsNotLearned()
        testHalfTypedWordClearedByEnterIsNotLearned()
        testWordStableForTwoPollsThenClearedIsLearned()
        testSettledCorrectionSurvivesUnstableClear()
        testSettledStateIsUsedWhenWatchingTimesOut()
        testLooseCapForStrongVocabulary()
        testLooseCapStillRejectsRewrites()
    }

    private static func session(_ transcript: String, field: String, caret: Int? = nil) -> CorrectionLearningSession? {
        CorrectionLearningSession(
            transcript: transcript, fieldValue: field,
            caretLocation: caret ?? field.utf16.count,
            isKnownWord: { knownWords.contains($0.lowercased()) }
        )
    }

    private static func learned(_ transcript: String, field: String, edits: [String]) -> [LearnedCorrection] {
        guard var learner = session(transcript, field: field) else { return [] }
        for edit in edits { _ = learner.observe(edit) }
        return learner.corrections()
    }

    private static func fix(_ original: String, _ corrected: String) -> [LearnedCorrection] {
        [LearnedCorrection(original: original, corrected: corrected)]
    }

    private static func testLearnsNameFix() {
        TestSupport.expectEqual(
            learned("Meet with Jon at noon.", field: "Notes: Meet with Jon at noon.",
                    edits: ["Notes: Meet with John at noon."]),
            fix("Jon", "John")
        )
    }

    private static func testLearnsLowercaseJargon() {
        TestSupport.expectEqual(
            learned("the team is deploying to super base", field: "the team is deploying to super base",
                    edits: ["the team is deploying to supabase"]),
            fix("super base", "supabase")
        )
    }

    private static func testLearnsMultiWordFix() {
        TestSupport.expectEqual(
            learned("we ship whisper flow today", field: "we ship whisper flow today",
                    edits: ["we ship Wispr Flow today"]),
            fix("whisper flow", "Wispr Flow")
        )
    }

    private static func testLearnsNetResultNotIntermediateTypos() {
        TestSupport.expectEqual(
            learned("Meet Jon and Sara", field: "Meet Jon and Sara",
                    edits: ["Meet Jhon and Sara", "Meet John and Sara", "Meet John and Sarah"]),
            [LearnedCorrection(original: "Jon", corrected: "John"),
             LearnedCorrection(original: "Sara", corrected: "Sarah")]
        )
        TestSupport.expectEqual(
            learned("Meet Jon", field: "Meet Jon", edits: ["Meet Jhon", "Meet Jon"]),
            []
        )
    }

    private static func testIgnoresGrammarAndRewrites() {
        TestSupport.expectEqual(
            learned("send it to their team", field: "send it to their team", edits: ["send it to there team"]),
            []
        )
        TestSupport.expectEqual(learned("so happy today", field: "so happy today", edits: ["so glad today"]), [])
        TestSupport.expectEqual(
            learned("meet with the team at noon", field: "meet with the team at noon",
                    edits: ["Lunch Plans Moved Indefinitely Okay"]),
            []
        )
    }

    private static func testIgnoresSentenceInitialKnownWord() {
        TestSupport.expectEqual(
            learned("Their team is deploying", field: "Their team is deploying",
                    edits: ["There team is deploying"]),
            []
        )
        TestSupport.expectEqual(
            learned("Hi. Their team", field: "Hi. Their team", edits: ["Hi. There team"]),
            []
        )
    }

    private static func testIgnoresFirstLetterCaseFix() {
        TestSupport.expectEqual(
            learned("so we ship to paris", field: "so we ship to paris", edits: ["So we ship to Paris"]),
            []
        )
    }

    private static func testIgnoresPersonalData() {
        TestSupport.expectEqual(
            learned("email jon at example dot com", field: "email jon at example dot com",
                    edits: ["email jon@example.com"]),
            []
        )
        TestSupport.expectEqual(learned("call me at 5551", field: "call me at 5551", edits: ["call me at 5552"]), [])
        TestSupport.expect(CorrectionLearningSession.looksLikePersonalData("example.com"), "Domains are personal data")
        TestSupport.expect(!CorrectionLearningSession.looksLikePersonalData("Next.js"), "Framework names are not")
    }

    private static func testEditsOutsideSpanOnlyShiftIt() {
        var learner = session("Meet Jon.", field: "Hi. Meet Jon.", caret: 13)!
        TestSupport.expectEqual(learner.observe("Hello there. Meet Jon."), .watching)
        TestSupport.expectEqual(learner.observe("Hello there. Meet Jon. Bye"), .watching)
        TestSupport.expectEqual(learner.corrections(), [])
        TestSupport.expectEqual(learner.observe("Hello there. Meet John. Bye"), .watching)
        TestSupport.expectEqual(learner.corrections(), fix("Jon", "John"))
    }

    private static func testAmbiguousEditBeforeSpanStaysOutside() {
        // Dictation "Bob said hi" sits after a stray "B"; deleting that "B" must not touch the span.
        var learner = session("Bob said hi", field: "BBob said hi")!
        TestSupport.expectEqual(learner.observe("Bob said hi"), .watching)
        TestSupport.expectEqual(learner.span, 0..<11)
        TestSupport.expectEqual(learner.corrections(), [])
    }

    private static func testFinishedKeepsLastIntactState() {
        var learner = session("Meet Jon.", field: "Meet Jon.")!
        TestSupport.expectEqual(learner.observe("Meet John."), .watching)
        TestSupport.expectEqual(learner.observe(""), .finished)
        TestSupport.expectEqual(learner.corrections(), fix("Jon", "John"))

        var merged = session("Meet Jon.", field: "Hi. Meet Jon.")!
        TestSupport.expectEqual(merged.observe("Hi Jon."), .finished)
        TestSupport.expectEqual(merged.corrections(), [])
    }

    private static func testRequiresDictationAtCaret() {
        TestSupport.expect(
            session("Meet Jon.", field: "Meet Jon. Other text", caret: 20) == nil,
            "An identical phrase away from the caret must not be watched"
        )
        TestSupport.expect(session("   ", field: "anything") == nil, "Blank transcripts are ignored")
        TestSupport.expect(session("Meet", field: "Meet", caret: 9) == nil, "Out-of-range caret is ignored")
    }

    private static func testAllowsOnlyWhitespaceBeforeCaret() {
        TestSupport.expect(session("Meet Jon.", field: "Meet Jon. ") != nil, "Trailing space is allowed")
        TestSupport.expect(session("Meet Jon", field: "Meet Jonx") == nil, "Trailing letters are not")
    }

    private static func testExtendingLastWord() {
        TestSupport.expectEqual(
            learned("Meet Sara", field: "Meet Sara", edits: ["Meet Sarah"]),
            fix("Sara", "Sarah")
        )
    }

    private static func testDissimilarity() {
        TestSupport.expectApproximatelyEqual(CorrectionLearningSession.dissimilarity("Jon", "John"), 0.25)
        TestSupport.expectApproximatelyEqual(CorrectionLearningSession.dissimilarity("abc", "abc"), 0)
        TestSupport.expect(CorrectionLearningSession.dissimilarity("happy", "glad") > 0.5, "Unrelated words differ")
    }

    // MARK: Fix-then-send and half-typed words

    private static func testFixThenImmediateClearIsLearned() {
        var learner = session("Meet Jon.", field: "Meet Jon.")!
        TestSupport.expectEqual(learner.track("Meet John."), .watching)
        TestSupport.expectEqual(learner.track("Meet John."), .watching)
        TestSupport.expectEqual(learner.track(""), .finished)
        TestSupport.expect(learner.isSpanLost, "A cleared field loses the span")
        TestSupport.expectEqual(learner.finalCorrections(), fix("Jon", "John"))
    }

    private static func testHalfTypedWordClearedByEnterIsNotLearned() {
        var learner = session("Ask Grok.", field: "Ask Grok.")!
        _ = learner.track("Ask Gro.")
        TestSupport.expectEqual(learner.track(""), .finished)
        TestSupport.expectEqual(learner.finalCorrections(), [])
    }

    private static func testWordStableForTwoPollsThenClearedIsLearned() {
        var learner = session("Ask Grok.", field: "Ask Grok.")!
        _ = learner.track("Ask Groq.")
        _ = learner.track("Ask Groq.")
        TestSupport.expectEqual(learner.track(""), .finished)
        TestSupport.expectEqual(learner.finalCorrections(), fix("Grok", "Groq"))
    }

    private static func testSettledCorrectionSurvivesUnstableClear() {
        var learner = session("Ask Grok about Jon.", field: "Ask Grok about Jon.")!
        _ = learner.track("Ask Groq about Jon.")
        learner.markSettled()
        _ = learner.track("Ask Groq about John.")
        TestSupport.expectEqual(learner.track(""), .finished)
        TestSupport.expectEqual(learner.finalCorrections(), fix("Grok", "Groq"))
    }

    private static func testHalfTypedWordThenFocusChangeIsNotLearned() {
        var learner = session("Meet Jon.", field: "Meet Jon.")!
        TestSupport.expectEqual(learner.track("Meet Jhon."), .watching)
        TestSupport.expectEqual(learner.finalCorrections(), [])
    }

    private static func testSettledStateIsUsedWhenWatchingTimesOut() {
        var learner = session("Meet Jon and Sara", field: "Meet Jon and Sara")!
        _ = learner.track("Meet John and Sara")
        learner.markSettled()
        _ = learner.track("Meet John and Sar")
        TestSupport.expectEqual(learner.finalCorrections(), fix("Jon", "John"))
    }

    // MARK: Loosened filter

    private static func testLooseCapForStrongVocabulary() {
        TestSupport.expectEqual(
            learned("ship it to Hello today", field: "ship it to Hello today", edits: ["ship it to Hala today"]),
            fix("Hello", "Hala")
        )
        TestSupport.expectEqual(
            learned("we ship to super base", field: "we ship to super base", edits: ["we ship to Supabase"]),
            fix("super base", "Supabase")
        )
        TestSupport.expectEqual(
            learned("said hi to Dough he", field: "said hi to Dough he", edits: ["said hi to Dougie"]),
            fix("Dough he", "Dougie")
        )
        TestSupport.expectEqual(
            learned("we ship the app for ios", field: "we ship the app for ios", edits: ["we ship the app for iOS"]),
            fix("ios", "iOS")
        )
    }

    private static func testLooseCapStillRejectsRewrites() {
        TestSupport.expectEqual(
            learned("send it to their team", field: "send it to their team", edits: ["send it to there team"]),
            []
        )
        TestSupport.expectEqual(
            learned("yesterday I went home", field: "yesterday I went home", edits: ["yesterday We left home"]),
            []
        )
        TestSupport.expectEqual(
            learned("so we ship to paris", field: "so we ship to paris", edits: ["so we ship to Paris"]),
            []
        )
    }
}
