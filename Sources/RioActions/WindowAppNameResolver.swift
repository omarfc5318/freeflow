import Foundation

/// Small private-purpose matcher that turns a spoken app name into one of the running apps'
/// names, for window control. Pure. Builder B's `AppNameMatcher` is for installed apps; this
/// one only ever sees the handful of apps that are running, so it stays strict and simple.
enum WindowAppNameResolver {
    private static let aliases: [String: String] = [
        "chrome": "google chrome",
        "vscode": "visual studio code",
        "vs code": "visual studio code",
        "code": "visual studio code",
        "settings": "system settings",
        "system preferences": "system settings",
        "imessage": "messages",
    ]

    /// Index into `names` of the best match, or nil. Order of preference: whole-name match,
    /// spoken words are the first words of the name, spoken words all appear in the name.
    /// Ties go to the shortest name, then the earliest in the list.
    static func bestMatchIndex(for spoken: String, in names: [String]) -> Int? {
        var query = normalize(spoken)
        guard !query.isEmpty else { return nil }
        if let canonical = aliases[query] { query = canonical }
        let queryTokens = query.split(separator: " ").map(String.init)
        let normalized = names.map(normalize)

        func pick(_ matches: (String, [String]) -> Bool) -> Int? {
            normalized.indices
                .filter { matches(normalized[$0], normalized[$0].split(separator: " ").map(String.init)) }
                .min { (normalized[$0].count, $0) < (normalized[$1].count, $1) }
        }
        return pick { name, _ in name == query }
            ?? pick { _, tokens in tokens.count >= queryTokens.count && Array(tokens.prefix(queryTokens.count)) == queryTokens }
            ?? pick { _, tokens in queryTokens.allSatisfy(tokens.contains) }
    }

    /// Lowercase, punctuation to spaces, collapsed, without a leading "the".
    static func normalize(_ text: String) -> String {
        let mapped = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        var words = String(mapped).split(separator: " ").map(String.init)
        if words.count > 1, words.first == "the" { words.removeFirst() }
        return words.joined(separator: " ")
    }
}
