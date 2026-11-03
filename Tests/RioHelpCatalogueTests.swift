import Foundation

/// The help sheet must never promise something Rio can't parse.
enum RioHelpCatalogueTests {
    private static let apps = ["Google Chrome", "Spotify", "Messages", "Slack", "Notes", "Safari"].map {
        InstalledApp(name: $0, bundleIdentifier: nil, url: URL(fileURLWithPath: "/Applications/\($0).app"))
    }

    /// Categories whose every example is understood by the local parser in this package (B's
    /// parser plus the voice phrases). The others belong to wave 2 builders whose phrase files
    /// are separate, so only their shape is checked here.
    private static let locallyParsed: Set<String> = [
        "Apps and websites", "Mac controls", "Windows", "Timers", "Undo and help",
    ]

    static func run() {
        testEveryCategoryHasExamples()
        testCatalogueCoversTheAbilities()
        testExamplesParse()
        testSpokenSummary()
        testHelpPhrases()
    }

    private static func testEveryCategoryHasExamples() {
        TestSupport.expect(RioHelpCatalogue.categories.count >= 8, "a real catalogue")
        var titles = Set<String>()
        for category in RioHelpCatalogue.categories {
            TestSupport.expect(!category.title.isEmpty, "title")
            TestSupport.expect(!category.symbol.isEmpty, "\(category.title) has an icon")
            TestSupport.expect(category.examples.count >= 3, "\(category.title) needs examples")
            TestSupport.expect(category.examples.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }, "blank example")
            TestSupport.expect(titles.insert(category.title).inserted, "duplicate category \(category.title)")
            TestSupport.expect(category.examples.count <= 6, "\(category.title) stays glanceable")
        }
    }

    private static func testCatalogueCoversTheAbilities() {
        let titles = Set(RioHelpCatalogue.categories.map(\.title))
        for needed in locallyParsed.union(["Keys and browser", "Files and calendar", "Smart help"]) {
            TestSupport.expect(titles.contains(needed), "missing category \(needed)")
        }
    }

    private static func testExamplesParse() {
        let parser = RioActionParser(installedApps: apps)
        for category in RioHelpCatalogue.categories where locallyParsed.contains(category.title) {
            for example in category.examples {
                switch parser.parse(example) {
                case .actions: break
                default: TestSupport.expect(false, "help example \"\(example)\" (\(category.title)) isn't understood")
                }
            }
        }
    }

    private static func testSpokenSummary() {
        let line = RioHelpCatalogue.spokenSummary
        TestSupport.expect(!line.isEmpty && line.count < 140, "one short line: \(line)")
        TestSupport.expect(line.lowercased().contains("timer"), "mentions a headline ability")
    }

    private static func testHelpPhrases() {
        let yes = [
            "help", "help me", "what can you do", "what can I say", "what can I ask you", "what are your commands",
            "show help", "show me what you can do", "what commands do you know", "show commands", "show me the help",
        ]
        for text in yes {
            let parsed = RioVoicePhrases.parse(raw: text, simplified: RioText.simplify(text))
            TestSupport.expectEqualNamed(parsed, .showHelp, "help phrase \"\(text)\"")
        }
        let no = [
            "help me write an email", "what can you do with this selection", "open help", "help wanted",
            "what can I do about this", "show me the way",
        ]
        for text in no {
            TestSupport.expect(
                RioVoicePhrases.parse(raw: text, simplified: RioText.simplify(text)) != .showHelp,
                "\"\(text)\" is not a help request"
            )
        }
    }
}
