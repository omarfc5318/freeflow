import Foundation

// Weather through Open-Meteo (free, no key). Foundation only.
// Privacy: the only thing sent is the place name (geocoding) and its coordinates (forecast).

struct RioPlace: Equatable {
    let name: String
    let latitude: Double
    let longitude: Double
}

struct RioWeatherDay: Equatable {
    let code: Int
    let high: Double
    let low: Double
}

struct RioWeatherReport: Equatable {
    let temperature: Double
    let code: Int
    let todayHigh: Double
    let todayLow: Double
    let todayRain: Int?
    let tomorrow: RioWeatherDay?
}

enum RioWeatherRequests {
    static func geocode(place: String) -> URLRequest? {
        let trimmed = place.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return RioOutsideHTTP.get(RioOutsideHTTP.url(
            host: "geocoding-api.open-meteo.com", path: "/v1/search",
            query: [("name", trimmed), ("count", "1"), ("language", "en"), ("format", "json")]
        ))
    }

    static func forecast(latitude: Double, longitude: Double, fahrenheit: Bool) -> URLRequest {
        let url = RioOutsideHTTP.url(host: "api.open-meteo.com", path: "/v1/forecast", query: [
            ("latitude", String(latitude)), ("longitude", String(longitude)),
            ("current", "temperature_2m,apparent_temperature,weather_code,wind_speed_10m"),
            ("daily", "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            ("temperature_unit", fahrenheit ? "fahrenheit" : "celsius"),
            ("wind_speed_unit", "mph"), ("timezone", "auto"), ("forecast_days", "2"),
        ])
        return RioOutsideHTTP.get(url) ?? URLRequest(url: URL(fileURLWithPath: "/"))
    }
}

enum RioWeatherParser {
    static func place(from data: Data) -> RioPlace? {
        guard let first = (RioOutsideHTTP.object(data)?["results"] as? [[String: Any]])?.first,
              let name = first["name"] as? String,
              let latitude = first["latitude"] as? Double, let longitude = first["longitude"] as? Double else { return nil }
        return RioPlace(name: name, latitude: latitude, longitude: longitude)
    }

    static func report(from data: Data) -> RioWeatherReport? {
        guard let root = RioOutsideHTTP.object(data),
              let current = root["current"] as? [String: Any],
              let temperature = current["temperature_2m"] as? Double,
              let code = current["weather_code"] as? Int,
              let daily = root["daily"] as? [String: Any],
              let codes = daily["weather_code"] as? [Int],
              let highs = daily["temperature_2m_max"] as? [Double],
              let lows = daily["temperature_2m_min"] as? [Double],
              let todayHigh = highs.first, let todayLow = lows.first else { return nil }
        let rain = (daily["precipitation_probability_max"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue }
        var tomorrow: RioWeatherDay?
        if codes.count > 1, highs.count > 1, lows.count > 1 {
            tomorrow = RioWeatherDay(code: codes[1], high: highs[1], low: lows[1])
        }
        return RioWeatherReport(
            temperature: temperature, code: code, todayHigh: todayHigh, todayLow: todayLow,
            todayRain: rain?.first, tomorrow: tomorrow
        )
    }
}

enum RioWeatherSpeech {
    /// WMO weather interpretation codes, as Open-Meteo returns them.
    static func describe(code: Int) -> String {
        switch code {
        case 0: return "clear"
        case 1: return "mostly clear"
        case 2: return "partly cloudy"
        case 3: return "overcast"
        case 45, 48: return "foggy"
        case 51, 53, 55: return "drizzling"
        case 56, 57: return "freezing drizzle"
        case 61: return "light rain"
        case 63: return "rainy"
        case 65: return "heavy rain"
        case 66, 67: return "freezing rain"
        case 71: return "light snow"
        case 73: return "snowy"
        case 75: return "heavy snow"
        case 77: return "snow grains"
        case 80: return "light showers"
        case 81: return "showers"
        case 82: return "heavy showers"
        case 85, 86: return "snow showers"
        case 95: return "thunderstorms"
        case 96, 99: return "thunderstorms with hail"
        default: return "unsettled"
        }
    }

    private static func whole(_ value: Double) -> Int { Int(value.rounded()) }

    static func sentence(place: String, report: RioWeatherReport) -> String {
        var text = "In \(place) it's \(whole(report.temperature)) degrees and \(describe(code: report.code)). "
        text += "High \(whole(report.todayHigh)), low \(whole(report.todayLow))."
        if let rain = report.todayRain, rain >= 30 { text += " \(rain) percent chance of rain." }
        if let tomorrow = report.tomorrow {
            text += " Tomorrow: \(describe(code: tomorrow.code)), \(whole(tomorrow.high)) to \(whole(tomorrow.low))."
        }
        return text
    }
}

struct RioWeatherService {
    let fetch: RioFetch

    /// "Davis California" finds nothing as a whole, so shorter names are tried too.
    static func candidates(for spoken: String) -> [String] {
        let full = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        var names = [full]
        if let comma = full.firstIndex(of: ",") { names.append(String(full[..<comma])) }
        let words = full.split(separator: " ")
        if words.count > 1 { names.append(words.dropLast().joined(separator: " ")) }
        if words.count > 2 { names.append(String(words[0])) }
        var seen = Set<String>()
        return names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    func answer(place spoken: String, fahrenheit: Bool) async throws -> String {
        var found: RioPlace?
        for name in Self.candidates(for: spoken) {
            guard let request = RioWeatherRequests.geocode(place: name) else { continue }
            if let place = RioWeatherParser.place(from: try await RioOutsideHTTP.send(request, using: fetch)) {
                found = place
                break
            }
        }
        guard let place = found else { throw RioOutsideError.notFound(spoken) }
        let request = RioWeatherRequests.forecast(latitude: place.latitude, longitude: place.longitude, fahrenheit: fahrenheit)
        guard let report = RioWeatherParser.report(from: try await RioOutsideHTTP.send(request, using: fetch)) else {
            throw RioOutsideError.badResponse
        }
        return RioWeatherSpeech.sentence(place: place.name, report: report)
    }
}
