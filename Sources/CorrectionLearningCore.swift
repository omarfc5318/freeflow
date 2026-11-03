import Foundation

/// A single word or short phrase the user fixed in freshly dictated text.
struct LearnedCorrection: Equatable {
    let original: String
    let corrected: String
}

/// Tracks the dictated span inside a text field while the user edits, then compares the
/// original dictated words with the final span once, so half-typed words and intermediate
/// typos are never learned. Field text never leaves this type; only corrected terms do.
struct CorrectionLearningSession {
    enum Outcome: Equatable {
        /// Keep watching.
        case watching
        /// The dictated span was deleted or merged with surrounding text; stop and learn
        /// from the last state where the span was still intact.
        case finished
    }

    /// A dictated word with surrounding punctuation stripped. Equality ignores sentence position.
    struct Word: Equatable {
        let text: String
        let startsSentence: Bool

        static func == (lhs: Word, rhs: Word) -> Bool { lhs.text == rhs.text }
    }

    static let maxPhraseWords = 3
    static let maxTermLength = 48
    static let maxSpanWords = 400
    /// Normalized edit distance above which a replacement reads as a rewrite, not a fix.
    static let maxDissimilarity = 0.5
    /// Looser cap for strong vocabulary evidence (names, jargon): speech models mishear these badly.
    static let maxStrongDissimilarity = 0.75

    private(set) var baseline: [UInt16]
    private(set) var span: Range<Int>
    /// The last state the caller declared stable (see `markSettled`); never a half-typed word.
    private var settledBaseline: [UInt16]
    private var settledSpan: Range<Int>
    /// True once an edit destroyed the dictated span (field sent, cleared or merged).
    private(set) var isSpanLost = false
    /// Consecutive polls the current intact state has been seen unchanged (1 = seen once).
    private var intactPollCount = 1
    /// Polls an intact state must survive before a field-clear (Send) may learn from it.
    static let minStablePolls = 2
    private let dictatedWords: [Word]
    private let isKnownWord: (String) -> Bool

    /// Finds the dictated text ending at the caret, or one whitespace before it (FreeFlow adds a
    /// space after sentence punctuation). Requiring the caret avoids latching onto an older phrase.
    init?(
        transcript: String, fieldValue: String, caretLocation: Int,
        isKnownWord: @escaping (String) -> Bool
    ) {
        let needle = Array(transcript.trimmingCharacters(in: .whitespacesAndNewlines).utf16)
        let value = Array(fieldValue.utf16)
        guard !needle.isEmpty, caretLocation >= needle.count, caretLocation <= value.count else { return nil }
        var ends = [caretLocation]
        if Self.isWhitespaceUnit(value[caretLocation - 1]) { ends.append(caretLocation - 1) }
        guard let end = ends.first(where: { end in
            end >= needle.count && value[(end - needle.count)..<end].elementsEqual(needle)
        }) else { return nil }
        self.baseline = value
        self.span = (end - needle.count)..<end
        self.settledBaseline = value
        self.settledSpan = (end - needle.count)..<end
        self.dictatedWords = Self.words(in: value[span])
        self.isKnownWord = isKnownWord
        guard dictatedWords.count <= Self.maxSpanWords else { return nil }
    }

    /// Moves the tracked span to follow a settled field value and marks it settled. Call only
    /// with values that have stopped changing, so the comparison never sees a half-typed word.
    mutating func observe(_ fieldValue: String) -> Outcome {
        let outcome = track(fieldValue)
        if outcome == .watching { markSettled() }
        return outcome
    }

    /// Follows the dictated span through a field value that may still be changing. Call on every
    /// polled change: incremental tracking is more accurate than diffing distant states, and it
    /// keeps the corrected text when the field is cleared right after (fix, then Send).
    /// On `.finished` the state stays at the last value where the span was still intact.
    mutating func track(_ fieldValue: String) -> Outcome {
        let current = Array(fieldValue.utf16)
        guard current != baseline else {
            if !isSpanLost { intactPollCount += 1 }
            return .watching
        }
        let delta = current.count - baseline.count

        guard let newSpan = trackedSpan(in: current, delta: delta), !newSpan.isEmpty else {
            isSpanLost = true
            return .finished
        }
        baseline = current
        span = newSpan
        intactPollCount = 1
        return .watching
    }

    /// Declares the tracked state stable (the value stopped changing).
    mutating func markSettled() {
        settledBaseline = baseline
        settledSpan = span
    }

    /// Net replacements between the original dictation and the span's current words.
    func corrections() -> [LearnedCorrection] {
        corrections(baseline: baseline, span: span)
    }

