import Foundation

/// Pure helpers for the speech-to-text request: the vocabulary hint sent as Whisper's
/// `prompt`, the rule for choosing between the transcripts made with and without it, and
/// which providers accept FLAC uploads.
enum TranscriptionRequestCore {
    /// Which of the two parallel transcripts to use.
    enum Choice: Equatable {
        case prompted
        case plain
    }

    /// Whisper reads at most 224 prompt tokens; stay safely under that.
    static let promptTokenBudget = 200
    /// Whisper's own threshold for repetitive, looping output, applied per window: measured
    /// normal speech peaks near 2.0 per 400-byte window, while loops score 10 or more.
    static let runawayCompressionRatio = 2.4
    /// Measured over windows because the ratio of a whole transcript grows with its length.
    private static let ratioWindowBytes = 400
    private static let ratioWindowStep = 200
    /// Below this length a compression ratio says nothing useful.
    private static let minimumBytesForRatio = 64
    /// Providers whose transcription endpoint documents FLAC uploads.
    private static let flacHosts: Set<String> = ["api.groq.com", "api.openai.com"]

    /// Why the plain transcript was used over the prompted one.
    enum PlainReason: Equatable {
        case silence
        case derailed
        case scriptMismatch
    }

    /// What happened to the vocabulary hint for one transcription.
    enum VocabularyOutcome: Equatable {
        case usedVocabulary
        case plainChosen(PlainReason)
        case promptedFailed
        case noPrompt
    }

    /// The prompt for one dictation. Over budget, the most useful terms win: names on
    /// screen for this dictation first, then the Dictionary newest-first (it is
    /// append-ordered, so learned words are at the end).
    static func vocabularyPrompt(vocabulary: [String], contextTerms: [String]) -> String? {
        vocabularyPrompt(terms: contextTerms + vocabulary.reversed())
    }

