import Foundation

/// How a spoken name matched an installed app, strongest first. The parser uses the kind to let
/// a well-known website beat a merely similar app name ("github" vs "GitHub Desktop").
enum AppNameMatchKind: Int, Equatable {
    case exact, alias, prefix, token, fuzzy

    var isStrong: Bool { self == .exact || self == .alias }
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

    /// Edit distance 1 (2 for long names) against app names and alias spellings; the first letter
    /// must agree and the closest app must be unique.
    private static func fuzzyMatch(_ key: String, in entries: [Entry]) -> InstalledApp? {
        guard key.count >= 5, let first = key.first else { return nil }
        let allowed = key.count >= 9 ? 2 : 1
        var best: [String: (app: InstalledApp, distance: Int)] = [:]
        func consider(_ candidate: String, app: InstalledApp) {
            guard candidate.first == first, abs(candidate.count - key.count) <= allowed else { return }
            let distance = RioText.editDistance(key, candidate)
            guard distance <= allowed else { return }
            let id = app.url.path
            if let existing = best[id], existing.distance <= distance { return }
            best[id] = (app, distance)
        }
        for entry in entries { consider(entry.compact, app: entry.app) }
        for (alias, target) in aliases {
            let wanted = RioText.compact(target)
            if let entry = entries.first(where: { $0.compact == wanted }) { consider(alias, app: entry.app) }
        }
        guard let minimum = best.values.map(\.distance).min() else { return nil }
        let closest = best.values.filter { $0.distance == minimum }
        return closest.count == 1 ? closest[0].app : nil
    }

    /// The one candidate; nil when none or when several apps fit (ambiguous).
    private static func onlyCandidate(_ candidates: [Entry]) -> InstalledApp? {
        candidates.count == 1 ? candidates[0].app : nil
    }
}
