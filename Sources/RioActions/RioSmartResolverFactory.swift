import Foundation

/// Where Rio's smart actions read their switches and the LLM configuration.
enum RioSmartSettings {
    static let enabledKey = "rio_smart_actions_enabled"
    private static let apiKeyAccount = "groq_api_key"
    private static let baseURLAccount = "api_base_url"
    private static let modelKey = "post_processing_model"
    /// Optional: a faster model on the same provider for understanding commands only (a spoken
    /// command must come back in well under the resolver's 6 s budget). Empty or unset means the
    /// post-processing model is used.
    static let resolverModelKey = "rio_smart_resolver_model"
    private static let defaultModel = "openai/gpt-oss-20b"

    /// On by default. Off means nothing is sent to the LLM for smart actions.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// The same key, base URL and model post-processing uses, read fresh on every call so a
    /// key added or changed in Settings applies without restarting. Never logged.
    /// The configuration for understanding commands: `llmConfig()` with the faster model, when one
    /// is configured.
    static func resolverConfig() -> RioSmartLLMConfig? {
        guard let base = llmConfig() else { return nil }
        let fast = (UserDefaults.standard.string(forKey: resolverModelKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fast.isEmpty else { return base }
        return RioSmartLLMConfig(apiKey: base.apiKey, baseURL: base.baseURL, model: fast)
    }

    static func llmConfig() -> RioSmartLLMConfig? {
        let key = (AppSettingsStorage.load(account: apiKeyAccount) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        let storedBase = (AppSettingsStorage.load(account: baseURLAccount) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (UserDefaults.standard.string(forKey: modelKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return RioSmartLLMConfig(
            apiKey: key,
            baseURL: storedBase.isEmpty ? APIConfigurationSaveFlow.defaultBaseURL : storedBase,
            model: model.isEmpty ? defaultModel : model
        )
    }
}

enum RioSmartResolverFactory {
    /// The LLM resolver for text the local parser couldn't place or only guessed at. Always
    /// returns one: whether smart actions are on, online and configured is checked when a command
    /// arrives, so the user gets a spoken reason instead of silence. The request itself times out
    /// with the resolver's 6 s budget.
    @MainActor static func make() -> RioSmartResolving? {
        RioSmartResolver(
            llm: RioSmartLLMClient(config: { RioSmartSettings.resolverConfig() }, timeout: RioSmartResolver.defaultTimeout),
            isEnabled: { RioSmartSettings.isEnabled },
            isOnline: { NetworkMonitor.shared.isOnline }
        )
    }
}
