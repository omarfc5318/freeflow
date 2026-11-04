import Foundation

// Shared plumbing for builder S's outside-world services (weather, news, music, Notion, Canvas).
// Foundation only. Services take a `RioFetch`, so tests answer from fixtures and never open a socket.

struct RioHTTPResponse: Equatable {
    let status: Int
    let data: Data
}

typealias RioFetch = @Sendable (URLRequest) async throws -> RioHTTPResponse

enum RioOutsideError: Error, Equatable {
    /// A token or setting is missing or no longer valid; the message says what to do.
    case notConfigured(String)
    case http(Int)
    case badResponse
    /// The place, page or song was not found.
    case notFound(String)
    case unavailable(String)
}

enum RioOutsideHTTP {
    static let timeout: TimeInterval = 10

    /// The live network: an ephemeral session with no cookies, cache or credential storage.
    static let live: RioFetch = { request in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RioOutsideError.badResponse }
        return RioHTTPResponse(status: http.statusCode, data: data)
    }

    /// Runs `request` and returns the body for a 2xx answer; any other status throws `.http`.
    static func send(_ request: URLRequest, using fetch: RioFetch) async throws -> Data {
        let response = try await fetch(request)
        guard (200..<300).contains(response.status) else { throw RioOutsideError.http(response.status) }
        return response.data
    }

    static func get(_ url: URL?, headers: [String: String] = [:]) -> URLRequest? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// An https URL built from parts, so user text only ever travels as a percent-encoded query value.
    static func url(host: String, path: String, query: [(String, String)]) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        // URLComponents leaves "&", "+" and "=" alone in query values, so encode them here.
        if !query.isEmpty {
            components.percentEncodedQuery = query.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
        }
        return components.url
    }

    /// Percent-encodes everything except RFC 3986 unreserved characters.
    static func encode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// application/x-www-form-urlencoded body.
    static func formBody(_ pairs: [(String, String)]) -> Data {
        let text = pairs.map { name, value in "\(name)=\(encode(value))" }.joined(separator: "&")
        return Data(text.utf8)
    }

    static func jsonBody(_ object: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: object)
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
