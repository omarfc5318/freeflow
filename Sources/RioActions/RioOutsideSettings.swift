import Foundation

/// Where builder S's integrations read their switches and credentials. Secrets (the Spotify
/// refresh token, the Notion and Canvas tokens) live in the app's private settings store
/// (`AppSettingsStorage`, a 0600 file next to the provider API key), never in UserDefaults and
/// never in a log. Not the Keychain: the app moved its secrets out of the Keychain on purpose
/// (`AppSettingsStorage.migrateFromKeychainIfNeeded`), and the settings section says so.
enum RioOutsideSettings {
    static let weatherEnabledKey = "rio_weather_enabled"
    static let weatherPlaceKey = "rio_weather_default_place"
    static let weatherCelsiusKey = "rio_weather_celsius"
    static let newsEnabledKey = "rio_news_enabled"
    static let newsModelKey = "rio_news_model"
    static let musicEnabledKey = "rio_music_enabled"
    static let notionEnabledKey = "rio_notion_enabled"
    static let notionPageKey = "rio_notion_default_page"
    static let canvasEnabledKey = "rio_canvas_enabled"
    static let canvasBaseKey = RioCanvasConfig.baseKey
    static let phoneEnabledKey = "rio_phone_texting_enabled"
    static let phoneHandlesKey = "rio_phone_owner_handles"
    static let phoneLastRowKey = "rio_phone_last_rowid"

    static let spotifyClientAccount = "rio_spotify_client_id"
    static let spotifyRefreshAccount = "rio_spotify_refresh_token"
    static let notionTokenAccount = "rio_notion_token"
    static let canvasTokenAccount = "rio_canvas_token"

    private static func flag(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    private static func text(_ key: String) -> String {
        (UserDefaults.standard.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Weather, news and music are on by default (they run only when asked, and the settings
    /// section says what each sends); phone texting is off until the owner turns it on.
    static var weatherEnabled: Bool { flag(weatherEnabledKey, default: true) }
    static var newsEnabled: Bool { flag(newsEnabledKey, default: true) }
    static var musicEnabled: Bool { flag(musicEnabledKey, default: true) }
    static var notionEnabled: Bool { flag(notionEnabledKey, default: true) }
    static var canvasEnabled: Bool { flag(canvasEnabledKey, default: true) }
    static var phoneEnabled: Bool { flag(phoneEnabledKey, default: false) }

    static var weatherDefaultPlace: String { text(weatherPlaceKey) }
    static var useFahrenheit: Bool {
        if let celsius = UserDefaults.standard.object(forKey: weatherCelsiusKey) as? Bool { return !celsius }
        return Locale.current.measurementSystem == .us
    }
    static var newsModelOverride: String { text(newsModelKey) }
    static var notionDefaultPage: String { text(notionPageKey) }
    static var canvasBaseText: String { text(canvasBaseKey) }
    static var phoneHandles: [String] { RioPhoneHandle.parseList(text(phoneHandlesKey)) }

    static func secret(_ account: String) -> String {
        (AppSettingsStorage.load(account: account) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func setSecret(_ value: String, account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { AppSettingsStorage.delete(account: account) } else { AppSettingsStorage.save(trimmed, account: account) }
    }

    static var spotifyConnected: Bool { !secret(spotifyClientAccount).isEmpty && !secret(spotifyRefreshAccount).isEmpty }
}
