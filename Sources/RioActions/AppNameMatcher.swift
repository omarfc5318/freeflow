import Foundation

/// How a spoken name matched an installed app, strongest first. The parser uses the kind to let
/// a well-known website beat a merely similar app name ("github" vs "GitHub Desktop").
enum AppNameMatchKind: Int, Equatable {
    case exact, alias, prefix, token, fuzzy, partial

    var isStrong: Bool { self == .exact || self == .alias }
    /// A mishearing or a part of a name is only a guess: the smart resolver gets the first say.
    var isConfident: Bool { self != .fuzzy && self != .partial }
}

struct AppNameMatch: Equatable {
    let app: InstalledApp
    let kind: AppNameMatchKind
}

/// Maps what Whisper heard ("Crome", "V S code", "settings") to an installed app. Deliberately
/// strict: an ambiguous or distant name matches nothing, so Rio says "I couldn't find X"
/// instead of opening the wrong app.
enum AppNameMatcher {
    /// Spoken name (letters and digits only) -> the app's display name.
    static let aliases: [String: String] = [
        "chrome": "Google Chrome", "googlechrome": "Google Chrome", "crome": "Google Chrome",
        "chrom": "Google Chrome", "crom": "Google Chrome", "krome": "Google Chrome",
        "vscode": "Visual Studio Code", "visualstudio": "Visual Studio Code",
        "vs": "Visual Studio Code", "code": "Visual Studio Code",
        "settings": "System Settings", "systempreferences": "System Settings",
        "preferences": "System Settings", "sysprefs": "System Settings",
        "imessage": "Messages", "message": "Messages", "texts": "Messages",
        "textmessages": "Messages", "sms": "Messages",
        "word": "Microsoft Word", "msword": "Microsoft Word",
        "excel": "Microsoft Excel", "powerpoint": "Microsoft PowerPoint",
        "ppt": "Microsoft PowerPoint", "outlook": "Microsoft Outlook",
        "teams": "Microsoft Teams", "onenote": "Microsoft OneNote",
        "email": "Mail", "mails": "Mail", "emails": "Mail",
        "ical": "Calendar", "calender": "Calendar",
        "applemusic": "Music", "itunes": "Music",
        "zoom": "zoom.us", "zoomus": "zoom.us",
        "appstore": "App Store", "photo": "Photos", "note": "Notes", "reminder": "Reminders",
        "iterm": "iTerm", "iterm2": "iTerm", "warpterminal": "Warp",
        "activitymonitor": "Activity Monitor",
        // Whisper hears "Claude" as "cloud" (owner report, 2026-11-03).
        "claude": "Claude", "cloud": "Claude", "clawed": "Claude", "claud": "Claude", "clod": "Claude",
        "cloude": "Claude", "claudeai": "Claude", "cloudai": "Claude", "claudedesktop": "Claude",
        "clouddesktop": "Claude", "claudeapp": "Claude", "cloudapp": "Claude",
        "claudecode": "Claude", "cloudcode": "Claude",
    ]

    static func bestMatch(for spoken: String, in apps: [InstalledApp]) -> InstalledApp? {
        match(for: spoken, in: apps)?.app
    }

    static func match(for spoken: String, in apps: [InstalledApp]) -> AppNameMatch? {
        let key = RioText.compact(spoken)
        guard !key.isEmpty, !apps.isEmpty else { return nil }
        // Sorted so the result never depends on the order apps were scanned in.
        let entries = apps
            .map { Entry(app: $0, compact: RioText.compact($0.name)) }
            .filter { !$0.compact.isEmpty }
            .sorted { ($0.app.name, $0.app.url.path) < ($1.app.name, $1.app.url.path) }

        if let hit = entries.first(where: { $0.compact == key }) {
            return AppNameMatch(app: hit.app, kind: .exact)
        }
        if let app = aliasTarget(for: key, in: entries) {
            return AppNameMatch(app: app, kind: .alias)
        }
        if let app = uniquePrefixMatch(key, in: entries) {
            return AppNameMatch(app: app, kind: .prefix)
        }
        if let app = uniqueTokenMatch(spoken, key: key, in: entries) {
            return AppNameMatch(app: app, kind: .token)
        }
        if let app = fuzzyMatch(key, in: entries) {
            return AppNameMatch(app: app, kind: .fuzzy)
        }
        if let app = uniqueCamelPartMatch(spoken, key: key, in: entries) {
            return AppNameMatch(app: app, kind: .partial)
        }
        return nil
    }

