import AppKit
import Foundation

/// Runs builder S's actions: weather, news, music, Notion and Canvas. Returns nil for anything else.
///
/// Network use (all disclosed in `RioIntegrationsSettingsSection`, each with its own switch):
/// weather sends a place name and coordinates to Open-Meteo; news sends a topic to the owner's AI
/// provider; Spotify, Notion and Canvas send the owner's own token and the request to their service.
/// Nothing is logged or stored from any answer.
@MainActor
final class RioOutsideActionHandler: RioActionHandling {
    static let shared = RioOutsideActionHandler()

    private let fetch: RioFetch
    private let openURL: @MainActor (URL) -> Bool

    init(fetch: @escaping RioFetch = RioOutsideHTTP.live, openURL: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.fetch = fetch
        self.openURL = openURL
    }

    func handle(_ action: RioAction, executor: RioActionExecuting) async -> RioActionResult? {
        switch action {
        case .weather(let place): return await weather(place)
        case .news(let topic): return await news(topic)
        case .playMusic(let query): return await playMusic(query)
        case .notionAdd(let text, let page): return await notionAdd(text, page: page)
        case .canvasDue(let range): return await canvasDue(range)
        default: return nil
        }
    }

    // MARK: Guards and messages

    private func offline() -> RioActionResult? {
        NetworkMonitor.shared.isOnline ? nil : .failed(message: "I'm offline right now")
    }

    private func failure(_ error: Error, subject: String) -> RioActionResult {
        guard let known = error as? RioOutsideError else {
            return .failed(message: "I couldn't reach \(subject)")
        }
        switch known {
        case .notConfigured(let message), .unavailable(let message): return .failed(message: message)
        case .notFound(let what): return .failed(message: "I couldn't find \(what) on \(subject)")
        case .http(let status) where status == 401 || status == 403:
            return .failed(message: "\(subject) didn't accept my token. Check it in Rio's settings, Integrations.")
        case .http, .badResponse: return .failed(message: "\(subject) gave me an answer I couldn't use")
        }
    }

    // MARK: Weather and news

    private func weather(_ spoken: String?) async -> RioActionResult {
        guard RioOutsideSettings.weatherEnabled else { return .failed(message: "Weather is switched off in Rio's settings") }
        let named = spoken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let place = named.isEmpty ? RioOutsideSettings.weatherDefaultPlace : named
        guard !place.isEmpty else {
            return .failed(message: "Tell me a place, like \"weather in Davis\", or set a default place in Rio's settings.")
        }
        if let offline = offline() { return offline }
        do {
            let answer = try await RioWeatherService(fetch: fetch).answer(place: place, fahrenheit: RioOutsideSettings.useFahrenheit)
            return .done(summary: answer)
        } catch {
            return failure(error, subject: "Open-Meteo")
        }
    }

    private func news(_ topic: String?) async -> RioActionResult {
        guard RioOutsideSettings.newsEnabled else { return .failed(message: "News is switched off in Rio's settings") }
        guard let base = RioSmartSettings.llmConfig() else {
            return .failed(message: "News needs your AI provider. Add your API key in Rio's settings first.")
        }
        let model = RioNewsModel.choose(configured: base.model, override: RioOutsideSettings.newsModelOverride, baseURL: base.baseURL)
        let llm = model.map { chosen in
            RioSmartLLMClient(
                config: { RioSmartLLMConfig(apiKey: base.apiKey, baseURL: base.baseURL, model: chosen) },
                timeout: 25
            )
        }
        if llm != nil, let offline = offline() { return offline }
        do {
            return .done(summary: try await RioNewsService(llm: llm).answer(topic: topic, now: Date()))
        } catch {
            if let known = error as? RioOutsideError { return failure(known, subject: "the news service") }
            return .failed(message: "I couldn't get the news right now")
        }
    }

    // MARK: Music

    private func playMusic(_ query: String) async -> RioActionResult {
        guard RioOutsideSettings.musicEnabled else { return .failed(message: "Music is switched off in Rio's settings") }
        var note = ""
        if RioOutsideSettings.spotifyConnected {
            if let offline = offline() { return offline }
            let service = RioSpotifyService(
                fetch: fetch, clientID: RioOutsideSettings.secret(RioOutsideSettings.spotifyClientAccount),
                refreshToken: RioOutsideSettings.secret(RioOutsideSettings.spotifyRefreshAccount)
            )
            do {
                let playback = try await service.play(query: query)
                if let rotated = playback.newRefreshToken {
                    RioOutsideSettings.setSecret(rotated, account: RioOutsideSettings.spotifyRefreshAccount)
                }
                switch playback.outcome {
                case .playing(let summary): return .done(summary: summary)
                case .noDevice(let target):
                    // Nothing is open to play on: open it in Spotify so one tap starts it.
                    if let url = URL(string: target.uri), openURL(url) {
                        return .done(summary: "Opened \(target.spoken) in Spotify. Press play there.")
                    }
                    return .failed(message: "Open Spotify on a device first, then ask again")
                }
            } catch RioOutsideError.notFound(let what) {
                return .failed(message: "I couldn't find \(what) on Spotify")
            } catch {
                note = " Spotify needs attention, check Rio's settings."
            }
        }
        guard let url = RioAppleMusic.searchURL(query: query), openURL(url) else {
            return .failed(message: "I couldn't open Apple Music")
        }
        return .done(summary: "Opened Apple Music search for \(query).\(note)")
    }

    // MARK: Notion and Canvas

    private func notionAdd(_ text: String, page: String?) async -> RioActionResult {
        guard RioOutsideSettings.notionEnabled else { return .failed(message: "Notion is switched off in Rio's settings") }
        let token = RioOutsideSettings.secret(RioOutsideSettings.notionTokenAccount)
        guard !token.isEmpty else { return .failed(message: "Add your Notion token in Rio's settings, Integrations, first.") }
        if let offline = offline() { return offline }
        let service = RioNotionService(fetch: fetch, token: token, defaultPage: RioOutsideSettings.notionDefaultPage)
        do {
            let title = try await service.add(text: text, page: page)
            return .done(summary: "Added it to \(title)")
        } catch {
            if case RioOutsideError.notFound(let what) = error {
                return .failed(message: "I couldn't find a Notion page called \(what). Share it with your Rio integration first.")
            }
            if case RioOutsideError.http(404) = error {
                return .failed(message: "Notion can't see that page. Share it with your Rio integration (page menu, Connections).")
            }
            return failure(error, subject: "Notion")
        }
    }

    private func canvasDue(_ range: String?) async -> RioActionResult {
        guard RioOutsideSettings.canvasEnabled else { return .failed(message: "Canvas is switched off in Rio's settings") }
        let token = RioOutsideSettings.secret(RioOutsideSettings.canvasTokenAccount)
        guard !token.isEmpty else { return .failed(message: "Add your Canvas token in Rio's settings, Integrations, first.") }
        guard let base = RioCanvasConfig.baseURL(from: RioOutsideSettings.canvasBaseText) else {
            return .failed(message: "Your Canvas address needs to start with https://. Fix it in Rio's settings.")
        }
        if let offline = offline() { return offline }
        do {
            return .done(summary: try await RioCanvasService(fetch: fetch, base: base, token: token).due(range: range, now: Date(), calendar: .current))
        } catch {
            return failure(error, subject: "Canvas")
        }
    }
}
