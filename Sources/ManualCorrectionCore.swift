import Foundation

/// Learns vocabulary from an explicit "Fix Last Dictation" edit, where the user retypes the
/// whole dictated text in an editor. Works in any app (terminals included) because it never
/// reads another app's text field. Reuses the automatic learner's session and filter, so both
/// paths accept and reject the same kinds of fixes.
enum ManualCorrectionCore {
    /// Spelling-level fixes between `original` and `edited`; empty when nothing qualifies.
    static func corrections(
        original: String,
        edited: String,
        isKnownWord: @escaping (String) -> Bool,
        isVocabularyTerm: @escaping (String) -> Bool = { _ in false }
    ) -> [LearnedCorrection] {
        let before = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let after = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !before.isEmpty, !after.isEmpty, before != after,
              var session = CorrectionLearningSession(
                  transcript: before, fieldValue: before,
                  caretLocation: before.utf16.count, isKnownWord: isKnownWord,
                  isVocabularyTerm: isVocabularyTerm
              ) else { return [] }
        // The whole field is the dictated span, so an edit inside it grows or shrinks that
        // span rather than crossing its boundary.
        guard session.observe(after) == .watching else { return [] }
        return uniqueByCorrectedTerm(session.corrections())
    }

    private static func uniqueByCorrectedTerm(_ corrections: [LearnedCorrection]) -> [LearnedCorrection] {
        var seen = Set<String>()
        return corrections.filter { seen.insert($0.corrected.lowercased()).inserted }
    }
}
