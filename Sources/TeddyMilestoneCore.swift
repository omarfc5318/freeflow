import Foundation

/// A usage milestone the bear can celebrate.
struct TeddyMilestone: Equatable {
    let label: String
}

enum TeddyMilestoneCore {
    static let wordThresholds = [1_000, 5_000, 10_000, 25_000, 50_000, 100_000, 250_000, 500_000, 1_000_000]
    static let streakThresholds = [3, 7, 14, 30, 60, 100, 365]

    /// The milestone a dictation just crossed, or nil. A threshold counts once: only when the
    /// total was below it before and is at or above it now. If several were crossed, the
    /// highest of that kind is named, and a words milestone wins over a streak.
    static func crossed(before: UsageSummary, after: UsageSummary) -> TeddyMilestone? {
        if let words = wordThresholds.last(where: { before.totalWords < $0 && after.totalWords >= $0 }) {
            return TeddyMilestone(label: "\(formatted(words)) words")
        }
        if let days = streakThresholds.last(where: { before.currentStreak < $0 && after.currentStreak >= $0 }) {
            return TeddyMilestone(label: "\(days)-day streak")
        }
        return nil
    }

    private static func formatted(_ number: Int) -> String {
        let digits = String(number)
        var result = ""
        for (index, character) in digits.reversed().enumerated() {
            if index > 0, index % 3 == 0 { result.append(",") }
            result.append(character)
        }
        return String(result.reversed())
    }
}

/// When the bear shrugs ("Didn't catch that") instead of sending audio or showing an error.
enum TeddyShrug {
    /// Recordings shorter than this that fail to transcribe shrug instead of showing an error.
    static let shortRecordingSeconds: TimeInterval = 1.0

    /// True when a finished recording should not be sent at all. Edit Mode always sends.
    static func shouldSkipTranscription(
        isCommandMode: Bool, recordedSeconds: TimeInterval, heardSpeechSeconds: TimeInterval, peakDB: Float,
        whisperMode: Bool = false
    ) -> Bool {
        guard !isCommandMode else { return false }
        return !SpeechPresence.isWorthTranscribing(
            recordedSeconds: recordedSeconds, heardSpeechSeconds: heardSpeechSeconds, peakDB: peakDB,
            whisperMode: whisperMode
        )
    }

    /// True when a very short recording was rejected by the provider as unusable audio
    /// (HTTP 400): a shrug, not a red toast. Real problems such as a bad key (401/403), rate
    /// limits (429), server or network failures still show their error.
    static func shouldShrugOnError(recordedSeconds: TimeInterval, errorDescription: String) -> Bool {
        recordedSeconds < shortRecordingSeconds && errorDescription.contains("HTTP 400")
    }
}
