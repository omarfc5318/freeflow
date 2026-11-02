import AppKit

// MARK: - Add Vocabulary Button Extension

@MainActor
extension AppState {
    /// Pastes a word (or words) from the macOS pasteboard into the user's custom vocabulary.
    /// Returns the pasted text if successful, or nil otherwise.
    @discardableResult
    func pasteWordToVocabulary() -> String? {
        // Read text from pasteboard (macOS native clipboard API)
        // Check if there's any non-whitespace content to paste
        guard let pastedString = NSPasteboard.general.string(forType: .string),
              !pastedString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let added = addVocabularyTerms(Self.vocabularyEntries(in: pastedString))
        return added.isEmpty ? nil : added.joined(separator: ", ")
    }
}

// MARK: - Shared Vocabulary Helpers

extension AppState {
    /// Splits vocabulary text on the separators the settings field documents.
    static func vocabularyEntries(in text: String) -> [String] {
        text
            .split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Appends terms not already present (case-insensitive) and returns the ones added.
    @discardableResult
    func addVocabularyTerms(_ terms: [String]) -> [String] {
        var seen = Set(Self.vocabularyEntries(in: customVocabulary).map { $0.lowercased() })
        let newUniqueWords = terms.filter { seen.insert($0.lowercased()).inserted }
        guard !newUniqueWords.isEmpty else { return [] }

        let newWordsString = newUniqueWords.joined(separator: ", ")
        // We trim the block as a whole to safely append, but not the individual words themselves
        var currentVocab = customVocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentVocab.isEmpty {
            if !currentVocab.hasSuffix(",") {
                currentVocab += ","
            }
            currentVocab += "\n\(newWordsString)"
        } else {
            currentVocab = newWordsString
        }

        customVocabulary = currentVocab
        return newUniqueWords
    }

    /// Saves corrections learned from the user's edits and confirms them in the menu bar.
    func learnVocabulary(from corrections: [LearnedCorrection]) {
        let added = addVocabularyTerms(corrections.map(\.corrected))
        guard !added.isEmpty else { return }
        let status = "Added \(added.map { "“\($0)”" }.joined(separator: ", ")) to vocabulary"
        statusText = status
        scheduleReadyStatusReset(after: 3, matching: [status])
        Task { @MainActor in VocabularyNotificationManager.shared.flashCheckmark() }
    }
}
