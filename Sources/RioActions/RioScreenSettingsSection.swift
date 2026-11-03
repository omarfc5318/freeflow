import SwiftUI

/// Where screen understanding reads its switch and its AI configuration (builder J).
enum RioScreenSettings {
    static let enabledKey = "rio_screen_understanding_enabled"
    static let visionModelKey = "rio_screen_vision_model"
    private static let apiKeyAccount = "groq_api_key"
    private static let baseURLAccount = "api_base_url"
    private static let contextModelKey = "context_model"
    private static let defaultContextModel = "qwen/qwen3.8-27b"

    /// On by default. Off means "what's on my screen" never captures or sends anything.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// The same key and base URL as dictation. The model is the screen-context model when it can
    /// read images, an optional override from Settings, or Llama 4 on Groq. Read fresh each time;
    /// never logged. When no vision model fits, the configured name is returned so the error
    /// message can say which model can't see.
    static func visionConfig() -> RioVisionConfig? {
        let key = (AppSettingsStorage.load(account: apiKeyAccount) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        let storedBase = (AppSettingsStorage.load(account: baseURLAccount) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = storedBase.isEmpty ? APIConfigurationSaveFlow.defaultBaseURL : storedBase
        let configured = (UserDefaults.standard.string(forKey: contextModelKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let override = UserDefaults.standard.string(forKey: visionModelKey) ?? ""
        let model = RioVisionModel.choose(configured: configured, override: override, baseURL: baseURL)
            ?? (configured.isEmpty ? defaultContextModel : configured)
        return RioVisionConfig(apiKey: key, baseURL: baseURL, model: model)
    }
}

/// Settings for screen understanding and click by voice. The lead embeds this in the Settings window.
struct RioScreenSettingsSection: View {
    @AppStorage(RioScreenSettings.enabledKey) private var enabled = true
    @AppStorage(RioScreenSettings.visionModelKey) private var visionModel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Screen questions and click by voice")
                .font(.headline)
            Toggle("Let Rio look at my screen when I ask", isOn: $enabled)
            Text("When you ask \"what's on my screen\" or \"what does this error mean\", Rio takes one picture of the window you're working in (never Rio's own windows, password managers or privacy settings), shrinks it, and sends it with your question to the AI provider you set up for dictation. The picture is used for that one answer and is never saved. Nothing is captured unless you ask.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if enabled {
                TextField("Vision model (optional)", text: $visionModel)
                    .textFieldStyle(.roundedBorder)
                Text("Leave empty to use your screen-context model. It must be able to read images; on Groq Rio falls back to Llama 4 Scout.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Off: \"what's on my screen\" won't capture or send anything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Click by voice (\"click Send\", \"check the second box\") reads button names through Accessibility on your Mac only. Nothing is sent anywhere. Rio never clicks in its own windows, System Settings privacy panes or password fields.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