    /// Terms in priority order as a plain comma-separated list ("Supabase, Groq, Claude."),
    /// deduped case-insensitively and trimmed to the token budget. A plain list measured as
    /// safe: a labelled prompt ("Vocabulary: …") made Whisper loop on noise-only audio.
    static func vocabularyPrompt(terms: [String]) -> String? {
        var seen = Set<String>()
        var accepted: [String] = []
        var tokens = 1 // the closing period
        for raw in terms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            let cost = estimatedTokens(term) + (accepted.isEmpty ? 0 : estimatedTokens(", "))
            // A long term may not fit while a shorter, lower-priority one still does.
            guard tokens + cost <= promptTokenBudget else { continue }
            accepted.append(term)
            tokens += cost
        }
        return accepted.isEmpty ? nil : accepted.joined(separator: ", ") + "."
    }

    /// A safe estimate of Whisper's token count: 2 ASCII characters per token, rounded up
    /// (measured English names and code identifiers run 2–2.8; the 200 budget leaves margin
    /// under the 224 limit), and one token per byte otherwise (the tokenizer is byte-level).
    static func estimatedTokens(_ text: String) -> Int {
        var ascii = 0
        var other = 0
        for byte in text.utf8 {
            if byte < 128 { ascii += 1 } else { other += 1 }
        }
        return (ascii + 1) / 2 + other
    }

    /// The prompt fixes how names and jargon are spelled, but on audio with no speech it can
    /// make Whisper write the vocabulary itself or invent a sentence (measured on accidental
    /// taps), where the plain request returns a stock silence phrase. So: no speech in the plain
    /// transcript wins; otherwise the prompted one, unless it looped, echoed, failed, or came
    /// back in a different script from the speech (an English hint pulling Arabic or Hindi
    /// into Latin).
    static func choose(
        prompted: String?,
        plain: String?,
        prompt: String,
        isSilencePhrase: (String) -> Bool
    ) -> Choice? {
        guard let outcome = decide(prompted: prompted, plain: plain, prompt: prompt, isSilencePhrase: isSilencePhrase) else {
            return nil
        }
        return outcome == .usedVocabulary ? .prompted : .plain
    }

    /// Like `choose`, but says why. Nil when neither transcript is usable.
    static func decide(
        prompted: String?,
        plain: String?,
        prompt: String,
        isSilencePhrase: (String) -> Bool
    ) -> VocabularyOutcome? {
        if let plain, plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSilencePhrase(plain) {
            return .plainChosen(.silence)
        }
        guard let prompted else { return plain == nil ? nil : .promptedFailed }
        if promptDerailed(transcript: prompted, prompt: prompt) {
            return plain == nil ? nil : .plainChosen(.derailed)
        }
        if let plain, scriptMismatch(plain: plain, prompted: prompted) {
            return .plainChosen(.scriptMismatch)
        }
        return .usedVocabulary
    }

    /// The text appended to the history item's debug status.
    static func statusSuffix(outcome: VocabularyOutcome, prompt: String?) -> String {
        switch outcome {
        case .usedVocabulary:
            let count = prompt?.split(separator: ",").count ?? 0
            return " · Vocabulary: used (\(count) terms)"
        case .plainChosen(.silence): return " · Vocabulary: skipped — no speech"
        case .plainChosen(.derailed): return " · Vocabulary: skipped — prompted transcript derailed"
        case .plainChosen(.scriptMismatch): return " · Vocabulary: skipped — script mismatch"
        case .promptedFailed: return " · Vocabulary: skipped — prompted request failed"
        case .noPrompt: return " · Vocabulary: none"
        }
    }

    enum Script: Equatable {
        case latin, arabic, devanagari, other
    }

    /// The script most of the text's letters are written in, or nil when no script has a
    /// clear majority (or there are no letters).
    static func dominantScript(_ text: String) -> Script? {
        var counts: [Script: Int] = [:]
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            counts[script(of: scalar), default: 0] += 1
        }
        let total = counts.values.reduce(0, +)
        guard total > 0, let top = counts.max(by: { $0.value < $1.value }),
              top.value * 2 > total else { return nil }
        return top.key
    }

    private static func script(of scalar: Unicode.Scalar) -> Script {
        switch scalar.value {
        case 0x41...0x24F, 0x1E00...0x1EFF: return .latin
        case 0x600...0x6FF, 0x750...0x77F, 0x8A0...0x8FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return .arabic
        case 0x900...0x97F: return .devanagari
        default: return .other
        }
    }

    /// True when the plain transcript is mainly a non-Latin script and the prompted one is
    /// not mainly that same script. Code-switched speech that stays mostly in the spoken
    /// script on both sides is not a mismatch.
    static func scriptMismatch(plain: String, prompted: String) -> Bool {
        guard let plainScript = dominantScript(plain), plainScript != .latin else { return false }
        return dominantScript(prompted) != plainScript
    }

    /// True when a transcript made with the vocabulary prompt is unusable: the model looped
    /// (highly compressible text) or echoed the start of the prompt.
    static func promptDerailed(transcript: String, prompt: String) -> Bool {
        if compressionRatio(transcript) > runawayCompressionRatio { return true }
        let leadingTerms = prompt.split(separator: ",").prefix(3)
        guard leadingTerms.count == 3 else { return false }
        let echo = leadingTerms
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "."))) }
            .joined(separator: ", ")
        return transcript.range(of: echo, options: .caseInsensitive) != nil
    }

    /// The highest compression ratio over any window of the text.
    static func compressionRatio(_ text: String) -> Double {
        let data = Data(text.utf8)
        guard data.count > ratioWindowBytes else { return ratio(data) }
        return stride(from: 0, through: data.count - ratioWindowBytes, by: ratioWindowStep)
            .map { ratio(data.subdata(in: $0..<($0 + ratioWindowBytes))) }
            .max() ?? 0
    }

    private static func ratio(_ data: Data) -> Double {
        guard data.count >= minimumBytesForRatio,
              let compressed = try? (data as NSData).compressed(using: .zlib),
              compressed.length > 0 else { return 0 }
        return Double(data.count) / Double(compressed.length)
    }

    static func acceptsFLAC(host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return flacHosts.contains(host)
    }
}
