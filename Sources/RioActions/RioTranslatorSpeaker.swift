import AVFoundation
import Foundation

/// Speaks a translation in its own language with a system voice ("Rio, say it"). Separate from
/// `RioVoice` (which is English-only and follows the "Rio talks back" setting): saying a
/// translation is an explicit request, so it speaks even if Rio's chatter is off.
@MainActor final class RioTranslatorSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private(set) var isSpeaking = false
    private var current: ObjectIdentifier?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    enum Outcome: Equatable {
        case speaking
        case noVoice
    }

    func speak(_ text: String, in language: RioTranslatorLanguage) -> Outcome {
        guard let voice = Self.voice(for: language) else { return .noVoice }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        current = ObjectIdentifier(utterance)
        isSpeaking = true
        synthesizer.speak(utterance)
        return .speaking
    }

    func stop() {
        current = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
    }

    /// The best installed voice for the language: the exact locale, else any voice of the language.
    private static func voice(for language: RioTranslatorLanguage) -> AVSpeechSynthesisVoice? {
        if let exact = AVSpeechSynthesisVoice(language: language.voiceLocale) { return exact }
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(language.code) }
            .max { $0.quality.rawValue < $1.quality.rawValue }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(id) }
    }

    /// Only the utterance still current ends the speaking state (a replaced one cancels late).
    private func finished(_ id: ObjectIdentifier) {
        guard current == id else { return }
        current = nil
        isSpeaking = false
    }
}
