import Foundation

enum AppNameMatcherTests {
    private static let apps = RioActionParserTests.apps

    private static func name(_ spoken: String, in list: [InstalledApp] = apps) -> String? {
        AppNameMatcher.bestMatch(for: spoken, in: list)?.name
    }

    static func run() {
        var failures: [String] = []
        func check(_ spoken: String, _ expected: String?, in list: [InstalledApp] = apps) {
            let actual = name(spoken, in: list)
            if actual != expected { failures.append("\"\(spoken)\": expected \(expected ?? "nil"), got \(actual ?? "nil")") }
        }

        // Aliases
        check("chrome", "Google Chrome"); check("Chrome", "Google Chrome")
        check("google chrome", "Google Chrome")
        check("vs code", "Visual Studio Code"); check("V S code", "Visual Studio Code")
        check("vscode", "Visual Studio Code"); check("code", "Visual Studio Code")
        check("settings", "System Settings"); check("system preferences", "System Settings")
        check("imessage", "Messages"); check("messages", "Messages")
        check("word", "Microsoft Word"); check("zoom", "zoom.us")
        check("email", "Mail"); check("terminal", "Terminal")
        // Exact, case and punctuation insensitive
        check("SPOTIFY", "Spotify"); check("spotify.", "Spotify"); check("face time", "FaceTime")
        check("text edit", "TextEdit"); check("granola", "Granola")
        // Prefix and token
        check("spot", "Spotify"); check("visual", "Visual Studio Code")
        check("studio code", "Visual Studio Code"); check("system", "System Settings")
        // Fuzzy mishearings
        check("Crome", "Google Chrome"); check("spotfy", "Spotify"); check("calender", "Calendar")
        check("slick", "Slack"); check("messges", "Messages")
        // Strictness: nothing near, too short, or ambiguous
        check("maps", "Maps"); check("map", nil); check("mail", "Mail")
        check("zorblax", nil); check("", nil); check("   ", nil); check("a", nil)
        check("microsoft", nil)
        check("spy", nil)
        // "Mail" must never be offered for "Maps" or vice versa when the other isn't installed
        let onlyMail = apps.filter { $0.name == "Mail" }
        let onlyMaps = apps.filter { $0.name == "Maps" }
        check("maps", nil, in: onlyMail)
        check("mail", nil, in: onlyMaps)
        check("chrome", nil, in: onlyMail)
        check("chrome", nil, in: [])
        // Deterministic: input order must not matter
        let a = AppNameMatcher.bestMatch(for: "micro", in: apps.reversed())
        let b = AppNameMatcher.bestMatch(for: "micro", in: apps)
        if a != b { failures.append("order-dependent result for \"micro\"") }
        // Match kinds drive website-vs-app precedence
        TestSupport.expectEqual(AppNameMatcher.match(for: "chrome", in: apps)?.kind, .alias)
        TestSupport.expectEqual(AppNameMatcher.match(for: "spotify", in: apps)?.kind, .exact)
        TestSupport.expectEqual(AppNameMatcher.match(for: "github", in: apps)?.kind, .prefix)
        TestSupport.expectEqual(AppNameMatcher.match(for: "slick", in: apps)?.kind, .fuzzy)
        // Edit distance and numbers
        TestSupport.expectEqual(RioText.editDistance("chrome", "crome"), 1)
        TestSupport.expectEqual(RioText.editDistance("chrome", "chrmoe"), 1)
        TestSupport.expectEqual(RioText.editDistance("", "abc"), 3)
        TestSupport.expectEqual(RioText.number(from: "forty five"), 45)
        TestSupport.expectEqual(RioText.number(from: "a hundred"), 100)
        TestSupport.expectEqual(RioText.number(from: "banana"), nil)

        TestSupport.expect(failures.isEmpty, "\(failures.count) matcher failures:\n" + failures.joined(separator: "\n"))
    }
}
