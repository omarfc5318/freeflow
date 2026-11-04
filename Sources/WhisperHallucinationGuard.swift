import Foundation

/// Whisper invents text for quiet or noisy audio: subtitle credits, "Thanks for watching",
/// news-channel sign-offs, or a stray sentence ("We are hoping for a win"). Neither a typed
/// dictation nor a Rio command should ever come from that, so a transcript that is one of
/// these becomes "I didn't catch that" and nothing is typed or run.
///
/// Deliberately narrow: a bare "thank you" or "you" is real speech often enough that the
/// existing segment-metadata filter (TranscriptionResponseParser) owns those.
enum WhisperHallucinationGuard {
    /// Credit, sign-off and boilerplate phrases. They only count when the whole transcript is
    /// short, so a long dictation that mentions one of them is never dropped.
    private static let phrases: [String] = [
        "thanks for watching",
        "thank you for watching",
        "thank you for listening",
        "please subscribe",
        "like and subscribe",
        "don't forget to subscribe",
        "see you in the next video",
        "subtitles by",
        "subtitled by",
        "subtitles made by",
        "captions by",
        "transcribed by",
        "translated by",
        "amara.org",
        "mbc 뉴스",
        "mbc news",
        "字幕",
        "ご視聴ありがとうございました",
        "продолжение следует",
        "субтитры",
        "we are hoping for a win"
    ]

    /// Sound-effect captions Whisper writes for non-speech audio.
    private static let bracketed: [String] = ["[music]", "(music)", "[applause]", "(applause)", "[silence]", "♪"]

    /// How many extra words (beyond the phrase itself) a transcript may have and still count.
    private static let extraWordAllowance = 6

    static func isHallucination(_ transcript: String) -> Bool {
        let normalized = normalize(transcript)
        guard !normalized.isEmpty else { return false }
        for marker in bracketed where normalized == marker || normalized.hasPrefix(marker) && wordCount(normalized) <= 3 {
            return true
        }
        let words = wordCount(normalized)
        for phrase in phrases where normalized.contains(phrase) {
            if words <= wordCount(phrase) + extraWordAllowance { return true }
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
