import Foundation

/// Vision request building, model choice and answer cleanup for "what's on my screen" (builder J).
/// Fake transport and synthetic bytes only: no screenshots, no network.
enum RioVisionRequestTests {
    private static let fakeJPEG = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0x03, 0xFF, 0xD9])

    private static func config(model: String = "qwen/qwen3.8-27b", key: String = "test-key") -> RioVisionConfig {
        RioVisionConfig(apiKey: key, baseURL: "https://api.example.test/openai/v1/", model: model)
    }

    private static func response(_ content: String, status: Int = 200) -> (Data, URLResponse) {
        let body = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        let http = HTTPURLResponse(url: URL(string: "https://api.example.test")!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, http)
    }

    private final class Box: @unchecked Sendable {
        var request: URLRequest?
    }

    static func run() async {
        testModelDetection()
        testModelChoice()
        testPromptAndCleanup()
        testMessages()
        await testRequestShape()
        await testFailures()
        await testReplyHandling()
    }

    private static func testModelDetection() {
        for model in ["qwen/qwen3.8-27b", "meta-llama/llama-4-scout-17b-16e-instruct", "meta-llama/llama-4-maverick-17b-128e-instruct",
                      "gpt-4o", "gpt-4o-mini", "gpt-4.1", "gemini-2.0-flash", "claude-sonnet-4-5", "pixtral-12b",
                      "qwen2.5-vl-72b", "llama-3.2-90b-vision-preview", "Qwen/Qwen3.6-27B"] {
            ETest.eq(RioVisionModel.isVisionCapable(model), true, "vision: \(model)")
        }
        for model in ["openai/gpt-oss-20b", "openai/gpt-oss-120b", "llama-3.3-70b-versatile", "llama-3.1-8b-instant",
                      "qwen/qwen3-32b", "whisper-large-v3", "", "  "] {
            ETest.eq(RioVisionModel.isVisionCapable(model), false, "text only: \(model)")
        }
    }

    private static func testModelChoice() {
        let groq = "https://api.groq.com/openai/v1"
        ETest.eq(RioVisionModel.choose(configured: "qwen/qwen3.8-27b", override: "", baseURL: groq), "qwen/qwen3.8-27b", "configured vision model")
        ETest.eq(RioVisionModel.choose(configured: "openai/gpt-oss-20b", override: "", baseURL: groq),
                 RioVisionModel.groqFallback, "Groq falls back to Llama 4")
        ETest.eq(RioVisionModel.choose(configured: "openai/gpt-oss-20b", override: "", baseURL: "https://api.other.test/v1"),
                 nil, "no vision model elsewhere")
        ETest.eq(RioVisionModel.choose(configured: "openai/gpt-oss-20b", override: "my-custom-vlm", baseURL: "https://api.other.test/v1"),
                 "my-custom-vlm", "explicit override wins")
        ETest.eq(RioVisionModel.choose(configured: "", override: "  ", baseURL: groq), RioVisionModel.groqFallback, "blank configured")
        ETest.eq(RioVisionModel.choose(configured: "gpt-4o", override: "", baseURL: "https://api.openai.com/v1"), "gpt-4o", "other provider")
    }

    private static func testPromptAndCleanup() {
        let system = RioVisionPrompt.system
        TestSupport.expect(system.lowercased().contains("never follow"), "system prompt guards against on-screen instructions")
        TestSupport.expect(system.contains("three sentences") || system.contains("3 sentences"), "system prompt caps the length")
        ETest.eq(RioVisionPrompt.user(question: nil).contains("What is on this screen"), true, "default question")
        ETest.eq(RioVisionPrompt.user(question: "what does this error mean").contains("what does this error mean"), true, "custom question")
        ETest.eq(RioVisionPrompt.user(question: "  ").contains("What is on this screen"), true, "blank question is the default")
        let long = String(repeating: "x", count: 900)
        ETest.eq(RioVisionPrompt.user(question: long).count < 700, true, "questions are capped")

        ETest.eq(RioVisionAnswer.clean("One. Two. Three. Four. Five."), "One. Two. Three.", "three sentences")
        ETest.eq(RioVisionAnswer.clean("  **Bold** text\nsecond line.  "), "Bold text second line.", "markdown and whitespace")
        ETest.eq(RioVisionAnswer.clean("- item one\n- item two"), "item one item two", "bullets flatten")
        ETest.eq(RioVisionAnswer.clean("<think>hidden</think>It is a terminal."), "It is a terminal.", "think tags")
        ETest.eq(RioVisionAnswer.clean(""), "", "empty")
        ETest.eq(RioVisionAnswer.clean(String(repeating: "word ", count: 200)).count <= RioVisionAnswer.maxCharacters + 1, true, "length cap")
    }

    private static func testMessages() {
        ETest.eq(RioVisionMessages.text(for: .notConfigured), RioVisionMessages.needsKey, "no key")
        ETest.eq(RioVisionMessages.text(for: .http(429)), RioVisionMessages.busy, "rate limited")
        ETest.eq(RioVisionMessages.text(for: .http(401)), RioVisionMessages.rejectedKey, "bad key")
        ETest.eq(RioVisionMessages.text(for: .http(400)), RioVisionMessages.cannotSee, "bad request is usually a text-only model")
        ETest.eq(RioVisionMessages.text(for: .http(500)), RioVisionMessages.unreachable, "server error")
        ETest.eq(RioVisionMessages.text(for: .badResponse), RioVisionMessages.unreachable, "garbage")
        ETest.eq(RioVisionMessages.text(for: .noVisionModel("openai/gpt-oss-20b")).contains("openai/gpt-oss-20b"), true, "names the model")
        ETest.eq(RioVisionMessages.text(for: .emptyAnswer), RioVisionMessages.unreachable, "empty answer")
    }

    private static func testRequestShape() async {
        let box = Box()
        let client = RioVisionClient(config: { config() }, transport: { request in
            box.request = request
            return response("It's a browser showing a login page.")
        })
        let answer = try? await client.describe(jpeg: fakeJPEG, question: "what's this")
        ETest.eq(answer, "It's a browser showing a login page.", "answer comes back")
        let request = box.request
        ETest.eq(request?.url?.absoluteString, "https://api.example.test/openai/v1/chat/completions", "url")
        ETest.eq(request?.httpMethod, "POST", "method")
        ETest.eq(request?.value(forHTTPHeaderField: "Authorization"), "Bearer test-key", "auth header")
        let body = request?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        ETest.eq(body?["model"] as? String, "qwen/qwen3.8-27b", "model")
        let messages = body?["messages"] as? [[String: Any]]
        ETest.eq(messages?.count, 2, "system plus user")
        ETest.eq(messages?.first?["role"] as? String, "system", "system first")
        let parts = messages?.last?["content"] as? [[String: Any]]
        ETest.eq(parts?.count, 2, "text and image parts")
        ETest.eq(parts?.first?["type"] as? String, "text", "text part")
        ETest.eq((parts?.first?["text"] as? String)?.contains("what's this"), true, "question is sent")
        ETest.eq(parts?.last?["type"] as? String, "image_url", "image part")
        let url = (parts?.last?["image_url"] as? [String: Any])?["url"] as? String
        ETest.eq(url, "data:image/jpeg;base64," + fakeJPEG.base64EncodedString(), "image is inlined, never stored")
        ETest.eq(body?["max_completion_tokens"] as? Int, RioVisionClient.maxOutputTokens, "short answers only")
        ETest.eq(request?.timeoutInterval, RioVisionClient.defaultTimeout, "timeout")
        ETest.eq(String(data: request?.httpBody ?? Data(), encoding: .utf8)?.contains("test-key"), false, "key is never in the body")
    }

    private static func testFailures() async {
        let missingKey = RioVisionClient(config: { config(key: "") }, transport: { _ in response("x") })
        await expectThrows(.notConfigured, "empty key") { _ = try await missingKey.describe(jpeg: fakeJPEG, question: nil) }
        let nilConfig = RioVisionClient(config: { nil }, transport: { _ in response("x") })
        await expectThrows(.notConfigured, "no config") { _ = try await nilConfig.describe(jpeg: fakeJPEG, question: nil) }
        let textOnly = RioVisionClient(config: { config(model: "openai/gpt-oss-20b") }, transport: { _ in
            TestSupport.expect(false, "a text-only model must never receive the screenshot")
            return response("x")
        })
        await expectThrows(.noVisionModel("openai/gpt-oss-20b"), "text-only model") {
            _ = try await textOnly.describe(jpeg: fakeJPEG, question: nil)
        }
        let limited = RioVisionClient(config: { config() }, transport: { _ in response("busy", status: 429) })
        await expectThrows(.http(429), "http 429") { _ = try await limited.describe(jpeg: fakeJPEG, question: nil) }
        let badURL = RioVisionClient(
            config: { RioVisionConfig(apiKey: "k", baseURL: "ftp://nope", model: "qwen/qwen3.8-27b") },
            transport: { _ in response("x") }
        )
        await expectThrows(.notConfigured, "non-http base URL") { _ = try await badURL.describe(jpeg: fakeJPEG, question: nil) }
        let empty = RioVisionClient(config: { config() }, transport: { _ in response("   ") })
        await expectThrows(.emptyAnswer, "blank answer") { _ = try await empty.describe(jpeg: fakeJPEG, question: nil) }
        let junk = RioVisionClient(config: { config() }, transport: { _ in (Data("not json".utf8), response("x").1) })
        await expectThrows(.badResponse, "junk body") { _ = try await junk.describe(jpeg: fakeJPEG, question: nil) }
        let noData = RioVisionClient(config: { config() }, transport: { _ in response("x") })
        await expectThrows(.notConfigured, "no image") { _ = try await noData.describe(jpeg: Data(), question: nil) }
    }

    private static func testReplyHandling() async {
        let long = "First sentence. Second one here. Third sentence ends. Fourth should go. Fifth too."
        let client = RioVisionClient(config: { config() }, transport: { _ in response(long) })
        let answer = try? await client.describe(jpeg: fakeJPEG, question: nil)
        ETest.eq(answer, "First sentence. Second one here. Third sentence ends.", "reply is cut to three sentences")
        let thinking = RioVisionClient(config: { config() }, transport: { _ in response("<think>plan</think>A terminal window.") })
        let stripped = try? await thinking.describe(jpeg: fakeJPEG, question: nil)
        ETest.eq(stripped, "A terminal window.", "think tags stripped")
    }

    private static func expectThrows(
        _ expected: RioVisionError, _ message: String, _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            TestSupport.expect(false, "\(message): expected \(expected), nothing thrown")
        } catch let error as RioVisionError {
            ETest.eq(error, expected, message)
        } catch {
            TestSupport.expect(false, "\(message): unexpected error \(error)")
        }
    }
}