    // MARK: Stages

    private struct Entry {
        let app: InstalledApp
        let compact: String
    }

    private static func aliasTarget(for key: String, in entries: [Entry]) -> InstalledApp? {
        guard let target = aliases[key] else { return nil }
        let wanted = RioText.compact(target)
        return entries.first(where: { $0.compact == wanted })?.app
    }

    /// A prefix of at least four letters that points at exactly one app.
    private static func uniquePrefixMatch(_ key: String, in entries: [Entry]) -> InstalledApp? {
        guard key.count >= 4 else { return nil }
        return onlyCandidate(entries.filter { $0.compact.hasPrefix(key) })
    }

    /// Every spoken word is a whole word of the app name ("studio code" in "Visual Studio Code").
    private static func uniqueTokenMatch(_ spoken: String, key: String, in entries: [Entry]) -> InstalledApp? {
        guard key.count >= 4 else { return nil }
        let spokenTokens = tokens(spoken)
        guard !spokenTokens.isEmpty else { return nil }
        let candidates = entries.filter { entry in
            let nameTokens = tokens(entry.app.name)
            return spokenTokens.allSatisfy { nameTokens.contains($0) }
        }
        return onlyCandidate(candidates)
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Edit distance 1 (2 for long names) against real app names only; the first letter must
    /// agree and the closest app must be unique. Aliases need an exact hit: "tests" is one edit
    /// from the alias "texts", and "run the tests" must never open Messages.
    private static func fuzzyMatch(_ key: String, in entries: [Entry]) -> InstalledApp? {
        guard let id = uniqueFuzzyID(key, among: entries.map { (id: $0.app.url.path, name: $0.compact) }) else { return nil }
        return entries.first { $0.app.url.path == id }?.app
    }

    /// The same mishearing rule for any list of compact names (RioWebURLs' sites use it too):
    /// at least five letters, the first letter agrees, edit distance 1 (2 for nine letters or
    /// more), and the closest candidate is unique. Each name carries an id (one per real thing, so
    /// two names for one site never make it ambiguous); several names may share an id.
    static func uniqueFuzzyID(_ key: String, among names: [(id: String, name: String)]) -> String? {
        guard key.count >= 5, let first = key.first else { return nil }
        let allowed = key.count >= 9 ? 2 : 1
        var best: [String: Int] = [:]
        for (id, candidate) in names {
            guard candidate.first == first, abs(candidate.count - key.count) <= allowed else { continue }
            let distance = RioText.editDistance(key, candidate)
            guard distance <= allowed else { continue }
            if let existing = best[id], existing <= distance { continue }
            best[id] = distance
        }
        guard let minimum = best.values.min() else { return nil }
        let closest = best.filter { $0.value == minimum }
        return closest.count == 1 ? closest.first?.key : nil
    }

    /// "edit" for "TextEdit": one spoken word that is a whole camel-case part of exactly one app.
    private static func uniqueCamelPartMatch(_ spoken: String, key: String, in entries: [Entry]) -> InstalledApp? {
        guard key.count >= 4, tokens(spoken).count == 1 else { return nil }
        return onlyCandidate(entries.filter { entry in
            let parts = camelParts(entry.app.name)
            return parts.count >= 2 && parts.contains(key)
        })
    }

    /// "TextEdit" -> ["text", "edit"]; "GitHub Desktop" -> ["git", "hub", "desktop"].
    static func camelParts(_ name: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var previousWasLower = false
        for character in name {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { parts.append(current.lowercased()) }
                current = ""
                previousWasLower = false
                continue
            }
            if character.isUppercase, previousWasLower, !current.isEmpty {
                parts.append(current.lowercased())
                current = ""
            }
            current.append(character)
            previousWasLower = character.isLowercase || character.isNumber
        }
        if !current.isEmpty { parts.append(current.lowercased()) }
        return parts
    }

    /// The one candidate; nil when none or when several apps fit (ambiguous).
    private static func onlyCandidate(_ candidates: [Entry]) -> InstalledApp? {
        candidates.count == 1 ? candidates[0].app : nil
    }
}
