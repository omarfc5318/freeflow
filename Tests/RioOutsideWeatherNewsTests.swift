import Foundation

/// A fake network for builder S's services: answers by URL, records every request. No sockets.
final class RioFakeNetwork: @unchecked Sendable {
    typealias Rule = (match: @Sendable (URLRequest) -> Bool, status: Int, body: String)
    private let lock = NSLock()
    private var rules: [Rule] = []
    private var seen: [URLRequest] = []

    init(_ rules: [Rule] = []) { self.rules = rules }

    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen }

    private func record(_ request: URLRequest) -> Rule? {
        lock.lock()
        defer { lock.unlock() }
        seen.append(request)
        return rules.first { $0.match(request) }
    }

    var fetch: RioFetch {
        { [self] request in
            guard let rule = record(request) else { return RioHTTPResponse(status: 404, data: Data()) }
            return RioHTTPResponse(status: rule.status, data: Data(rule.body.utf8))
        }
    }

    static func rule(_ needle: String, _ status: Int, _ body: String) -> Rule {
        ({ $0.url?.absoluteString.contains(needle) == true }, status, body)
    }

    static func rule(_ needle: String, _ body: String) -> Rule { rule(needle, 200, body) }
}

enum RioOutsideWeatherNewsTests {
    static let geocodeFixture = #"{"results":[{"id":5,"name":"Davis","latitude":38.54491,"longitude":-121.74052,"country":"United States","admin1":"California","timezone":"America/Los_Angeles"}],"generationtime_ms":0.5}"#
    static let forecastFixture = #"{"latitude":38.54,"longitude":-121.74,"current":{"time":"2026-11-03T08:00","temperature_2m":61.4,"apparent_temperature":59.0,"weather_code":2,"wind_speed_10m":6.2},"daily":{"time":["2026-11-03","2026-11-04"],"weather_code":[2,61],"temperature_2m_max":[70.2,66.1],"temperature_2m_min":[48.4,50.3],"precipitation_probability_max":[10,70]}}"#

    static func run() async {
        weatherRequests()
        weatherParsing()
        await weatherService()
        newsModelChoice()
        newsText()
        await newsService()
    }

    private static func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    private static func weatherRequests() {
        let geo = RioWeatherRequests.geocode(place: "San Francisco")!
        TestSupport.expectEqual(geo.url?.host, "geocoding-api.open-meteo.com")
        TestSupport.expectEqual(geo.url?.path, "/v1/search")
        TestSupport.expectEqual(query(geo)["name"], "San Francisco")
        TestSupport.expectEqual(query(geo)["count"], "1")
        TestSupport.expectEqual(geo.httpMethod, "GET")
        TestSupport.expect(geo.url?.absoluteString.contains("San%20Francisco") == true, "place is percent-encoded")
        TestSupport.expect(RioWeatherRequests.geocode(place: "   ") == nil, "an empty place makes no request")

        let forecast = RioWeatherRequests.forecast(latitude: 38.54491, longitude: -121.74052, fahrenheit: true)
        TestSupport.expectEqual(forecast.url?.host, "api.open-meteo.com")
        TestSupport.expectEqual(forecast.url?.path, "/v1/forecast")
        TestSupport.expectEqual(query(forecast)["latitude"], "38.54491")
        TestSupport.expectEqual(query(forecast)["temperature_unit"], "fahrenheit")
        TestSupport.expectEqual(query(forecast)["timezone"], "auto")
        TestSupport.expectEqual(query(forecast)["wind_speed_unit"], "mph")
        TestSupport.expect(forecast.value(forHTTPHeaderField: "Authorization") == nil, "no credentials go to Open-Meteo")
        let celsius = RioWeatherRequests.forecast(latitude: 1, longitude: 2, fahrenheit: false)
        TestSupport.expectEqual(query(celsius)["temperature_unit"], "celsius")
    }

