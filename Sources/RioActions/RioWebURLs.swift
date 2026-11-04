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
        // School
        "gradescope": "https://www.gradescope.com",
        "piazza": "https://piazza.com",
        "overleaf": "https://www.overleaf.com",
        "desmos": "https://www.desmos.com/calculator",
        "wolframalpha": "https://www.wolframalpha.com",
        "wolfram": "https://www.wolframalpha.com",
        "quizlet": "https://quizlet.com",
        "khanacademy": "https://www.khanacademy.org",
        "leetcode": "https://leetcode.com",
        "edstem": "https://edstem.org",
        // Developer
        "vercel": "https://vercel.com",
        "verceldashboard": "https://vercel.com/dashboard",
        "supabase": "https://supabase.com",
        "supabasedashboard": "https://supabase.com/dashboard",
        "linear": "https://linear.app",
        "cloudflare": "https://dash.cloudflare.com",
        "cloudflaredashboard": "https://dash.cloudflare.com",
        "stripe": "https://stripe.com",
        "stripedashboard": "https://dashboard.stripe.com",
        "netlify": "https://app.netlify.com",
        "gitlab": "https://gitlab.com",
        "npm": "https://www.npmjs.com",
        "npmjs": "https://www.npmjs.com",
    ]

    static func knownSite(compactName: String) -> URL? {
        knownSites[compactName].flatMap { URL(string: $0) }
    }

    static func isKnownSite(spoken: String) -> Bool {
        knownSites[RioText.compact(spoken)] != nil
    }

    /// Real names of something else, never a mishearing of a site: "canvas" (the school site, when
    /// one is set up) is not Canva.
    private static let fuzzyExclusions: Set<String> = ["canvas"]

    /// A known site that `compactName` is one mishearing away from ("spotfy", "piaza" from "pia
    /// za"), by the rule installed apps use (`AppNameMatcher.uniqueFuzzyID`). `extra` adds the
    /// owner's own sites (Canvas). Nil for an exact name, an excluded word or an ambiguous one.
    static func fuzzySite(compactName: String, extra: [String: URL] = [:]) -> URL? {
        let key = compactName.lowercased()
        guard knownSites[key] == nil, extra[key] == nil, !fuzzyExclusions.contains(key) else { return nil }
        var urls: [String: URL] = [:]
        var names: [(id: String, name: String)] = []
        for (name, text) in knownSites {
            guard let url = URL(string: text) else { continue }
            urls[url.absoluteString] = url
            names.append((url.absoluteString, name))
        }
        for (name, url) in extra {
            urls[url.absoluteString] = url
            names.append((url.absoluteString, name))
        }
        return AppNameMatcher.uniqueFuzzyID(key, among: names).flatMap { urls[$0] }
    }

    // MARK: Spoken domains

    static let allowedTLDs: Set<String> = [
        "com", "org", "net", "io", "co", "ai", "app", "dev", "edu", "gov", "me", "tv", "us", "uk",
        "qa", "ae", "sa", "info", "xyz", "fm", "gg", "ly", "so", "sh", "to", "in", "de", "fr",
        "ca", "au", "news", "tech", "online", "store", "site", "page", "club", "cloud", "design",
    ]

    /// "hala discover dot com" -> https://haladiscover.com; "github.com" -> https://github.com;
    /// "github dot com slash vercel slash next dot js" -> https://github.com/vercel/next.js.
    /// Nil unless the text is a host name with a known top-level domain, optionally followed by
    /// a path. A spoken host ("dot com") needs "slash" before each path segment; a written one
    /// ("github.com/ofarhan", whose slashes the parser turned into spaces) takes the words as is.
    static func domainURL(fromSpoken spoken: String) -> URL? {
        let original = RioText.collapseWhitespace(spoken.trimmingCharacters(in: .whitespacesAndNewlines))
        let isWritten = !RioText.matches(#"(?:^|\s)dot(?:\s|$)"#, original)
        let text = RioText.replacing(#"\s+dot\s+"#, with: ".", in: original)
        guard text.contains("."),
              let groups = RioText.firstMatch(#"^(.+?\.[A-Za-z]{2,24})(?:\s+(.+))?$"#, in: text),
              let hostWords = groups[1] else { return nil }
        let host = hostWords.lowercased().replacingOccurrences(of: " ", with: "")
        guard RioText.matches(#"^(?:[a-z0-9-]+\.)+[a-z]{2,24}$"#, host),
              let tld = host.split(separator: ".").last, allowedTLDs.contains(String(tld)),
              !host.hasPrefix("-"), !host.contains("..") else { return nil }
        guard let rest = groups[2] else { return safeURL(string: "https://\(host)") }
        guard let path = path(fromSpoken: rest, isWritten: isWritten) else { return nil }
        return safeURL(string: "https://\(host)\(path)")
    }

    /// "slash vercel slash next.js" -> "/vercel/next.js". Nil for anything that is not a plain path.
    private static func path(fromSpoken rest: String, isWritten: Bool) -> String? {
        let tokens = rest.split(separator: " ").map(String.init)
        var segments: [String]
        if tokens.contains(where: { $0.lowercased() == "slash" }) {
            guard tokens.first?.lowercased() == "slash" else { return nil }
            segments = []
            var current = ""
            for token in tokens.dropFirst() {
                if token.lowercased() == "slash" {
                    if !current.isEmpty { segments.append(current) }
                    current = ""
                } else {
                    current += token
                }
            }
            if !current.isEmpty { segments.append(current) }
        } else {
            guard isWritten else { return nil }
            segments = tokens
        }
        guard !segments.isEmpty, segments.count <= 8,
              segments.allSatisfy({ RioText.matches(#"^[A-Za-z0-9._~-]{1,80}$"#, $0) && $0 != "." && $0 != ".." }) else { return nil }
        return "/" + segments.joined(separator: "/")
    }

    /// The spoken URL after "open"/"go to" written out, so the clause stays one short target:
    /// "open github dot com slash vercel slash next dot js" -> "open github.com/vercel/next.js",
    /// "open linear dot app" -> "open linear.app" (the trailing "app" is not an app suffix).
    static func writingSpokenURLs(in text: String) -> String {
        let verb = #"(?:open(?:\s+up)?|go\s+to|visit|navigate\s+to|take\s+me\s+to|pull\s+up|bring\s+up|load)"#
        let host = #"((?:[A-Za-z0-9-]+\s+){0,3}?[A-Za-z0-9-]+(?:\s+dot\s+[A-Za-z0-9-]+)*\s+dot\s+([A-Za-z]{2,24}))"#
        let path = #"((?:\s+slash\s+[A-Za-z0-9._~-]+(?:\s+dot\s+[A-Za-z0-9_~-]+)*)*)(?:\s+slash)?"#
        let pattern = #"((?:^|\b(?:and|then)\s+|[,;]\s*)"# + verb + #"\s+(?:the\s+)?(?:web\s?site\s+|site\s+)?)"# + host + path
            + #"(?=\s+(?:and|then)\b|\s*[,.;!?]|\s*$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: text), let lead = Range(match.range(at: 1), in: text),
                  let hostRange = Range(match.range(at: 2), in: text), let tldRange = Range(match.range(at: 3), in: text),
                  allowedTLDs.contains(text[tldRange].lowercased()) else { continue }
            let written = RioText.replacing(#"\s+dot\s+"#, with: ".", in: String(text[hostRange])).replacingOccurrences(of: " ", with: "")
            var pathText = ""
            if let pathRange = Range(match.range(at: 4), in: text) {
                let segments = String(text[pathRange]).components(separatedBy: "slash").map {
                    RioText.replacing(#"\s+dot\s+"#, with: ".", in: $0).replacingOccurrences(of: " ", with: "")
                }.filter { !$0.isEmpty }
                if !segments.isEmpty { pathText = "/" + segments.joined(separator: "/") }
            }
            result.replaceSubrange(whole, with: String(text[lead]) + written + pathText)
        }
        return result
    }

    // MARK: Local addresses

    static let maxPort = 65_535

    /// "localhost 3000", "localhost:8081", "127.0.0.1 8080 slash api" -> http://localhost:3000.
    /// Only for the owner's own words: the smart resolver's URL rule still refuses local hosts.
    static func localURL(fromSpoken spoken: String) -> URL? {
        let spokenColon = RioText.replacing(#"\s+colon\s+"#, with: " ", in: spoken.lowercased())
        let text = RioText.collapseWhitespace(spokenColon.replacingOccurrences(of: ":", with: " ")
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
        #"\b(?:go\s+to|go\s+on|open|visit|navigate\s+to|take\s+me\s+to)\s+(?:the\s+)?(youtube|you\s?tube|amazon)(?:\.com|\s+dot\s+com)?\s*,?\s*(?:and|then)\s+(?:then\s+)?(?:search|look)(?:\s+for|\s+up)?\s+"#

    static func apply(to text: String) -> String {
        RioWebURLs.writingSpokenURLs(in: RioText.replacing(pattern, with: "search $1 for ", in: text))
    }
}
