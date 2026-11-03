import AppKit

// MARK: - Fix Last Dictation

extension AppState {
    /// Opens the floating editor with the last dictated text so the user can teach Rio the
    /// right spellings in any app, including ones whose text fields can't be watched.
    func fixLastDictation() {
        guard !lastDictatedText.isEmpty else {
            let status = "Nothing to fix yet"
            statusText = status
            scheduleReadyStatusReset(after: 3, matching: [status])
            return
        }
        FixLastDictationPanel.shared.show(original: lastDictatedText, appState: self)
    }

    /// Learns vocabulary from the user's edit. Returns false when nothing qualified, so the
    /// editor can explain and stay open.
    func teachRio(original: String, edited: String) -> Bool {
        let corrections = ManualCorrectionCore.corrections(
            original: original, edited: edited, isKnownWord: Self.spellCheckerKnowsWord
        )
        guard !corrections.isEmpty else { return false }
        learnVocabulary(from: corrections)
        return true
    }

    private static func spellCheckerKnowsWord(_ word: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound
    }
}
