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

/// The app Rio itself just opened, switched to or arranged. "Move this window to the left"
/// right after Rio opened TextEdit means TextEdit's window, even when focus churn has already put
/// the owner's chat or editor back in front (review F29/F30). Pure and in memory only.
final class RioRecentWindowTarget: @unchecked Sendable {
    static let shared = RioRecentWindowTarget()
    /// How long the app Rio touched stays the target of an unnamed window command.
    static let lifetime: TimeInterval = 45

    struct Entry: Equatable {
        let processIdentifier: Int32
        let name: String
        let at: Date
    }

    private let lock = NSLock()
    private var entry: Entry?

    init() {}

    func note(processIdentifier: Int32, name: String, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        entry = Entry(processIdentifier: processIdentifier, name: name, at: now)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entry = nil
    }

    /// The app to use when a window command names none, or nil to use the frontmost app.
    /// `isUsable` says whether the process still runs, visible, as a regular app.
    func current(now: Date = Date(), isUsable: (Int32) -> Bool) -> Entry? {
        lock.lock()
        let found = entry
        lock.unlock()
        guard let found, now.timeIntervalSince(found.at) >= 0, now.timeIntervalSince(found.at) <= Self.lifetime,
              isUsable(found.processIdentifier) else { return nil }
        return found
    }
}
