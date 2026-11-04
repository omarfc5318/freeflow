import CryptoKit
import Foundation

// Spotify Web API with OAuth PKCE (no client secret) and a loopback redirect, plus the Apple
// Music fallback. Foundation only: nothing here opens a socket, a browser or Keychain.

enum RioSpotifyPKCE {
    /// RFC 7636 unreserved characters.
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Maps random bytes to verifier characters; bytes that would bias the choice are skipped.
    static func verifier(from bytes: [UInt8]) -> String {
        let limit = (256 / alphabet.count) * alphabet.count
        return String(bytes.filter { Int($0) < limit }.map { alphabet[Int($0) % alphabet.count] })
    }

    /// Random from the system generator (cryptographically secure on macOS).
    static func makeVerifier(length: Int = 64) -> String {
        var generator = SystemRandomNumberGenerator()
        var verifier = ""
        while verifier.count < length {
            verifier += Self.verifier(from: (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) })
        }
        return String(verifier.prefix(length))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func makeState() -> String { makeVerifier(length: 24) }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct RioSpotifyToken: Equatable {
    let access: String
    let refresh: String?
    let expiresIn: Int
}

enum RioSpotifyTarget: Equatable {
    case track(uri: String, title: String, artist: String)
    case artist(uri: String, name: String)

    var uri: String {
        switch self {
        case .track(let uri, _, _), .artist(let uri, _): return uri
        }
    }

    var spoken: String {
        switch self {
        case .track(_, let title, let artist): return "\(title) by \(artist)"
        case .artist(_, let name): return name
        }
    }
}

enum RioSpotifyCallback: Equatable {
    case code(String)
    case denied
    /// The state did not match: not from the login the owner started.
    case rejected
    /// Not the redirect (a favicon request, say).
    case ignore
}

enum RioSpotifyRequests {
    static let port: UInt16 = 8898
    static let redirectURI = "http://127.0.0.1:\(port)/callback"
    static let scopes = "user-modify-playback-state user-read-playback-state"

    static func authorizeURL(clientID: String, challenge: String, state: String) -> URL {
        RioOutsideHTTP.url(host: "accounts.spotify.com", path: "/authorize", query: [
            ("response_type", "code"), ("client_id", clientID), ("redirect_uri", redirectURI),
            ("code_challenge_method", "S256"), ("code_challenge", challenge), ("scope", scopes), ("state", state),
        ]) ?? URL(fileURLWithPath: "/")
    }

    private static func tokenRequest(_ pairs: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = RioOutsideHTTP.timeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = RioOutsideHTTP.formBody(pairs)
        return request
    }

    static func tokenExchange(clientID: String, code: String, verifier: String) -> URLRequest {
        tokenRequest([
            ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirectURI),
            ("client_id", clientID), ("code_verifier", verifier),
        ])
    }

    static func tokenRefresh(clientID: String, refreshToken: String) -> URLRequest {
        tokenRequest([("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", clientID)])
    }

    static func search(query: String, accessToken: String) -> URLRequest {
        RioOutsideHTTP.get(
            RioOutsideHTTP.url(host: "api.spotify.com", path: "/v1/search", query: [("q", query), ("type", "track,artist"), ("limit", "1")]),
            headers: ["Authorization": "Bearer \(accessToken)"]
        ) ?? URLRequest(url: URL(fileURLWithPath: "/"))
    }

    static func play(target: RioSpotifyTarget, accessToken: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/play")!)
        request.httpMethod = "PUT"
        request.timeoutInterval = RioOutsideHTTP.timeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch target {
        case .track(let uri, _, _): request.httpBody = RioOutsideHTTP.jsonBody(["uris": [uri]])
        case .artist(let uri, _): request.httpBody = RioOutsideHTTP.jsonBody(["context_uri": uri])
        }
        return request
    }
}

enum RioSpotifyParser {
    static func token(from data: Data) -> RioSpotifyToken? {
        guard let json = RioOutsideHTTP.object(data), let access = json["access_token"] as? String, !access.isEmpty else { return nil }
        return RioSpotifyToken(access: access, refresh: json["refresh_token"] as? String, expiresIn: json["expires_in"] as? Int ?? 3600)
    }