    /// What to learn when watching ends: the last intact state if the span was destroyed (that
    /// is the text the user corrected and sent) and that state was seen on at least
    /// `minStablePolls` consecutive polls; otherwise the last settled state, so a word still
    /// being typed at send, timeout or focus change ("Gro" for "Groq") is never learned.
    func finalCorrections() -> [LearnedCorrection] {
        let settled = corrections(baseline: settledBaseline, span: settledSpan)
        guard isSpanLost else { return settled }
        // Corrections also present in the settled state are stable by definition, so falling
        // back to the settled state keeps exactly those.
        return intactPollCount >= Self.minStablePolls ? corrections() : settled
    }

    private func corrections(baseline: [UInt16], span: Range<Int>) -> [LearnedCorrection] {
        let finalWords = Self.words(in: baseline[span])
        guard finalWords.count <= Self.maxSpanWords else { return [] }
        return Self.replacements(from: dictatedWords, to: finalWords).compactMap { candidate in
            isVocabularyCorrection(candidate.correction, startsSentence: candidate.startsSentence)
                ? candidate.correction : nil
        }
    }

    /// Returns where the dictated span sits in `current`, or nil if an edit crossed its boundary.
    private func trackedSpan(in current: [UInt16], delta: Int) -> Range<Int>? {
        let (prefix, suffix) = Self.commonAffixes(baseline, current)
        let changedStart = prefix
        let changedEnd = baseline.count - suffix
        // Built lazily: a field that shrank by more than the span (Send clearing text before the
        // dictation) would make an eager `grown` an inverted Range, which traps. Each return
        // path below only uses the range its own conditions keep valid.
        var moved: Range<Int> { (span.lowerBound + delta)..<(span.upperBound + delta) }
        var grown: Range<Int> { span.lowerBound..<(span.upperBound + delta) }

        // Typing glued onto the first or last dictated word ("Sara" → "Sarah") edits that word.
        if changedStart == changedEnd {
            if changedStart == span.upperBound,
               Self.isWordUnit(baseline[span.upperBound - 1]), Self.isWordUnit(current[changedStart]) {
                return grown
            }
            if changedStart == span.lowerBound,
               Self.isWordUnit(baseline[span.lowerBound]), Self.isWordUnit(current[changedStart + delta - 1]) {
                return grown
            }
        }

        // Prefer an alignment that keeps the edit outside the span: when repeated characters make
        // the edit position ambiguous ("BBob" → "Bob"), the span itself was not touched.
        if changedEnd <= span.lowerBound || Self.editFitsBefore(span.lowerBound, baseline, current) {
            return moved
        }
        if changedStart >= span.upperBound || Self.editFitsAfter(span.upperBound, baseline, current) {
            return span
        }
        guard changedStart >= span.lowerBound, changedEnd <= span.upperBound else { return nil }
        return grown
    }

    // MARK: Filtering

    /// Keeps spelling-level fixes of names and jargon; drops rewrites, typo and grammar fixes,
    /// and anything that looks like personal data.
    func isVocabularyCorrection(_ correction: LearnedCorrection, startsSentence: Bool) -> Bool {
        let corrected = correction.corrected
        guard corrected.count <= Self.maxTermLength,
              corrected.contains(where: { $0.isLetter }),
              corrected != correction.original,
              !Self.looksLikePersonalData(corrected) else { return false }
        let distance = Self.dissimilarity(correction.original, corrected)
        guard distance <= Self.maxStrongDissimilarity else { return false }

        // "so" → "So" or "paris" → "Paris" is sentence or proper-noun casing, not vocabulary.
        let isFirstLetterCaseFix = correction.original.lowercased() == corrected.lowercased()
            && correction.original.dropFirst() == corrected.dropFirst()
        if isFirstLetterCaseFix { return false }

        let correctedWords = corrected.split(separator: " ").map(String.init)
        var hasStrongShape = false
        for (index, word) in correctedWords.enumerated() {
            if Self.hasDistinctiveShape(word) { hasStrongShape = true }
            // A capital mid-sentence marks a name; at a sentence start it proves nothing.
            let isSentenceInitial = index == 0 && startsSentence
            if !isSentenceInitial, word.first?.isUppercase == true { hasStrongShape = true }
        }
        // Words the spell checker knows ("their" → "There") are grammar, not vocabulary.
        let hasUnknownWord = !correctedWords.allSatisfy { isKnownWord($0.lowercased()) }
        guard hasStrongShape || hasUnknownWord else { return false }
        if distance <= Self.maxDissimilarity { return true }

        // Past the general cap only strong evidence passes, and never a swap between two
        // sets of ordinary dictionary words ("I went" → "We left" is a rewrite).
        let originalWords = correction.original.split(separator: " ").map(String.init)
        let swapsKnownWords = !hasUnknownWord && originalWords.allSatisfy { isKnownWord($0.lowercased()) }
        return !swapsKnownWords
    }

