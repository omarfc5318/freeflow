import Foundation

/// The agent's model turn: the user's configured provider and key, with the window screenshot
/// attached when there is one. The screenshot goes to the app's context model (the one
/// dictation already uses for screenshots); without a picture, or if the provider rejects the
/// image, the same step is asked again as text only. Prompts and replies are never logged.
@MainActor
final class RioTaskVisionModel: RioTaskModelling {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private static let timeout: TimeInterval = 30
    private static let contextModelKey = "context_model"

    private let config: () -> RioSmartLLMConfig?
    private let transport: Transport

    init(
        config: @escaping () -> RioSmartLLMConfig? = { RioSmartSettings.llmConfig() },
        transport: @escaping Transport = { try await LLMAPITransport.data(for: $0) }
    ) {
        self.config = config
        self.transport = transport
    }

    func nextStep(system: String, user: String, imageDataURL: String?) async throws -> String {
        guard let config = config(), !config.apiKey.isEmpty else { throw RioSmartLLMError.notConfigured }
        if let imageDataURL {
            let stored = (UserDefaults.standard.string(forKey: Self.contextModelKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let visionModel = stored.isEmpty ? AppContextService.defaultContextModel : stored
            do {
                return try await complete(config, model: visionModel, system: system, user: user, image: imageDataURL)
            } catch RioSmartLLMError.http(let status) where [400, 404, 413, 415, 422].contains(status) {
                // The provider can't take the picture; carry on with the text outline alone.
            }
        }
        return try await complete(config, model: config.model, system: system, user: user, image: nil)
    }

    private func complete(
        _ config: RioSmartLLMConfig, model: String, system: String, user: String, image: String?
    ) async throws -> String {
        var base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions"), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { throw RioSmartLLMError.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.timeout
        let userContent: Any
        if let image {
            userContent = [
                ["type": "text", "text": user],
                ["type": "image_url", "image_url": ["url": image]],
            ]
        } else {
            userContent = user
        }
        var payload: [String: Any] = [
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userContent],
            ],
        ]
        payload.merge(ModelConfiguration.nonContentRequestOptions(
            model: model, temperature: 0, defaultModel: "openai/gpt-oss-20b",
            defaultReasoningEffort: "low", defaultMaxCompletionTokens: 1_024
        )) { _, new in new }
        payload["model"] = model
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else { throw RioSmartLLMError.badResponse }
        guard http.statusCode == 200 else { throw RioSmartLLMError.http(http.statusCode) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
              var content = message["content"] as? String else { throw RioSmartLLMError.badResponse }
        if ModelConfiguration.config(for: model).shouldStripThinkTags {
            content = ModelConfiguration.stripThinkTags(content)
        }
        return content
    }
}