    /// The artist when the query is just that artist's name, otherwise the best track.
    static func target(from data: Data, query: String) -> RioSpotifyTarget? {
        guard let json = RioOutsideHTTP.object(data) else { return nil }
        let artist = ((json["artists"] as? [String: Any])?["items"] as? [[String: Any]])?.first
        if let uri = artist?["uri"] as? String, let name = artist?["name"] as? String,
           RioText.compact(name) == RioText.compact(query) {
            return .artist(uri: uri, name: name)
        }
        let track = ((json["tracks"] as? [String: Any])?["items"] as? [[String: Any]])?.first
        if let uri = track?["uri"] as? String, let title = track?["name"] as? String {
            let by = ((track?["artists"] as? [[String: Any]])?.first?["name"] as? String) ?? "Unknown artist"
            return .track(uri: uri, title: title, artist: by)
        }
        if let uri = artist?["uri"] as? String, let name = artist?["name"] as? String { return .artist(uri: uri, name: name) }
        return nil
    }

    /// Reads the redirect's request line ("GET /callback?code=...&state=... HTTP/1.1").
    static func authorizationCode(fromRequestLine line: String, expectedState: String) -> RioSpotifyCallback {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: "http://127.0.0.1" + parts[1]), components.path == "/callback" else { return .ignore }
        let items = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        guard items["state"] == expectedState else { return .rejected }
        if items["error"] != nil { return .denied }
        guard let code = items["code"], !code.isEmpty else { return .rejected }
        return .code(code)
    }
}

/// Apple Music through its `music://` search link: the fallback when Spotify isn't connected.
enum RioAppleMusic {
    static func searchURL(query: String) -> URL? {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }
        return URL(string: "music://music.apple.com/us/search?term=\(RioOutsideHTTP.encode(term))")
    }
}

enum RioSpotifyOutcome: Equatable {
    case playing(String)
    /// Found, but no Spotify device is open to play on.
    case noDevice(RioSpotifyTarget)
}

struct RioSpotifyPlayback: Equatable {
    let outcome: RioSpotifyOutcome
    /// Set when Spotify rotated the refresh token; the caller stores it.
    let newRefreshToken: String?
}

struct RioSpotifyService {
    static let reconnectMessage = "Spotify needs you to connect again. Open Rio's settings, Integrations, Connect Spotify."

    let fetch: RioFetch
    let clientID: String
    let refreshToken: String

    func play(query: String) async throws -> RioSpotifyPlayback {
        let refreshed = try await accessToken()
        let found = try await RioOutsideHTTP.send(RioSpotifyRequests.search(query: query, accessToken: refreshed.access), using: fetch)
        guard let target = RioSpotifyParser.target(from: found, query: query) else { throw RioOutsideError.notFound(query) }
        let response = try await fetch(RioSpotifyRequests.play(target: target, accessToken: refreshed.access))
        let rotated = refreshed.refresh.flatMap { $0 == refreshToken ? nil : $0 }
        switch response.status {
        case 200..<300: return RioSpotifyPlayback(outcome: .playing("Playing \(target.spoken)"), newRefreshToken: rotated)
        case 404: return RioSpotifyPlayback(outcome: .noDevice(target), newRefreshToken: rotated)
        case 401, 403: throw RioOutsideError.notConfigured(Self.reconnectMessage)
        default: throw RioOutsideError.http(response.status)
        }
    }

    private func accessToken() async throws -> RioSpotifyToken {
        let response = try await fetch(RioSpotifyRequests.tokenRefresh(clientID: clientID, refreshToken: refreshToken))
        if (400..<500).contains(response.status) { throw RioOutsideError.notConfigured(Self.reconnectMessage) }
        guard (200..<300).contains(response.status) else { throw RioOutsideError.http(response.status) }
        guard let token = RioSpotifyParser.token(from: response.data) else { throw RioOutsideError.badResponse }
        return token
    }
}
