import Foundation

enum LLMAPITransport {
    private static func makeEphemeralSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        // URLSession's resource timeout is session-scoped, while each caller
        // already puts its configured timeout on the URLRequest. Keep both
        // session timers aligned with that request instead of applying one
        // global timeout to every provider and operation.
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
    }

    /// One long-lived session for every provider call, so the TCP+TLS connection (and its
    /// HTTP/2 stream pool) opened when recording starts is still warm when the audio is
    /// uploaded and again for cleanup. A session per request paid DNS, TCP and TLS each time.
    /// Per-request timeouts still come from `URLRequest.timeoutInterval`, and every caller
    /// also races its own deadline, so the resource timeout is only a backstop.
    private static let sharedSession = makeEphemeralSession(timeout: 3600)

    /// A connection that went stale while idle fails with this; one retry on a brand-new
    /// connection is safe (and is exactly what every request used to get).
    static func isStaleConnectionError(_ error: Error) -> Bool {
        (error as? URLError)?.code == .networkConnectionLost
    }

    /// Runs `operation` on the shared (warm) session; if the reused connection turns out to be
    /// dead, repeats it once on a fresh session.
    private static func withStaleConnectionRetry(
        timeout: TimeInterval,
        _ operation: (URLSession) async throws -> (Data, URLResponse)
    ) async throws -> (Data, URLResponse) {
        do {
            return try await operation(sharedSession)
        } catch where isStaleConnectionError(error) && !Task.isCancelled {
            let session = makeEphemeralSession(timeout: timeout)
            defer { session.finishTasksAndInvalidate() }
            return try await operation(session)
        }
    }

    private static func timeout(for request: URLRequest) -> TimeInterval {
        let requestTimeout = request.timeoutInterval
        guard requestTimeout.isFinite, requestTimeout > 0 else {
            return 60
        }
        return requestTimeout
    }

    static func data(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        try await withStaleConnectionRetry(timeout: timeout(for: request)) { session in
            try await data(for: request, using: session)
        }
    }

    static func data(
        for request: URLRequest,
        cache: TemperatureCapabilityCache
    ) async throws -> (Data, URLResponse) {
        try await withStaleConnectionRetry(timeout: timeout(for: request)) { session in
            try await data(for: request, using: session, cache: cache)
        }
    }

    static func data(
        for request: URLRequest,
        using session: URLSession
    ) async throws -> (Data, URLResponse) {
        try await data(for: request, using: session, cache: TemperatureCapabilityCache.shared)
    }

    static func data(
        for request: URLRequest,
        using session: URLSession,
        cache: TemperatureCapabilityCache
    ) async throws -> (Data, URLResponse) {
        let observation = cache.beginObservation(for: request)
        let capability = observation.capability
        let outgoing = capability == .unsupported ? requestWithoutTemperature(request) ?? request : request
        let result = try await session.data(for: outgoing)
        if let response = result.1 as? HTTPURLResponse, response.statusCode == 200,
           isValidCompletionResponse(result.0), payloadHasTemperature(outgoing) {
            cache.record(.supported, for: outgoing, observation: observation)
        }
        guard capability != .unsupported,
              let response = result.1 as? HTTPURLResponse,
              response.statusCode == 400,
              let retry = requestWithoutUnsupportedTemperature(outgoing, errorData: result.0) else {
            return result
        }
        cache.record(.unsupported, for: outgoing, observation: observation)
        let retried = try await session.data(for: retry)
        return retried
    }

    private static func payloadHasTemperature(_ request: URLRequest) -> Bool {
        guard let body = request.httpBody,
              let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return payload["temperature"] != nil
    }

    private static func isValidCompletionResponse(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]], !choices.isEmpty,
              let message = choices[0]["message"] as? [String: Any] else { return false }
        return message["content"] != nil || message["reasoning"] != nil
    }

    private static func requestWithoutTemperature(_ request: URLRequest) -> URLRequest? {
        guard let body = request.httpBody,
              var payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              payload.removeValue(forKey: "temperature") != nil,
              let retryBody = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var retry = request
        retry.httpBody = retryBody
        return retry
    }

    private static func requestWithoutUnsupportedTemperature(
        _ request: URLRequest,
        errorData: Data
    ) -> URLRequest? {
        guard request.httpBody != nil,
              let error = try? JSONSerialization.jsonObject(with: errorData) as? [String: Any],
              let details = error["error"] as? [String: Any] else {
            return nil
        }
        let code = (details["code"] as? String ?? "").lowercased()
        let param = (details["param"] as? String ?? "").lowercased()
        let message = (details["message"] as? String ?? "").lowercased()
        let unsupportedCode = code == "unsupported_parameter" || code == "unsupported_value"
        let unsupportedMessage = message.contains("unsupported") ||
            message.contains("not supported") || message.contains("does not support")
        guard unsupportedCode && param == "temperature" && unsupportedMessage else {
            return nil
        }
        return requestWithoutTemperature(request)
    }

    static func upload(
        for request: URLRequest,
        from bodyData: Data
    ) async throws -> (Data, URLResponse) {
        // Reuses the warm connection; a dead one is retried once on a fresh session.
        try await withStaleConnectionRetry(timeout: timeout(for: request)) { session in
            try await session.upload(for: request, from: bodyData)
        }
    }

    /// Hosts worth warming: one entry per distinct http(s) origin, skipping blanks, malformed
    /// URLs and loopback hosts (no handshake worth hiding there).
    static func prewarmURLs(baseURLs: [String]) -> [URL] {
        var seen = Set<String>()
        var urls: [URL] = []
        for raw in baseURLs {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = url.host?.lowercased(), !host.isEmpty,
                  host != "localhost", host != "127.0.0.1", host != "::1" else { continue }
            let origin = "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
            if seen.insert(origin).inserted { urls.append(url) }
        }
        return urls
    }

    /// Opens (or confirms) the connection to each provider host while the user is still
    /// speaking. Sends a body-less HEAD with no credentials and no user data to the already
    /// configured base URL; the status and body are ignored. Only the connection matters.
    static func prewarm(baseURLs: [String]) {
        for url in prewarmURLs(baseURLs: baseURLs) {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5
            Task.detached(priority: .utility) {
                _ = try? await sharedSession.data(for: request)
            }
        }
    }
}
