import Foundation

/// Everything that turns spoken words into a web URL. Only http and https URLs are ever built,
/// and user text only ever lands in an encoded query value or a validated host name.
enum RioWebURLs {
    /// Spoken name (letters and digits only, so "you tube" == "youtube") -> https URL.
    private static let knownSites: [String: String] = [
        "youtube": "https://www.youtube.com",
        "gmail": "https://mail.google.com",
        "github": "https://github.com",
        "netflix": "https://www.netflix.com",
        "google": "https://www.google.com",
        "googlemaps": "https://maps.google.com",
        "maps": "https://maps.google.com",
        "googledrive": "https://drive.google.com",
        "drive": "https://drive.google.com",
        "googledocs": "https://docs.google.com",
        "docs": "https://docs.google.com",
        "googlesheets": "https://sheets.google.com",
        "sheets": "https://sheets.google.com",
        "googleslides": "https://slides.google.com",
        "googlecalendar": "https://calendar.google.com",
        "googlemeet": "https://meet.google.com",
        "meet": "https://meet.google.com",
        "twitter": "https://x.com",
        "instagram": "https://www.instagram.com",
        "facebook": "https://www.facebook.com",
        "linkedin": "https://www.linkedin.com",
        "reddit": "https://www.reddit.com",
        "amazon": "https://www.amazon.com",
        "wikipedia": "https://www.wikipedia.org",
        "chatgpt": "https://chatgpt.com",
        "claude": "https://claude.ai",
        "notion": "https://www.notion.so",
        "slack": "https://app.slack.com",
        "discord": "https://discord.com/app",
        "whatsapp": "https://web.whatsapp.com",
        "spotify": "https://open.spotify.com",
        "twitch": "https://www.twitch.tv",
        "tiktok": "https://www.tiktok.com",
        "pinterest": "https://www.pinterest.com",
        "stackoverflow": "https://stackoverflow.com",
        "hackernews": "https://news.ycombinator.com",
        "outlook": "https://outlook.live.com",
        "figma": "https://www.figma.com",
        "dropbox": "https://www.dropbox.com",
        "apple": "https://www.apple.com",
        "icloud": "https://www.icloud.com",
        "yahoo": "https://www.yahoo.com",
        "bing": "https://www.bing.com",
        "duckduckgo": "https://duckduckgo.com",
        "ebay": "https://www.ebay.com",
        "paypal": "https://www.paypal.com",
        "imdb": "https://www.imdb.com",
        "soundcloud": "https://soundcloud.com",
        "hulu": "https://www.hulu.com",
        "disneyplus": "https://www.disneyplus.com",
        "primevideo": "https://www.primevideo.com",
        "canva": "https://www.canva.com",
        "trello": "https://trello.com",
        "medium": "https://medium.com",
        "quora": "https://www.quora.com",
    ]

    static func knownSite(compactName: String) -> URL? {
        knownSites[compactName].flatMap { URL(string: $0) }
    }

    static func isKnownSite(spoken: String) -> Bool {
        knownSites[RioText.compact(spoken)] != nil
    }

    // MARK: Spoken domains

    static let allowedTLDs: Set<String> = [
        "com", "org", "net", "io", "co", "ai", "app", "dev", "edu", "gov", "me", "tv", "us", "uk",
        "qa", "ae", "sa", "info", "xyz", "fm", "gg", "ly", "so", "sh", "to", "in", "de", "fr",
        "ca", "au", "news", "tech", "online", "store", "site", "page", "club", "cloud", "design",
    ]

