import Foundation

// Pure web rules shared by the multi-step agent and the smart resolver: which hosts the agent may
// never open, what counts as the same site, and which text fields are browser chrome (the
// address bar) rather than part of a page. Foundation only.

enum RioWebHostRules {
    /// Loopback, link-local and private addresses: Rio browses the public web only. Any IP
    /// literal (dotted, decimal, hex, octal, short or IPv6) is refused outright: the host must be
    /// a name ending in an alphabetic top-level domain.
    static func isLocalHost(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" || localSuffixes.contains(where: { host.hasSuffix("." + $0) }) { return true }
        if host.contains(":") || host.contains("[") { return true }
        // Best effort: public wildcard-DNS services that resolve to any IP written in the name
        // (127.0.0.1.nip.io). A real DNS check would still race; these are the well-known ones.
        if wildcardDNSSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        guard let tld = host.split(separator: ".").last, tld.count >= 2, tld.allSatisfy({ $0.isLetter && $0.isASCII }) else {
            return true
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (127, _), (10, _), (0, _), (169, 254), (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    /// Names only a home or office network resolves (none is a public top-level domain).
    private static let localSuffixes = [
        "local", "localhost", "internal", "home.arpa", "lan", "home", "corp", "intranet", "private",
    ]

    private static let wildcardDNSSuffixes = [
        "nip.io", "sslip.io", "xip.io", "localtest.me", "lvh.me", "vcap.me", "traefik.me",
        "localhost.direct", "lacolhost.com", "127.0.0.1.nip.io",
    ]

    /// Shared hosting where every customer is a separate site (alice.github.io ≠ mallory.github.io).
    private static let sharedHostingSuffixes = [
        "github.io", "gitlab.io", "vercel.app", "netlify.app", "pages.dev", "workers.dev", "web.app",
        "firebaseapp.com", "herokuapp.com", "onrender.com", "fly.dev", "glitch.me", "repl.co",
        "blogspot.com", "wordpress.com", "azurewebsites.net", "cloudfront.net", "appspot.com",
        "s3.amazonaws.com", "notion.site", "carrd.co", "wixsite.com", "squarespace.com",
    ]

    private static let secondLevelLabels: Set<String> = ["co", "com", "org", "net", "gov", "edu", "ac", "or", "ne"]

    /// "www.shop.example.co.uk" -> "example.co.uk". No public-suffix list: the common two-letter
    /// country domains with a generic second level are handled, everything else is last two labels.
    static func registrableDomain(_ host: String) -> String {
        var host = host.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        let labels = host.split(separator: ".").map(String.init)
        if let shared = sharedHostingSuffixes.first(where: { host.hasSuffix("." + $0) }) {
            let keep = shared.split(separator: ".").count + 1
            return labels.suffix(keep).joined(separator: ".")
        }
        guard labels.count > 2 else { return host }
        let tld = labels[labels.count - 1], second = labels[labels.count - 2]
        let keep = (tld.count == 2 && secondLevelLabels.contains(second)) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }

    /// Host without a leading "www.", lowercased.
    static func bareHost(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
    }

    /// Scheme plus registrable domain (plus a non-default port). Two pages with the same key are
    /// treated as the same site.
    static func originKey(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return scheme + "://" }
        let port = url.port.map { ":\($0)" } ?? ""
        return scheme + "://" + registrableDomain(host) + port
    }

    /// Whether the user's goal names this host: its registrable domain ("kayak.com") or its main
    /// name as a word ("kayak").
    static func goalMentions(host: String, goal: String) -> Bool {
        let lowerGoal = goal.lowercased()
        let domain = registrableDomain(host)
        if lowerGoal.contains(domain) { return true }
        // The bare name ("amazon") only counts for its .com site; any other domain must be named in
        // full ("amazon.ae"), so amazon.xyz or amazon.evil.io never pass as the site you meant.
        guard let name = domain.split(separator: ".").first.map(String.init), name.count >= 3,
              domain == name + ".com" else { return false }
        return RioText.matches(#"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: name) + #"(?![\p{L}\p{N}])"#, lowerGoal)
    }
}

enum RioBrowserChrome {
    private static let addressIdentifiers: Set<String> = [
        "web_browser_address_and_search_field",  // Safari
        "urlbar-input", "urlbar", "urlbar-container",  // Firefox
    ]
    private static let addressLabelPattern =
        #"(?i)(?:address\s+and\s+search\s+bar|address\s+bar|enter\s+(?:web\s+)?address|smart\s+search\s+field|url\s*bar|location\s+bar|"#
        + #"(?:type|enter)\s+(?:a\s+)?url|search\s+or\s+(?:type|enter)|omnibox|search\s+with\s+\w+\s+or\s+enter)"#

    /// Whether a text field is a browser's address (and search) field, from its AXIdentifier and
    /// any of its texts (title, description, placeholder, help). Callers apply this to fields
    /// outside any AXWebArea only: a page's own "Enter address" input is not browser chrome.
    static func isAddressField(identifier: String?, texts: [String]) -> Bool {
        if let identifier, addressIdentifiers.contains(identifier.lowercased()) { return true }
        return texts.contains { RioText.matches(addressLabelPattern, $0) }
    }
}
