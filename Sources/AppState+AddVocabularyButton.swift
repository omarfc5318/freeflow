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

    /// Saves corrections learned from the user's edits and confirms them in the menu bar.
    /// Returns the terms that were new to the vocabulary.
    @discardableResult
    func learnVocabulary(from corrections: [LearnedCorrection]) -> [String] {
        learn(from: corrections).addedTerms
    }

    private static func isDictionaryWord(_ word: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound
    }

    /// True when `term` is already in the custom vocabulary (case-insensitive).
    func isCustomVocabularyTerm(_ term: String) -> Bool {
        let lowered = term.lowercased()
        return Self.vocabularyEntries(in: customVocabulary).contains { $0.lowercased() == lowered }
    }

    /// Adds the corrected words to the vocabulary and counts each mishearing; one fixed twice
    /// becomes a replacement rule, which also works when the word is already in the vocabulary.
    /// Always answers the owner: "Learned", or "Rio already knows" when nothing was new.
    @discardableResult
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
        guard let feedback = CorrectionFeedbackCore.feedback(
            corrections: corrections, addedTerms: outcome.addedTerms, newRules: outcome.newRules
        ) else { return outcome }

        statusText = feedback.status
        scheduleReadyStatusReset(after: 3, matching: [feedback.status])
        if !outcome.isEmpty { Task { @MainActor in VocabularyNotificationManager.shared.flashCheckmark() } }
        presentLearnFeedback(feedback.moment)
        return outcome
    }

    /// Shows the sign now, or holds it until the next dictation closes when one is starting or
    /// running (it would be wiped or dropped otherwise).
    private func presentLearnFeedback(_ moment: TeddyMoment) {
        if isDeferringLearnFeedback || isRecording || isTranscribing {
            deferredLearnMoment.defer(moment)
        } else {
            showTeddyMoment(moment)
        }
    }

    /// Once per app per session: tells the owner why edits in this app can't be learned.
    func explainUnwatchableApp(_ appName: String?) {
        guard let text = unwatchableAppNotices.noticeText(forApp: appName) else { return }
        overlayManager.showNotice(text)
    }
}
