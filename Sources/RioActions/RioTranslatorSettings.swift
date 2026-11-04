import SwiftUI

/// Where the translator reads its switches and the transcription configuration.
enum RioTranslatorSettings {
    static let otherLanguageKey = "rio_translator_other_language"
    /// Conversation mode re-listens to Arabic commands with Whisper (sends only that command's audio).
    static let arabicConversationKey = "rio_arabic_conversation_commands"
    /// On unless turned off: without it, Arabic said after "Rio" hands-free reaches Rio as the
    /// English recognizer's guess. The action key already sends its command audio to Whisper.
    static let arabicConversationDefault = true

    /// "My other language": what English is translated into. Arabic unless changed.
    static var otherLanguage: RioTranslatorLanguage {
        RioTranslatorLanguage.named(UserDefaults.standard.string(forKey: otherLanguageKey)).flatMap {
            $0 == .english ? nil : $0
        } ?? .arabic
    }

    static var isArabicConversationEnabled: Bool {
        UserDefaults.standard.object(forKey: arabicConversationKey) as? Bool ?? arabicConversationDefault
    }

    /// The same transcription key, URL and model dictation uses (Groq Whisper by default), read
    /// fresh each time. Never logged.
    static func whisperConfig() -> RioWhisperConfig? {
        func stored(_ account: String) -> String {
            (AppSettingsStorage.load(account: account) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let key = stored("transcription_api_key").isEmpty ? stored("groq_api_key") : stored("transcription_api_key")
        let base = !stored("transcription_api_url").isEmpty ? stored("transcription_api_url")
            : (stored("api_base_url").isEmpty ? APIConfigurationSaveFlow.defaultBaseURL : stored("api_base_url"))
        guard !key.isEmpty, let endpoint = LanguageProbeCore.endpoint(baseURL: base) else { return nil }
        let configured = (UserDefaults.standard.string(forKey: "transcription_model") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = LanguageProbeCore.probeModel(
            baseURL: base, configuredModel: configured.isEmpty ? "whisper-large-v3" : configured
        )
        return RioWhisperConfig(endpoint: endpoint, apiKey: key, model: model)
    }
}

/// Settings for the live translator and Arabic commands. The lead embeds this in the Settings window.
struct RioTranslatorSettingsSection: View {
    @AppStorage(RioTranslatorSettings.otherLanguageKey) private var otherLanguage = RioTranslatorLanguage.arabic.name
    @AppStorage(RioTranslatorSettings.arabicConversationKey) private var arabicConversation = RioTranslatorSettings.arabicConversationDefault

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Translator and Arabic commands")
                .font(.headline)
            Picker("My other language", selection: $otherLanguage) {
                ForEach(RioTranslatorLanguage.all, id: \.name) { Text($0.name).tag($0.name) }
            }
            .frame(maxWidth: 280)
            Text("Say \"Rio, translate what is being said\" to start live subtitles next to Rio, and \"Rio, stop translating\" (or press Esc, or press Fn + Control + Option together) to stop. Anything that isn't English is shown in English; English is shown in your other language. Say \"Rio, say it\" to hear the last translation.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("While it is on, the sound around you is sent in short pieces to your transcription provider (Groq by default), and the text to your AI provider, to be transcribed and translated. A label on the subtitles says so the whole time. Nothing is saved. It pauses while Rio speaks, while you dictate or hold the action key, and while a command runs. It turns itself off after 10 quiet minutes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Understand Arabic commands in conversation mode (sends audio to your transcription provider)", isOn: $arabicConversation)
            Text("On by default, so Arabic commands (\"ريو افتح كروم\") work hands-free as they do with the action key. In conversation mode, when Rio hears \"Rio\" but not a command he knows, only the audio of that one command (about the last second and a half plus the command) is sent to your transcription provider to read it again. Everything else stays on this Mac, and plain English commands are never sent. Turn it off to keep conversation mode entirely on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
