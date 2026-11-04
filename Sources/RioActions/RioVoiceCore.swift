import Foundation

// Pure pieces of Rio's voice: which installed voice to use, when to stay silent, how the mouth
// moves and how he sounds. No AVFoundation here, so all of it is covered by the tests.

enum RioVoiceQuality: Int, Comparable {
    case standard = 0
    case enhanced = 1
    case premium = 2

    static func < (lhs: RioVoiceQuality, rhs: RioVoiceQuality) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct RioVoiceCandidate: Equatable {
    let identifier: String
    let name: String
    /// BCP 47, as AVSpeechSynthesisVoice reports it ("en-US").
    let language: String
    let quality: RioVoiceQuality
}

enum RioVoiceChooser {
    /// Friendly, clear voices Apple ships, best first. A premium or enhanced voice of any name
    /// still outranks a standard one of these.
    private static let preferredNames = ["Ava", "Allison", "Samantha", "Nicky", "Zoe", "Joelle", "Tessa", "Karen", "Moira", "Daniel"]
    /// The old robotic and novelty voices live in this namespace (Fred, Zarvox, Bubbles...).
    private static let classicVoicePrefix = "com.apple.speech.synthesis.voice."

    static func pick(from candidates: [RioVoiceCandidate]) -> RioVoiceCandidate? {
        candidates
            .filter { $0.language.lowercased().hasPrefix("en") && !$0.identifier.hasPrefix(classicVoicePrefix) }
            .min { rank($0) < rank($1) }
    }

    private static func rank(_ voice: RioVoiceCandidate) -> (Int, Int, Int, Int) {
        (
            -voice.quality.rawValue,
            regionRank(voice.language),
            preferredNames.firstIndex(of: voice.name) ?? preferredNames.count,
            // Stable tie-breaks so the choice never depends on list order.
            voice.name.stableOrder
        )
    }

    private static func regionRank(_ language: String) -> Int {
        switch language.replacingOccurrences(of: "_", with: "-").lowercased() {
        case "en-us": return 0
        case "en-gb": return 1
        case "en-au": return 2
        case "en-ie", "en-za", "en-in": return 3
        default: return 4
        }
    }
}

private extension String {
    /// An order-only integer from the name that is stable across runs (String.hashValue is not).
    var stableOrder: Int {
        unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 1_000_003 }
    }
}

enum RioVoiceDefaults {
    /// The "Rio talks back" toggle in Settings. On unless the user turns it off.
    static let enabledKey = "rio_talks_back_enabled"

    static var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true
    }
}

enum RioVoiceStyle {
    /// A little higher than a person, quick and bright: a small bear.
    static let pitch: Float = 1.22
    static let rate: Float = 0.53
    static let volume: Float = 0.9
}

enum RioVoicePolicy {
    /// Rio never talks over a call or over himself recording; the line still shows on the card.
    static func shouldSpeak(
        text: String, isEnabled: Bool, isOtherAppUsingMicrophone: Bool, isRioRecording: Bool
    ) -> Bool {
        isEnabled && !isOtherAppUsingMicrophone && !isRioRecording
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The corner bear's mouth, 0 (closed) to 1 (wide open). The synthesizer tells us when each word
/// starts; between words the mouth relaxes, and a quick flutter keeps it alive.
enum RioMouthLevel {
    static let restingLevel: Double = 0

    static func level(secondsSinceWord: TimeInterval, wordLength: Int, time: TimeInterval) -> Double {
        let envelope = exp(-max(0, secondsSinceWord) / 0.18)
        let size = 0.55 + 0.45 * Double(min(max(wordLength, 1), 10)) / 10
        let flutter = 0.75 + 0.25 * sin(time * 22)
        return min(1, max(0, envelope * size * flutter))
    }
}

/// Tells utterances apart by a token Rio mints, not by object identity (an `ObjectIdentifier`
/// can be reused once an utterance is freed, so a late callback could match a new line).
struct RioUtteranceTracker: Equatable {
    private(set) var current: UUID?

    /// Starts a new utterance; any earlier one stops counting.
    mutating func begin() -> UUID {
        let token = UUID()
        current = token
        return token
    }

    func isCurrent(_ token: UUID?) -> Bool { token != nil && token == current }

    /// True when `token` was the current utterance (and it is now finished).
    mutating func end(_ token: UUID?) -> Bool {
        guard isCurrent(token) else { return false }
        current = nil
        return true
    }

    mutating func cancel() { current = nil }
}

/// Backstop for a missing `didFinish`, so `isSpeaking` can never stay true.
enum RioSpeechWatchdog {
    /// Silence after the last spoken word that counts as "he is done" once the synthesizer
    /// itself reports it is no longer speaking.
    static let idleGrace: TimeInterval = 1.5
    /// A word is never more than this far apart from the next even for a slow voice.
    static let hardSilence: TimeInterval = 8

    /// A generous upper bound for how long `characterCount` characters can take to say.
    static func maxDuration(characterCount: Int) -> TimeInterval {
        10 + Double(characterCount) * 0.25
    }

    static func shouldForceFinish(
        synthesizerIsSpeaking: Bool, secondsSinceWord: TimeInterval, secondsSinceStart: TimeInterval, maxDuration: TimeInterval
    ) -> Bool {
        if secondsSinceStart > maxDuration { return true }
        if !synthesizerIsSpeaking { return secondsSinceWord > idleGrace }
        return secondsSinceWord > hardSilence
    }
}