    private static func weatherParsing() {
        let place = RioWeatherParser.place(from: Data(geocodeFixture.utf8))
        TestSupport.expectEqual(place?.name, "Davis")
        TestSupport.expectEqual(place?.latitude, 38.54491)
        TestSupport.expect(RioWeatherParser.place(from: Data(#"{"generationtime_ms":0.4}"#.utf8)) == nil, "no results key is not found")
        TestSupport.expect(RioWeatherParser.place(from: Data("nope".utf8)) == nil, "garbage is not a place")

        let report = RioWeatherParser.report(from: Data(forecastFixture.utf8))
        TestSupport.expectEqual(report?.temperature, 61.4)
        TestSupport.expectEqual(report?.code, 2)
        TestSupport.expectEqual(report?.todayHigh, 70.2)
        TestSupport.expectEqual(report?.todayRain, 10)
        TestSupport.expectEqual(report?.tomorrow?.code, 61)
        TestSupport.expectEqual(report?.tomorrow?.low, 50.3)
        TestSupport.expect(RioWeatherParser.report(from: Data(#"{"current":{}}"#.utf8)) == nil, "missing fields are not a report")

        TestSupport.expectEqual(RioWeatherSpeech.describe(code: 0), "clear")
        TestSupport.expectEqual(RioWeatherSpeech.describe(code: 95), "thunderstorms")
        TestSupport.expectEqual(RioWeatherSpeech.describe(code: 71), "light snow")
        TestSupport.expectEqual(RioWeatherSpeech.describe(code: 12345), "unsettled")

        TestSupport.expectEqual(
            RioWeatherSpeech.sentence(place: "Davis", report: report!),
            "In Davis it's 61 degrees and partly cloudy. High 70, low 48. Tomorrow: light rain, 66 to 50."
        )
        let rainy = RioWeatherParser.report(from: Data(forecastFixture.replacingOccurrences(of: "[10,70]", with: "[45,70]").utf8))!
        TestSupport.expect(RioWeatherSpeech.sentence(place: "Davis", report: rainy).contains("45 percent chance of rain"), "likely rain is spoken")
    }

    private static func weatherService() async {
        let network = RioFakeNetwork([
            RioFakeNetwork.rule("geocoding-api.open-meteo.com", geocodeFixture),
            RioFakeNetwork.rule("api.open-meteo.com/v1/forecast", forecastFixture),
        ])
        let service = RioWeatherService(fetch: network.fetch)
        let answer = try? await service.answer(place: "Davis", fahrenheit: true)
        TestSupport.expectEqual(answer, "In Davis it's 61 degrees and partly cloudy. High 70, low 48. Tomorrow: light rain, 66 to 50.")
        TestSupport.expectEqual(network.requests.count, 2)

        // "Davis California" has no match as a whole; the first word does.
        let retry = RioFakeNetwork([
            ({ $0.url?.absoluteString.contains("name=Davis%20California") == true }, 200, #"{"generationtime_ms":1}"#),
            RioFakeNetwork.rule("name=Davis", geocodeFixture),
            RioFakeNetwork.rule("api.open-meteo.com/v1/forecast", forecastFixture),
        ])
        let second = try? await RioWeatherService(fetch: retry.fetch).answer(place: "Davis California", fahrenheit: false)
        TestSupport.expect(second?.hasPrefix("In Davis") == true, "falls back to a shorter place name")

        let nowhere = RioFakeNetwork([RioFakeNetwork.rule("geocoding-api", #"{"generationtime_ms":1}"#)])
        do {
            _ = try await RioWeatherService(fetch: nowhere.fetch).answer(place: "Narnia", fahrenheit: true)
            fatalError("an unknown place must throw")
        } catch {
            TestSupport.expectEqual(error as? RioOutsideError, .notFound("Narnia"))
        }
        let down = RioFakeNetwork([
            RioFakeNetwork.rule("geocoding-api", geocodeFixture),
            RioFakeNetwork.rule("api.open-meteo.com/v1/forecast", 500, "oops"),
        ])
        do {
            _ = try await RioWeatherService(fetch: down.fetch).answer(place: "Davis", fahrenheit: true)
            fatalError("a server error must throw")
        } catch {
            TestSupport.expectEqual(error as? RioOutsideError, .http(500))
        }
    }

    // MARK: News

    private static func newsModelChoice() {
        let groq = "https://api.groq.com/openai/v1"
        TestSupport.expectEqual(RioNewsModel.choose(configured: "groq/compound", override: "", baseURL: groq), "groq/compound")
        TestSupport.expectEqual(RioNewsModel.choose(configured: "openai/gpt-oss-20b", override: "", baseURL: groq), "groq/compound-mini")
        TestSupport.expectEqual(RioNewsModel.choose(configured: "openai/gpt-oss-20b", override: "my-search-model", baseURL: groq), "my-search-model")
        TestSupport.expectEqual(RioNewsModel.choose(configured: "gpt-4o-search-preview", override: "", baseURL: "https://api.openai.com/v1"), "gpt-4o-search-preview")
        TestSupport.expectEqual(RioNewsModel.choose(configured: "sonar", override: "", baseURL: "https://api.perplexity.ai"), "sonar")
        TestSupport.expect(RioNewsModel.choose(configured: "llama3", override: "", baseURL: "http://localhost:11434/v1") == nil, "no search model on a plain provider")
        TestSupport.expect(RioNewsModel.choose(configured: "gpt-4o", override: "", baseURL: "https://api.openai.com/v1") == nil, "gpt-4o cannot browse here")
        TestSupport.expect(RioNewsModel.choose(configured: "x", override: "", baseURL: "https://api.groq.com.evil.example/v1") == nil, "host must be exactly api.groq.com")
    }

    private static func newsText() {
        let reply = "**Top stories**\n- Markets rose on [Reuters](https://reuters.com/x) reports.\n- Rain is expected in Doha. See https://example.com/a for more.\n"
        let spoken = RioNewsText.spoken(reply)
        TestSupport.expect(!spoken.contains("*") && !spoken.contains("http") && !spoken.contains("]("), "markdown and links are removed: \(spoken)")
        TestSupport.expect(spoken.contains("Markets rose on Reuters reports"), "link text is kept: \(spoken)")
        TestSupport.expect(RioNewsText.spoken(String(repeating: "Word. ", count: 200)).count <= 520, "long answers are cut short")
        TestSupport.expectEqual(RioNewsText.spoken("  \n "), "")
        TestSupport.expect(RioNewsPrompt.user(topic: "AI").contains("AI"), "topic goes in the question")
        TestSupport.expect(!RioNewsPrompt.user(topic: nil).isEmpty, "no topic asks for the headlines")
    }

    private struct FakeLLM: RioSmartLLMCompleting {
        let reply: String
        func complete(system: String, user: String, maxOutputTokens: Int?) async throws -> String { reply }
    }

    private static func newsService() async {
        do {
            _ = try await RioNewsService(llm: nil).answer(topic: nil, now: Date())
            fatalError("no search model must throw")
        } catch {
            TestSupport.expectEqual(error as? RioOutsideError, .unavailable(RioNewsService.unavailableMessage))
        }
        let answer = try? await RioNewsService(llm: FakeLLM(reply: "- **Markets** rose today.")).answer(topic: "markets", now: Date())
        TestSupport.expectEqual(answer, "Markets rose today.")
        do {
            _ = try await RioNewsService(llm: FakeLLM(reply: "  ")).answer(topic: nil, now: Date())
            fatalError("an empty reply must throw")
        } catch {
            TestSupport.expectEqual(error as? RioOutsideError, .badResponse)
        }
    }
}
