import Foundation

// Notion: append a paragraph to a page through an internal integration token. Foundation only.

enum RioNotionPageID {
    /// The 32-hex page id in a Notion URL, a bare id or a dashed id, as a dashed UUID. Nil otherwise.
    static func extract(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var path = trimmed
        if let end = path.firstIndex(where: { "?#".contains($0) }) { path = String(path[..<end]) }
        guard let groups = RioText.firstMatch(#"([0-9a-f]{32}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/?$"#, in: path),
              let found = groups[1] else { return nil }
        let hex = found.replacingOccurrences(of: "-", with: "").lowercased()
        let chars = Array(hex)
        func part(_ range: Range<Int>) -> String { String(chars[range]) }
        return [part(0..<8), part(8..<12), part(12..<16), part(16..<20), part(20..<32)].joined(separator: "-")
    }
}

enum RioNotionRequests {
    static let version = "2022-06-28"
    /// Notion rejects a rich-text object over 2000 characters.
    static let blockLimit = 1_900

    /// One paragraph block per `blockLimit` characters.
    static func blocks(for text: String) -> [[String: Any]] {
        let characters = Array(text)
        guard !characters.isEmpty else { return [] }
        return stride(from: 0, to: characters.count, by: blockLimit).map { start in
            let piece = String(characters[start..<min(start + blockLimit, characters.count)])
            return [
                "object": "block", "type": "paragraph",
                "paragraph": ["rich_text": [["type": "text", "text": ["content": piece]]]],
            ]
        }
    }

    private static func request(_ url: URL, method: String, token: String, body: [String: Any]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = RioOutsideHTTP.timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(version, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = RioOutsideHTTP.jsonBody(body)
        return request
    }

    /// Nil unless `pageID` is a dashed UUID, so the path can never be steered elsewhere.
    static func append(pageID: String, text: String, token: String) -> URLRequest? {
        guard RioNotionPageID.extract(from: pageID) == pageID.lowercased(),
              let url = URL(string: "https://api.notion.com/v1/blocks/\(pageID.lowercased())/children") else { return nil }
        return request(url, method: "PATCH", token: token, body: ["children": blocks(for: text)])
    }

    static func search(query: String, token: String) -> URLRequest {
        request(URL(string: "https://api.notion.com/v1/search")!, method: "POST", token: token, body: [
            "query": query, "filter": ["property": "object", "value": "page"], "page_size": 5,
        ])
    }
}

enum RioNotionParser {
    static func pageMatch(from data: Data) -> (id: String, title: String)? {
        guard let page = (RioOutsideHTTP.object(data)?["results"] as? [[String: Any]])?.first(where: { $0["object"] as? String == "page" }),
              let id = page["id"] as? String, let properties = page["properties"] as? [String: Any] else { return nil }
        for case let property as [String: Any] in properties.values where property["type"] as? String == "title" {
            let title = (property["title"] as? [[String: Any]])?.compactMap { $0["plain_text"] as? String }.joined() ?? ""
            return (id, title.isEmpty ? "Untitled" : title)
        }
        return (id, "Untitled")
    }
}

struct RioNotionService {
    static let noPageMessage = "Tell me which Notion page, or paste a default page link in Rio's settings, Integrations."

    let fetch: RioFetch
    let token: String
    /// A page link or id from Settings.
    let defaultPage: String?

    /// Appends `text` and returns the page's name for the spoken answer.
    func add(text: String, page spoken: String?) async throws -> String {
        let name = spoken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let id: String
        let title: String
        if !name.isEmpty {
            let found = try await RioOutsideHTTP.send(RioNotionRequests.search(query: name, token: token), using: fetch)
            guard let match = RioNotionParser.pageMatch(from: found) else { throw RioOutsideError.notFound(name) }
            (id, title) = match
        } else if let fallback = defaultPage.flatMap(RioNotionPageID.extract(from:)) {
            (id, title) = (fallback, "your Notion page")
        } else {
            throw RioOutsideError.notConfigured(Self.noPageMessage)
        }
        guard let request = RioNotionRequests.append(pageID: id, text: text, token: token) else { throw RioOutsideError.badResponse }
        _ = try await RioOutsideHTTP.send(request, using: fetch)
        return title
    }
}
