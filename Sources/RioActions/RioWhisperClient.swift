import Foundation

struct RioWhisperConfig: Equatable {
    let endpoint: URL
    let apiKey: String
    let model: String
}

enum RioWhisperError: Error, Equatable {
    case http(Int)
    case badResponse
}

/// One Whisper transcription of a short clip, with the language it detected. Audio and text are never logged.
enum RioWhisperClient {
    static let requestTimeout: TimeInterval = 8

    static func transcribe(
        pcm16: Data, sampleRate: Int, config: RioWhisperConfig,
        timeout: TimeInterval = requestTimeout,
        transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await LLMAPITransport.data(for: $0) }
    ) async throws -> (language: String?, text: String) {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: config.endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = LanguageProbeCore.multipartBody(
            wav: LanguageProbeCore.wav(pcm16: pcm16, sampleRate: sampleRate),
            model: config.model,
            responseFormat: TranscriptionService.responseFormat(forModel: config.model),
            boundary: boundary
        )
        let (data, response) = try await transport(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw RioWhisperError.http(status) }
        guard let parsed = LanguageProbeCore.parseResponse(data) else { throw RioWhisperError.badResponse }
        return (parsed.language, parsed.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
