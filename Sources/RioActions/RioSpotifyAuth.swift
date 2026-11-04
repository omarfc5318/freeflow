import AppKit
import Foundation
import Network

/// The one-time Spotify login: PKCE, with a loopback listener on 127.0.0.1 that catches the
/// redirect. The listener is bound to the loopback address only, answers the first valid
/// redirect, and closes after a few minutes at most. The refresh token goes to the private store.
@MainActor
final class RioSpotifyAuth {
    static let shared = RioSpotifyAuth()
    private static let timeout: TimeInterval = 180
    private var inFlight = false

    /// Returns nil on success or a message to show.
    func connect(clientID rawClientID: String, fetch: @escaping RioFetch = RioOutsideHTTP.live) async -> String? {
        let clientID = rawClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { return "Paste your Spotify client ID first." }
        guard !inFlight else { return "A Spotify login is already open in your browser." }
        inFlight = true
        defer { inFlight = false }

        let verifier = RioSpotifyPKCE.makeVerifier()
        let state = RioSpotifyPKCE.makeState()
        let catcher = RioLoopbackCatcher(port: RioSpotifyRequests.port, state: state)
        do { try catcher.start() } catch {
            return "I couldn't open port \(RioSpotifyRequests.port) on this Mac. Another app may be using it."
        }
        let url = RioSpotifyRequests.authorizeURL(clientID: clientID, challenge: RioSpotifyPKCE.challenge(for: verifier), state: state)
        guard NSWorkspace.shared.open(url) else {
            catcher.stop()
            return "I couldn't open your browser."
        }
        let result = await catcher.result(timeout: Self.timeout)
        switch result {
        case .code(let code):
            do {
                let data = try await RioOutsideHTTP.send(RioSpotifyRequests.tokenExchange(clientID: clientID, code: code, verifier: verifier), using: fetch)
                guard let token = RioSpotifyParser.token(from: data), let refresh = token.refresh else { return "Spotify's answer wasn't what I expected." }
                RioOutsideSettings.setSecret(clientID, account: RioOutsideSettings.spotifyClientAccount)
                RioOutsideSettings.setSecret(refresh, account: RioOutsideSettings.spotifyRefreshAccount)
                return nil
            } catch {
                return "Spotify wouldn't accept the login. Check the client ID and the redirect address."
            }
        case .denied: return "You said no in Spotify, so nothing was connected."
        case .rejected: return "That login didn't match the one I started, so I ignored it."
        case .ignore: return "The login timed out. Press Connect to try again."
        }
    }
}

/// Listens on 127.0.0.1 for the single OAuth redirect.
private final class RioLoopbackCatcher: @unchecked Sendable {
    private let port: UInt16
    private let state: String
    private let queue = DispatchQueue(label: "rio.spotify.loopback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var continuation: CheckedContinuation<RioSpotifyCallback, Never>?
    private var finished: RioSpotifyCallback?

    init(port: UInt16, state: String) {
        self.port = port
        self.state = state
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    func result(timeout: TimeInterval) async -> RioSpotifyCallback {
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(.ignore) }
        return await withCheckedContinuation { continuation in
            lock.lock()
            if let done = finished {
                lock.unlock()
                continuation.resume(returning: done)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    private func finish(_ outcome: RioSpotifyCallback) {
        lock.lock()
        guard finished == nil else { lock.unlock(); return }
        finished = outcome
        let waiting = continuation
        continuation = nil
        lock.unlock()
        stop()
        waiting?.resume(returning: outcome)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else { connection.cancel(); return }
            let line = request.components(separatedBy: "\r\n").first ?? ""
            let outcome = RioSpotifyParser.authorizationCode(fromRequestLine: line, expectedState: self.state)
            let message = outcome == .ignore ? "Not found" : "You can close this tab and go back to Rio."
            let body = "<html><body style=\"font-family:-apple-system;text-align:center;margin-top:20vh\"><h2>\(message)</h2></body></html>"
            let head = "HTTP/1.1 \(outcome == .ignore ? "404 Not Found" : "200 OK")\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
            connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
            if outcome != .ignore { self.finish(outcome) }
        }
    }
}
