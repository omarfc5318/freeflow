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

    /// The vocabulary as a plain comma-separated list ("Supabase, Groq, Claude."),
    /// trimmed to the token budget. A plain list measured as safe: a labelled prompt
    /// ("Vocabulary: …") made Whisper loop on noise-only audio.
    static func vocabularyPrompt(terms: [String]) -> String? {
        var seen = Set<String>()
        var accepted: [String] = []
        var tokens = 1 // the closing period
        for raw in terms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            let cost = estimatedTokens(term) + (accepted.isEmpty ? 0 : estimatedTokens(", "))
            guard tokens + cost <= promptTokenBudget else { break }
            accepted.append(term)
            tokens += cost
        }
        return accepted.isEmpty ? nil : accepted.joined(separator: ", ") + "."
    }

    /// An upper bound on Whisper's token count: 1.5 ASCII characters per token (measured
    /// English names and code identifiers run 2–2.8), and one token per byte otherwise
    /// (the tokenizer is byte-level).
    static func estimatedTokens(_ text: String) -> Int {
        var ascii = 0
        var other = 0
        for byte in text.utf8 {
            if byte < 128 { ascii += 1 } else { other += 1 }
        }
        return (ascii * 2 + 2) / 3 + other
    }

    /// The prompt fixes how names and jargon are spelled, but on audio with no speech it can
    /// make Whisper write the vocabulary itself or invent a sentence (measured on accidental
    /// taps), where the plain request returns a stock silence phrase. So: no speech in the plain
    /// transcript wins; otherwise the prompted one, unless it looped or failed.
    static func choose(
        prompted: String?,
        plain: String?,
        prompt: String,
        isSilencePhrase: (String) -> Bool
    ) -> Choice? {
        if let plain, plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSilencePhrase(plain) {
            return .plain
        }
        if let prompted, !promptDerailed(transcript: prompted, prompt: prompt) {
            return .prompted
        }
        return plain == nil ? nil : .plain
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
