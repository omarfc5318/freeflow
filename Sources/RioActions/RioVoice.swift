import AVFoundation
import Combine
import Foundation

/// Rio's voice: on-device AVSpeechSynthesizer, free, and silent whenever it would be rude.
/// The corner bear mirrors `isSpeaking` and `level` (his mouth).
///
/// Silent rule: never speaks while another app is using the microphone (a call) or while Rio
/// himself is recording, and never when the "Rio talks back" setting is off. The line still
/// shows on the bear's card; only the sound is skipped.
@MainActor final class RioVoice: ObservableObject {
    static let shared = RioVoice()

    @Published private(set) var isSpeaking = false
    /// 0...1 mouth level while speaking.
    @Published private(set) var level: Double = 0

    /// AppState sets this to report that Rio is recording right now (dictation or the action
    /// key), so he never talks into his own microphone. Defaults to "not recording".
    var isRioRecordingProvider: () -> Bool = { false }

    private let synthesizer = AVSpeechSynthesizer()
    private let delegateBridge = SpeechDelegate()
    private var currentUtterance: ObjectIdentifier?
    private var mouthTimer: Timer?
    private var lastWordAt = Date.distantPast
    private var lastWordLength = 5
    private var lastSilenceCheck = Date.distantPast
    private lazy var voice: AVSpeechSynthesisVoice? = Self.chooseVoice()

    private init() {
        delegateBridge.owner = self
        synthesizer.delegate = delegateBridge
    }

    /// Says `text`, replacing whatever he is saying. Does nothing when silence rules apply.
    func speak(_ text: String) {
        guard let prepared = RioSpeechText.prepare(text), canSpeak(prepared) else { return }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: prepared)
        utterance.voice = voice
        utterance.pitchMultiplier = RioVoiceStyle.pitch
        utterance.rate = RioVoiceStyle.rate
        utterance.volume = RioVoiceStyle.volume
        utterance.preUtteranceDelay = 0.05
        currentUtterance = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        currentUtterance = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        finishSpeaking()
    }

    private func canSpeak(_ text: String) -> Bool {
        RioVoicePolicy.shouldSpeak(
            text: text,
            isEnabled: RioVoiceDefaults.isEnabled,
            isOtherAppUsingMicrophone: MicUsageMonitor.isOtherAppUsingMicrophone(),
            isRioRecording: isRioRecordingProvider()
        )
    }

    // MARK: Voice choice

    /// The best installed English voice: premium or enhanced if present, else a friendly standard one.
    private static func chooseVoice() -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices().map { voice in
            RioVoiceCandidate(
                identifier: voice.identifier, name: voice.name, language: voice.language,
                quality: quality(of: voice)
            )
        }
        if let picked = RioVoiceChooser.pick(from: candidates),
           let voice = AVSpeechSynthesisVoice(identifier: picked.identifier) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: "en-US")
    }

    private static func quality(of voice: AVSpeechSynthesisVoice) -> RioVoiceQuality {
        switch voice.quality {
        case .premium: return .premium
        case .enhanced: return .enhanced
        default: return .standard
        }
    }

    // MARK: Delegate events (hopped onto the main actor by SpeechDelegate)

    fileprivate func utteranceStarted(_ id: ObjectIdentifier) {
        guard id == currentUtterance else { return }
        lastWordAt = Date()
        lastWordLength = 5
        isSpeaking = true
        startMouthTimer()
    }

    fileprivate func wordSpoken(_ id: ObjectIdentifier, length: Int) {
        guard id == currentUtterance else { return }
        lastWordAt = Date()
        lastWordLength = length
    }

    fileprivate func utteranceEnded(_ id: ObjectIdentifier) {
        guard id == currentUtterance else { return }
        currentUtterance = nil
        finishSpeaking()
    }

    private func finishSpeaking() {
        mouthTimer?.invalidate()
        mouthTimer = nil
        level = RioMouthLevel.restingLevel
        if isSpeaking { isSpeaking = false }
    }

    // MARK: Mouth

    private func startMouthTimer() {
        mouthTimer?.invalidate()
        lastSilenceCheck = Date()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMouth() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouthTimer = timer
    }

    private func updateMouth() {
        let now = Date()
        level = RioMouthLevel.level(
            secondsSinceWord: now.timeIntervalSince(lastWordAt),
            wordLength: lastWordLength,
            time: now.timeIntervalSinceReferenceDate
        )
        // A call or a recording that starts mid-sentence cuts him off.
        if now.timeIntervalSince(lastSilenceCheck) >= 0.5 {
            lastSilenceCheck = now
            if MicUsageMonitor.isOtherAppUsingMicrophone() || isRioRecordingProvider() { stopSpeaking() }
        }
    }

    // MARK: Bridge

    /// AVSpeechSynthesizer delegate callbacks arrive off the main actor; this hops them over.
    private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
        weak var owner: RioVoice?

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
            let id = ObjectIdentifier(utterance)
            Task { @MainActor [weak owner] in owner?.utteranceStarted(id) }
        }

        func speechSynthesizer(
            _ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
            utterance: AVSpeechUtterance
        ) {
            let id = ObjectIdentifier(utterance)
            let length = characterRange.length
            Task { @MainActor [weak owner] in owner?.wordSpoken(id, length: length) }
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            let id = ObjectIdentifier(utterance)
            Task { @MainActor [weak owner] in owner?.utteranceEnded(id) }
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            let id = ObjectIdentifier(utterance)
            Task { @MainActor [weak owner] in owner?.utteranceEnded(id) }
        }
    }
}
