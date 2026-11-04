import Foundation

enum CorrectionFeedbackCoreTests {
    static func run() {
        testLearnedTermsShowLearned()
        testNewRuleShowsRule()
        testKnownWordShowsAlreadyKnown()
        testNothingToReportIsNil()
        testAlreadyKnownMomentShape()
        testLearnedStaysUpLongEnough()
        testDeferredMomentSurvivesUntilTaken()
        testNewerDeferredMomentWins()
        testAnchorableNeedsSelectedRange()
        testUnsupportedEditNoticeOncePerApp()
    }

    private static func fix(_ original: String, _ corrected: String) -> LearnedCorrection {
        LearnedCorrection(original: original, corrected: corrected)
    }

    private static func testLearnedTermsShowLearned() {
        let feedback = CorrectionFeedbackCore.feedback(
            corrections: [fix("nashwa", "Nashwa")], addedTerms: ["Nashwa"], newRules: []
        )
        TestSupport.expectEqual(feedback?.moment, .learned("Nashwa"))
        TestSupport.expectEqual(feedback?.status, "Added “Nashwa” to vocabulary")
    }

    private static func testNewRuleShowsRule() {
        let feedback = CorrectionFeedbackCore.feedback(
            corrections: [fix("super base", "Supabase")], addedTerms: [],
            newRules: [WordReplacement(heard: "super base", replacement: "Supabase")]
        )
        TestSupport.expectEqual(feedback?.moment, .learned("super base → Supabase"))
        TestSupport.expectEqual(feedback?.status, "Rio will now write “Supabase” when he hears “super base”")
    }

    private static func testKnownWordShowsAlreadyKnown() {
        let feedback = CorrectionFeedbackCore.feedback(
            corrections: [fix("cloud", "Claude")], addedTerms: [], newRules: []
        )
        TestSupport.expectEqual(feedback?.moment, .alreadyKnown("Claude"))
        TestSupport.expectEqual(feedback?.status, "Rio already knows “Claude”")
    }

    private static func testNothingToReportIsNil() {
        TestSupport.expect(
            CorrectionFeedbackCore.feedback(corrections: [], addedTerms: [], newRules: []) == nil,
            "No corrections means no sign"
        )
    }

    private static func testAlreadyKnownMomentShape() {
        let moment = TeddyMoment.alreadyKnown("Claude")
        TestSupport.expectEqual(moment.caption, "Rio already knows")
        TestSupport.expectEqual(moment.text, "Claude")
        TestSupport.expect(moment.seconds >= 3 && moment.seconds <= 4.5, "Readable but short")
    }

    private static func testLearnedStaysUpLongEnough() {
        TestSupport.expect(TeddyMoment.learned("x").seconds >= 3.5, "The owner never saw the 2.5 s sign")
    }

    private static func testDeferredMomentSurvivesUntilTaken() {
        var queue = DeferredMoment()
        TestSupport.expect(queue.take() == nil, "Starts empty")
        queue.defer(.learned("Nashwa"))
        TestSupport.expectEqual(queue.take(), .learned("Nashwa"))
        TestSupport.expect(queue.take() == nil, "Shown once")
    }

    private static func testNewerDeferredMomentWins() {
        var queue = DeferredMoment()
        queue.defer(.alreadyKnown("Claude"))
        queue.defer(.learned("Hala"))
        TestSupport.expectEqual(queue.take(), .learned("Hala"))
    }

    private static func testAnchorableNeedsSelectedRange() {
        TestSupport.expect(
            !AppTextInsertionCore.canAnchorDictation(role: "AXTextArea", subrole: nil, hasSelectedTextRange: false),
            "Warp's text area has no selected range, so the pasted text can never be located"
        )
        TestSupport.expect(
            AppTextInsertionCore.canAnchorDictation(role: "AXTextArea", subrole: nil, hasSelectedTextRange: true),
            "A text area with a caret is anchorable"
        )
        TestSupport.expect(
            !AppTextInsertionCore.canAnchorDictation(role: "AXTextField", subrole: "AXSecureTextField", hasSelectedTextRange: true),
            "Secure fields never are"
        )
    }

    private static func testUnsupportedEditNoticeOncePerApp() {
        var notices = UnwatchableAppNotices()
        TestSupport.expectEqual(notices.noticeText(forApp: "Warp"), "I can't see edits in Warp. Tap Right ⌘ to fix the last dictation.")
        TestSupport.expect(notices.noticeText(forApp: "Warp") == nil, "Once per app per session")
        TestSupport.expect(notices.noticeText(forApp: "Ghostty") != nil, "Another app gets its own")
        TestSupport.expect(notices.noticeText(forApp: nil) == nil, "No app name, no notice")
    }
}
