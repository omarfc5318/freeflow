import Foundation

/// Conversation mode's second listen: reads one command's audio again with Whisper, which is
/// multilingual, when the on-device English recognizer's text didn't look like a command
/// (`RioCommandRecheckGate`). Only that command's audio (a few seconds, starting at "Rio") is
/// sent, only when online, configured and switched on in Settings. A slow or failed answer
/// falls back to the on-device text, so this never blocks a command.
enum RioCommandAudioRecheck {
    /// Longest wait before giving up and using the on-device text.
    static let timeout: TimeInterval = 3

    static func isAvailable(forOnDeviceText text: String) -> Bool {
        RioTranslatorSettings.isArabicConversationEnabled
            && RioCommandRecheckGate.shouldRecheck(onDeviceText: text)
            && NetworkMonitor.shared.isOnline
            && RioTranslatorSettings.whisperConfig() != nil
    }

    /// Whisper's text for the audio (PCM16 mono), or nil when it fails, times out or hears only noise.
    static func transcribe(pcm16: Data, sampleRate: Int) async -> String? {
        guard let config = RioTranslatorSettings.whisperConfig() else { return nil }
        guard let heard = try? await RioWhisperClient.transcribe(
            pcm16: pcm16, sampleRate: sampleRate, config: config, timeout: timeout
        ), !RioTranscriptFilter.isNoise(heard.text) else { return nil }
        return heard.text
    }
}