    /// "hala discover dot com" -> https://haladiscover.com; "github.com" -> https://github.com.
    /// Nil unless the text is a host name with a known top-level domain.
    static func domainURL(fromSpoken spoken: String) -> URL? {
        var text = spoken.lowercased()
        text = RioText.replacing(#"\s+dot\s+"#, with: ".", in: text)
        guard text.contains(".") else { return nil }
        text = text.replacingOccurrences(of: " ", with: "")
        guard RioText.matches(#"^(?:[a-z0-9-]+\.)+[a-z]{2,24}$"#, text),
              let tld = text.split(separator: ".").last, allowedTLDs.contains(String(tld)),
              !text.hasPrefix("-"), !text.contains("..") else { return nil }
        return safeURL(string: "https://\(text)")
    }

    // MARK: Local addresses

    static let maxPort = 65_535

    /// "localhost 3000", "localhost:8081", "127.0.0.1 8080 slash api" -> http://localhost:3000.
    /// Only for the owner's own words: the smart resolver's URL rule still refuses local hosts.
    static func localURL(fromSpoken spoken: String) -> URL? {
        let text = RioText.collapseWhitespace(spoken.lowercased().replacingOccurrences(of: ":", with: " ")
            .replacingOccurrences(of: "/", with: " slash "))
        let pattern = #"^(localhost|local\s+host|127\.0\.0\.1)\s+(?:port\s+)?(\d{1,5})((?:\s+(?:slash\s+)?[a-z0-9_-]+)*)(?:\s+slash)?$"#
        guard let groups = RioText.firstMatch(pattern, in: text), let hostWord = groups[1],
              let portText = groups[2], let port = Int(portText), (1...maxPort).contains(port) else { return nil }
        let host = hostWord == "127.0.0.1" ? "127.0.0.1" : "localhost"
        let segments = (groups[3] ?? "").split(separator: " ").map(String.init).filter { $0 != "slash" }
        let path = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
        return safeURL(string: "http://\(host):\(port)\(path)")
    }

    // MARK: Search

    static func googleSearchURL(query: String) -> URL? {
        searchURL(base: "https://www.google.com/search?q=", query: query)
    }

    static func youtubeSearchURL(query: String) -> URL? {
        searchURL(base: "https://www.youtube.com/results?search_query=", query: query)
    }

    static func amazonSearchURL(query: String) -> URL? {
        searchURL(base: "https://www.amazon.com/s?k=", query: query)
    }

    static func githubSearchURL(query: String) -> URL? {
        searchURL(base: "https://github.com/search?q=", query: query)
    }

    static func stackOverflowSearchURL(query: String) -> URL? {
        searchURL(base: "https://stackoverflow.com/search?q=", query: query)
    }

    static func netflixSearchURL(query: String) -> URL? {
        searchURL(base: "https://www.netflix.com/search?q=", query: query)
    }

    /// "open youtube and play X": the video site's own search, never Spotify. Nil when `site`
    /// is not the home page of a video site.
    static func videoSiteSearchURL(site: URL, query: String) -> URL? {
        guard let host = site.host?.lowercased(), site.path.isEmpty || site.path == "/", site.query == nil else { return nil }
        switch host {
        case "www.youtube.com", "youtube.com", "m.youtube.com": return youtubeSearchURL(query: query)
        case "www.netflix.com", "netflix.com": return netflixSearchURL(query: query)
        default: return nil
        }
    }

    private static func searchURL(base: String, query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return safeURL(string: base + encoded)
    }

    // MARK: Safety

    /// True only for http/https URLs with a host. The executor re-checks every URL it opens.
    static func isSafeWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return (url.host ?? "").isEmpty == false
    }

    private static func safeURL(string: String) -> URL? {
        guard let url = URL(string: string), isSafeWebURL(url) else { return nil }
        return url
    }
}

/// "go to amazon and search for headphones" is one site search, not "open the site, then Google
/// the words". Rewritten to "search amazon for headphones" before the clauses are split.
enum RioWebSearchRewrite {
    private static let pattern =
        #"\b(?:go\s+to|go\s+on|open|visit|navigate\s+to|take\s+me\s+to)\s+(?:the\s+)?(youtube|you\s?tube|amazon)(?:\.com)?\s*,?\s*(?:and|then)\s+(?:then\s+)?(?:search|look)(?:\s+for|\s+up)?\s+"#

    static func apply(to text: String) -> String {
        RioText.replacing(pattern, with: "search $1 for ", in: text)
    }
}
