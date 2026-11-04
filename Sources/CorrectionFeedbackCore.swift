import Foundation

/// What one batch of corrections taught Rio.
struct LearnOutcome {
    var addedTerms: [String] = []
    var newRules: [WordReplacement] = []
    var isEmpty: Bool { addedTerms.isEmpty && newRules.isEmpty }
}

/// The status line and bear sign for a batch of corrections.
struct CorrectionFeedback: Equatable {
    let status: String
    let moment: TeddyMoment
}

enum CorrectionFeedbackCore {
    /// nil when there were no corrections. Corrections that taught nothing new (the word was
    /// already in the vocabulary) still get a sign, so the owner can tell Rio saw the edit.
    static func feedback(
        corrections: [LearnedCorrection], addedTerms: [String], newRules: [WordReplacement]
    ) -> CorrectionFeedback? {
        guard !corrections.isEmpty else { return nil }
        if let rule = newRules.first {
            return CorrectionFeedback(
                status: "Rio will now write “\(rule.replacement)” when he hears “\(rule.heard)”",
                moment: .learned(TeddyLearnedCard.label(for: newRules.map { "\($0.heard) → \($0.replacement)" }))
            )
        }
        if !addedTerms.isEmpty {
            return CorrectionFeedback(
                status: "Added \(quoted(addedTerms)) to vocabulary",
                moment: .learned(TeddyLearnedCard.label(for: addedTerms))
            )
        }
        let terms = corrections.map(\.corrected)
        return CorrectionFeedback(
            status: "Rio already knows \(quoted(terms))",
            moment: .alreadyKnown(TeddyLearnedCard.label(for: terms))
        )
    }

    private static func quoted(_ terms: [String]) -> String {
        terms.map { "“\($0)”" }.joined(separator: ", ")
    }
}

/// A bear sign held back while a dictation is starting or running, shown right after that
/// dictation closes. The latest sign wins.
struct DeferredMoment {
    private var moment: TeddyMoment?

    mutating func `defer`(_ newMoment: TeddyMoment) { moment = newMoment }

    mutating func take() -> TeddyMoment? {
        defer { moment = nil }
        return moment
    }
}

/// Apps whose text fields can't be read (terminals like Warp) get one explanation per session.
struct UnwatchableAppNotices {
    private var told = Set<String>()

    mutating func noticeText(forApp name: String?) -> String? {
        guard let name, !name.isEmpty, told.insert(name).inserted else { return nil }
        return "I can't see edits in \(name). Tap Right ⌘ to fix the last dictation."
    }
}
