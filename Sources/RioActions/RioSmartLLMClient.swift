import Foundation

/// Where Rio's smart actions talk to the user's configured LLM provider. Same key, base URL and
/// model as post-processing, same `LLMAPITransport`. Prompts and replies are never logged.
struct RioSmartLLMConfig: Equatable {
    let apiKey: String
    let baseURL: String
    let model: String
}

enum RioSmartLLMError: Error, Equatable {
    case notConfigured
    case http(Int)
    case badResponse
}

protocol RioSmartLLMCompleting: Sendable {
    func complete(system: String, user: String, maxOutputTokens: Int?) async throws -> String
}

struct RioSmartLLMClient: RioSmartLLMCompleting {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// A resolver answer is spoken, so a slow reply is worse than a short one.
    static let defaultTimeout: TimeInterval = 12

    private let config: @Sendable () -> RioSmartLLMConfig?
    private let timeout: TimeInterval
    private let transport: Transport

    init(
        config: @escaping @Sendable () -> RioSmartLLMConfig?,
        timeout: TimeInterval = RioSmartLLMClient.defaultTimeout,
        transport: @escaping Transport = { try await LLMAPITransport.data(for: $0) }
    ) {
        self.config = config
        self.timeout = timeout
        self.transport = transport
    }

    func complete(system: String, user: String, maxOutputTokens: Int?) async throws -> String {
        guard let config = config(), !config.apiKey.isEmpty, let request = try makeRequest(config, system, user, maxOutputTokens) else {
            throw RioSmartLLMError.notConfigured
        }
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else { throw RioSmartLLMError.badResponse }
        guard http.statusCode == 200 else { throw RioSmartLLMError.http(http.statusCode) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
              var content = message["content"] as? String else {
            throw RioSmartLLMError.badResponse
        }
        if ModelConfiguration.config(for: config.model).shouldStripThinkTags {
            content = ModelConfiguration.stripThinkTags(content)
        }
        return content
    }

    private func makeRequest(
        _ config: RioSmartLLMConfig, _ system: String, _ user: String, _ maxOutputTokens: Int?
    ) throws -> URLRequest? {
        var base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions"), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        var payload: [String: Any] = [
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        payload.merge(ModelConfiguration.nonContentRequestOptions(
            model: config.model,
            temperature: 0,
            defaultModel: "openai/gpt-oss-20b",
            defaultReasoningEffort: "low",
            defaultMaxCompletionTokens: 4_096
        )) { _, new in new }
        if let maxOutputTokens, payload["max_completion_tokens"] == nil {
            payload["max_completion_tokens"] = maxOutputTokens
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }
}
