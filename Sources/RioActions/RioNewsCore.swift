import Foundation

// News through a web-search-capable model on the owner's own AI provider. Foundation only.
// Privacy: only the topic and today's date are sent, to the provider the owner already set up.

enum RioNewsModel {
    /// A model that can browse: the owner's override, the configured model when its name says it
    /// searches, or Groq's compound-mini when the provider is Groq. Nil means news is unavailable.
    static func choose(configured: String, override: String, baseURL: String) -> String? {
        let custom = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        let model = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        if searches(model) { return model }
        let host = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased()
        return host == "api.groq.com" ? "groq/compound-mini" : nil
    }

    private static func searches(_ model: String) -> Bool {
        let name = model.lowercased()
        return ["compound", "search", "sonar", "online"].contains { name.contains($0) }
    }
}

enum RioNewsPrompt {
    static func system(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return """
        You are Rio, a teddy-bear assistant who reads the news aloud. Today is \(formatter.string(from: now)). \
        Search the web for the latest reliable news. Answer in at most three short spoken sentences, \
        plain text only: no markdown, no bullet points, no links, no source lists.
        """
    }

    static func user(topic: String?) -> String {
        let trimmed = topic?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "What are the top headlines right now?" : "What is the latest news about \(trimmed)?"
    }
}

enum RioNewsText {
    static let limit = 480

    /// A model reply made safe to speak: no markdown, links or bullets, and short.
    static func spoken(_ reply: String) -> String {
        var text = RioText.replacing(#"\[([^\]]*)\]\([^)]*\)"#, with: "$1", in: reply)
        text = RioText.replacing(#"https?://\S+"#, with: "", in: text)
        text = RioText.replacing(#"(?m)^\s*(?:[-*•]|\d+[.)])\s+"#, with: "", in: text)
        text = text.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "`", with: "")
        text = RioText.collapseWhitespace(text)
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        if let end = head.lastIndex(where: { ".!?".contains($0) }) { return String(head[...end]) }
        return head
    }
}

struct RioNewsService {
    static let unavailableMessage = "News needs an AI provider that can search the web, like Groq's compound models. Yours can't, so I can't read the news."

    /// Nil when no search-capable model is available.
    let llm: (any RioSmartLLMCompleting)?

    func answer(topic: String?, now: Date) async throws -> String {
        guard let llm else { throw RioOutsideError.unavailable(Self.unavailableMessage) }
        let reply = try await llm.complete(
            system: RioNewsPrompt.system(now: now), user: RioNewsPrompt.user(topic: topic), maxOutputTokens: 600
        )
        let spoken = RioNewsText.spoken(reply)
        guard !spoken.isEmpty else { throw RioOutsideError.badResponse }
        return spoken
    }
}
