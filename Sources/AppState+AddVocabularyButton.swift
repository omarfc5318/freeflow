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

    static let mishearingTallyStorageKey = "mishearing_tally"

    /// What one batch of corrections taught Rio.
    struct LearnOutcome {
        var addedTerms: [String] = []
        var newRules: [WordReplacement] = []
        var isEmpty: Bool { addedTerms.isEmpty && newRules.isEmpty }
    }

    /// Saves corrections learned from the user's edits and confirms them in the menu bar.
    /// Returns the terms that were new to the vocabulary.
    @discardableResult
    func learnVocabulary(from corrections: [LearnedCorrection]) -> [String] {
        learn(from: corrections).addedTerms
    }

    /// Adds the corrected words to the vocabulary and counts each mishearing; one fixed twice
    /// becomes a replacement rule, which also works when the word is already in the vocabulary.
    @discardableResult
    private static func isDictionaryWord(_ word: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound
    }

    func learn(from corrections: [LearnedCorrection]) -> LearnOutcome {
        var outcome = LearnOutcome()
        outcome.addedTerms = addVocabularyTerms(corrections.map(\.corrected))

        var tally: MishearingTally = Self.loadStoredJSON(forKey: Self.mishearingTallyStorageKey) ?? MishearingTally()
        var rules = wordReplacements
        for correction in corrections {
            if let rule = tally.record(correction, existingRules: rules, isKnownWord: Self.isDictionaryWord) {
                rules.append(rule)
                outcome.newRules.append(rule)
            }
        }
        Self.storeJSON(tally, forKey: Self.mishearingTallyStorageKey)
        if !outcome.newRules.isEmpty { wordReplacements = rules }
        guard !outcome.isEmpty else { return outcome }

        let status: String
        let label: String
        if let rule = outcome.newRules.first {
            status = "Rio will now write “\(rule.replacement)” when he hears “\(rule.heard)”"
            label = TeddyLearnedCard.label(for: outcome.newRules.map { "\($0.heard) → \($0.replacement)" })
        } else {
            status = "Added \(outcome.addedTerms.map { "“\($0)”" }.joined(separator: ", ")) to vocabulary"
            label = TeddyLearnedCard.label(for: outcome.addedTerms)
        }
        statusText = status
        scheduleReadyStatusReset(after: 3, matching: [status])
        Task { @MainActor in VocabularyNotificationManager.shared.flashCheckmark() }
        showTeddyMoment(.learned(label))
        return outcome
    }
}