    /// Inner capitals, digits or symbols: "iOS", "GPT4", "C++", "Next.js".
    private static func hasDistinctiveShape(_ word: String) -> Bool {
        word.dropFirst().contains(where: { $0.isUppercase })
            || word.contains(where: { $0.isNumber })
            || word.contains(where: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "-" })
    }

    private static let personalDataPattern = try? NSRegularExpression(
        pattern: #"@|://|www\.|\d{3,}|\.(com|net|org|edu|gov|io|co|me|us|uk)\b"#,
        options: [.caseInsensitive]
    )

    /// Emails, links, domains and long numbers (accounts, phones) are never learned.
    static func looksLikePersonalData(_ term: String) -> Bool {
        guard let personalDataPattern else { return true }
        return personalDataPattern.firstMatch(in: term, range: NSRange(term.startIndex..., in: term)) != nil
    }

    // MARK: Diffing

    private static let edgePunctuation = CharacterSet(charactersIn: ".,!?;:\"“”‘’()[]{}…")
    private static let sentenceEnders: Set<Character> = [".", "!", "?", "…"]

    static func words(in units: ArraySlice<UInt16>) -> [Word] {
        var startsSentence = true
        var result: [Word] = []
        for raw in String(decoding: units, as: UTF16.self).split(whereSeparator: { $0.isWhitespace }) {
            let text = String(raw).trimmingCharacters(in: edgePunctuation)
            if !text.isEmpty { result.append(Word(text: text, startsSentence: startsSentence)) }
            startsSentence = raw.last.map { sentenceEnders.contains($0) } ?? false
        }
        return result
    }

    struct Candidate {
        let correction: LearnedCorrection
        let startsSentence: Bool
    }

    /// Returns each run of replaced words between unchanged words, ignoring pure inserts/deletes
    /// and any run longer than a short phrase.
    static func replacements(from old: [Word], to new: [Word]) -> [Candidate] {
        let lengths = lcsTable(old, new)
        var candidates: [Candidate] = []
        var removed: [Word] = []
        var added: [Word] = []
        var i = 0
        var j = 0

        func flush() {
            if (1...maxPhraseWords).contains(removed.count), (1...maxPhraseWords).contains(added.count) {
                candidates.append(Candidate(
                    correction: LearnedCorrection(
                        original: removed.map(\.text).joined(separator: " "),
                        corrected: added.map(\.text).joined(separator: " ")
                    ),
                    startsSentence: added[0].startsSentence
                ))
            }
            removed = []
            added = []
        }

        while i < old.count || j < new.count {
            if i < old.count, j < new.count, old[i] == new[j] {
                flush()
                i += 1
                j += 1
            } else if j < new.count, i == old.count || lengths[i][j + 1] >= lengths[i + 1][j] {
                added.append(new[j])
                j += 1
            } else {
                removed.append(old[i])
                i += 1
            }
        }
        flush()
        return candidates
    }

    /// Suffix LCS lengths: `table[i][j]` is the LCS of `old[i...]` and `new[j...]`.
    private static func lcsTable(_ old: [Word], _ new: [Word]) -> [[Int]] {
        var table = Array(repeating: Array(repeating: 0, count: new.count + 1), count: old.count + 1)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        return table
    }

    private static func isWordUnit(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    private static func isWhitespaceUnit(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// True when everything from `boundary` on is unchanged, i.e. the edit fits wholly before it.
    private static func editFitsBefore(_ boundary: Int, _ a: [UInt16], _ b: [UInt16]) -> Bool {
        let tail = a.count - boundary
        return tail <= b.count && a[boundary...].elementsEqual(b[(b.count - tail)...])
    }

    /// True when everything before `boundary` is unchanged, i.e. the edit fits wholly after it.
    private static func editFitsAfter(_ boundary: Int, _ a: [UInt16], _ b: [UInt16]) -> Bool {
        boundary <= b.count && a[..<boundary].elementsEqual(b[..<boundary])
    }

    static func commonAffixes(_ a: [UInt16], _ b: [UInt16]) -> (prefix: Int, suffix: Int) {
        let limit = min(a.count, b.count)
        var prefix = 0
        while prefix < limit, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        return (prefix, suffix)
    }

    /// Levenshtein distance over lowercased letters and digits, normalized by the longer length.
    static func dissimilarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.lowercased().filter { $0.isLetter || $0.isNumber })
        let y = Array(b.lowercased().filter { $0.isLetter || $0.isNumber })
        let longest = max(x.count, y.count)
        guard longest > 0 else { return 0 }
        guard !x.isEmpty, !y.isEmpty else { return 1 }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var row = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = row
        }
        return Double(previous[y.count]) / Double(longest)
    }
}
