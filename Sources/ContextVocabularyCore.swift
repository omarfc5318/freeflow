import Foundation

/// Names on screen for one dictation: the proper nouns in the app-context summary
/// ("replying to Siobhan Kelly about the Kubeflow launch"), added to the speech-to-text
/// vocabulary hint so the recognizer spells them as they appear on screen.
enum ContextVocabularyCore {
    /// Kept small so the user's own Dictionary always fits in the prompt first.
    static let maximumTerms = 12
    private static let maximumWordsPerTerm = 4
    /// Capitalized mid-sentence words that are not names.
    private static let ordinaryWords: Set<String> = ["i", "i'm", "i'll", "i've", "i'd", "ok", "okay"]
    private static let edgePunctuation = CharacterSet(charactersIn: "\"'“”‘’()[]{}<>,;:!?*_`")

    static func terms(fromSummary summary: String) -> [String] {
        guard !ContextInferenceFailure.isFailureSummary(summary) else { return [] }
        var terms: [String] = []
        var seen = Set<String>()
        for sentence in sentences(in: summary) {
            for term in properNounRuns(in: sentence) where seen.insert(term.lowercased()).inserted {
                terms.append(term)
                if terms.count == maximumTerms { return terms }
            }
        }
        return terms
    }

    /// Splits on sentence-ending punctuation followed by a space, so "Next.js" stays whole.
    private static func sentences(in text: String) -> [[Substring]] {
        var sentences: [[Substring]] = [[]]
        for word in text.split(whereSeparator: \.isWhitespace) {
            sentences[sentences.count - 1].append(word)
            if let last = word.last, ".!?".contains(last) { sentences.append([]) }
        }
        return sentences.filter { !$0.isEmpty }
    }

    /// Runs of consecutive capitalized words, skipping each sentence's first word,
    /// which is capitalized anyway. A comma or similar after a word ends its run.
    private static func properNounRuns(in sentence: [Substring]) -> [String] {
        var runs: [String] = []
        var current: [String] = []
        func finishRun() {
            if !current.isEmpty, current.count <= maximumWordsPerTerm {
                runs.append(current.joined(separator: " "))
            }
            current = []
        }
        for (index, raw) in sentence.enumerated() {
            let word = cleaned(raw)
            if index > 0, isProperNoun(word) {
                current.append(word)
            } else {
                finishRun()
            }
            if endsRun(raw) { finishRun() }
        }
        finishRun()
        return runs
    }

    private static func cleaned(_ raw: Substring) -> String {
        var word = String(raw).trimmingCharacters(in: edgePunctuation)
        while let last = word.last, ".".contains(last) { word.removeLast() }
        for suffix in ["'s", "’s"] where word.hasSuffix(suffix) {
            word.removeLast(suffix.count)
        }
        return word
    }

    private static func isProperNoun(_ word: String) -> Bool {
        guard word.count >= 2,
              word.contains(where: \.isUppercase),
              word.first?.isLetter == true,
              !ordinaryWords.contains(word.lowercased()),
              !word.contains("@"), !word.contains("/"), !word.contains("://") else { return false }
        return true
    }

    private static func endsRun(_ raw: Substring) -> Bool {
        guard let last = raw.last else { return false }
        return ",;:!?.)\"”".contains(last)
    }
}
