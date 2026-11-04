import Foundation

/// Whisper invents text for quiet or noisy audio: subtitle credits, "Thanks for watching",
/// news-channel sign-offs, or a stray sentence ("We are hoping for a win"). Neither a typed
/// dictation nor a Rio command should ever come from that, so a transcript that is one of
/// these becomes "I didn't catch that" and nothing is typed or run.
///
/// Deliberately narrow, because a false hit throws away something the owner really said:
/// - it only applies when the recording held little speech (`SpeechEvidence`), the audio
///   Whisper invents these lines for;
/// - a sign-off must be (nearly) the whole transcript: "Thank you for watching the kids
///   yesterday" is kept;
/// - a credit ("subtitles by", "translated by") must open the transcript and be followed by a
///   short name only: "Captions by John" goes, "The book was translated by my professor" and
///   "Captions by the design team are due Friday" stay.
/// A bare "thank you" or "you" is real speech often enough that the segment-metadata filter
/// (TranscriptionResponseParser) owns those.
enum WhisperHallucinationGuard {
    /// What the level meter heard during the recording.
    struct SpeechEvidence: Equatable {
        let recordedSeconds: TimeInterval
        let heardSpeechSeconds: TimeInterval

        /// Below this much detected speech a recording can't hold a real sentence.
        static let minimumSpeechSeconds: TimeInterval = 1.0
        /// Or speech made up under this share of a longer recording (a TV in the background).
        static let minimumSpeechShare = 0.2

        /// True when the audio was mostly quiet or noise: the only audio the guard judges.
        var isMostlyQuiet: Bool {
            heardSpeechSeconds < Self.minimumSpeechSeconds
                || heardSpeechSeconds < recordedSeconds * Self.minimumSpeechShare
        }
    }

    /// Sign-offs and boilerplate: they count when they are the whole transcript, give or take a word.
    private static let signOffs: [String] = [
        "thanks for watching",
        "thank you for watching",
        "thank you for listening",
        "thanks for listening",
        "thank you so much for watching",
        "please subscribe",
        "please subscribe to my channel",
        "subscribe to my channel",
        "like and subscribe",
        "don't forget to subscribe",
        "see you in the next video",
        "mbc 뉴스",
        "mbc news",
        "字幕",
        "ご視聴ありがとうございました",
        "продолжение следует",
        "субтитры",
        "we are hoping for a win"
    ]

    /// Credit lines: they count only at the start, followed by a short name or a website.
    private static let credits: [String] = [
        "subtitles by", "subtitled by", "subtitles made by", "captions by", "transcribed by", "translated by"
    ]

    /// Domains Whisper copies from subtitle files; nobody dictates them in a short line.
    private static let creditDomains: [String] = ["amara.org"]

    /// Sound-effect captions Whisper writes for non-speech audio.
    private static let bracketed: [String] = ["[music]", "(music)", "[applause]", "(applause)", "[silence]", "♪"]

    /// Extra words a sign-off may carry ("Thanks for watching, everyone").
    private static let signOffExtraWords = 1
    /// Words a credit's name may have ("Captions by John Smith", "Subtitles by the Amara.org community").
    private static let creditNameWords = 3
    /// A line mentioning a credit domain counts up to this many words.
    private static let creditDomainLineWords = 8

    /// `evidence` nil means the level meter didn't run: the phrase rules alone decide.
    static func isHallucination(_ transcript: String, evidence: SpeechEvidence? = nil) -> Bool {
        if let evidence, !evidence.isMostlyQuiet { return false }
        let normalized = normalize(transcript)
        guard !normalized.isEmpty else { return false }
        let words = wordCount(normalized)
        for marker in bracketed where normalized == marker || normalized.hasPrefix(marker) && words <= 3 {
            return true
        }
        for phrase in signOffs where normalized.contains(phrase) {
            if words <= wordCount(phrase) + signOffExtraWords { return true }
        }
        for credit in credits where normalized.hasPrefix(credit + " ") {
            if words - wordCount(credit) <= creditNameWords { return true }
        }
        for domain in creditDomains where normalized.contains(domain) {
            if words <= creditDomainLineWords { return true }
        }
        return false
    }

    private static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
        let kept = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || "'.[]()♪".unicodeScalars.contains(scalar) { return Character(scalar) }
            return " "
        }
        return String(kept)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
