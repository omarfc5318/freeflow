import Foundation

/// Spoken file requests: query parsing, the Spotlight predicates and ranking of synthetic results.
/// Nothing here touches the real file index.
enum RioFilesTests {
    private static let home = "/Users/test"
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static func ago(days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    static func run() {
        queryParsing()
        folders()
        nameMatching()
        predicates()
        ranking()
        eligibility()
        safety()
    }

    private static func safety() {
        for path in ["/x/Setup.app", "/x/run.command", "/x/install.sh", "/x/Tool.PKG", "/x/a.dmg", "/x/task.workflow", "/x/m.scpt"] {
            TestSupport.expect(RioFileRanker.isRiskyToOpen(path: path, isDirectory: false, isExecutable: false), "\(path) is risky")
        }
        for path in ["/x/Resume.pdf", "/x/notes.txt", "/x/deck.key"] {
            TestSupport.expect(!RioFileRanker.isRiskyToOpen(path: path, isDirectory: false, isExecutable: true), "\(path) is fine")
        }
        TestSupport.expect(RioFileRanker.isRiskyToOpen(path: "/x/mybinary", isDirectory: false, isExecutable: true), "bare executable")
        TestSupport.expect(!RioFileRanker.isRiskyToOpen(path: "/x/folder", isDirectory: true, isExecutable: true), "folders are fine")
        TestSupport.expect(!RioFileRanker.isRiskyToOpen(path: "/x/README", isDirectory: false, isExecutable: false), "plain file without extension")
    }

    private static func q(_ spoken: String) -> RioFileQuery { RioFileQuery.parse(spoken) }

    private static func queryParsing() {
        let resume = q("resume")
        TestSupport.expectEqual(resume.coreTokens, ["resume"])
        TestSupport.expect(resume.types.isEmpty && !resume.preferRecent, "plain resume")

        let hw = q("MAT108 homework 6 PDF")
        TestSupport.expectEqual(hw.coreTokens, ["mat", "108", "homework", "6"])
        TestSupport.expectEqual(hw.types, [.pdf])

        let spoken = q("MAT108 homework six PDF")
        TestSupport.expectEqual(spoken.coreTokens, ["mat", "108", "homework", "6"])

        let deck = q("Hala deck")
        TestSupport.expectEqual(deck.coreTokens, ["hala"])
        TestSupport.expectEqual(deck.softTokens, ["deck"])
        TestSupport.expect(deck.types.contains(.slides) && deck.types.contains(.pdf), "deck means slides or pdf")

        let latest = q("latest PDF")
        TestSupport.expect(latest.coreTokens.isEmpty && latest.preferRecent && latest.types == [.pdf], "latest pdf")

        let dotted = q("resume.pdf")
        TestSupport.expectEqual(dotted.coreTokens, ["resume"])
        TestSupport.expectEqual(dotted.types, [.pdf])
        TestSupport.expectEqual(q("Hala pitch deck").coreTokens, ["hala", "pitch"])
        TestSupport.expectEqual(q("tax return").coreTokens, ["tax", "return"])
        TestSupport.expectEqual(q("invoice from Apple").coreTokens, ["invoice", "apple"])
        TestSupport.expectEqual(q("ECS119 syllabus").coreTokens, ["ecs", "119", "syllabus"])
        TestSupport.expectEqual(q("my \u{201C}Résumé\u{201D}").coreTokens, ["resume"])
        TestSupport.expectEqual(q("the word document about visas").types, [.word])
        TestSupport.expectEqual(q("budget spreadsheet").types, [.sheet])
        TestSupport.expectEqual(q("budget spreadsheet").coreTokens, ["budget"])
        TestSupport.expectEqual(q("the slides for chapter 3").coreTokens, ["chapter", "3"])
        TestSupport.expectEqual(q("the slides for chapter 3").softTokens, ["slides"])
        TestSupport.expectEqual(q("most recent screenshot").preferRecent, true)
        TestSupport.expect(q("").isEmpty, "empty query")
        TestSupport.expect(q("the").isEmpty, "stop words only")
    }

    private static func folders() {
        let cases: [(String, RioWellKnownFolder?)] = [
            ("downloads folder", .downloads), ("Downloads", .downloads), ("my downloads", .downloads),
            ("documents", .documents), ("documents folder", .documents), ("desktop", .desktop),
            ("home folder", .home), ("home", nil), ("my home", nil), ("pictures folder", .pictures), ("movies folder", .movies),
            ("music folder", .music), ("iCloud Drive folder", .iCloudDrive), ("iCloud Drive", .iCloudDrive),
            ("applications folder", .applications),
            ("music", nil), ("pictures", nil), ("resume", nil), ("documents about visas", nil), ("downloads of Hala", nil),
        ]
        for (text, expected) in cases {
            TestSupport.expectEqual(RioWellKnownFolder.match(spoken: text), expected)
        }
        TestSupport.expectEqual(RioWellKnownFolder.downloads.path(home: home), "/Users/test/Downloads")
        TestSupport.expectEqual(RioWellKnownFolder.home.path(home: home), "/Users/test")
        TestSupport.expectEqual(
            RioWellKnownFolder.iCloudDrive.path(home: home),
            "/Users/test/Library/Mobile Documents/com~apple~CloudDocs"
        )
        TestSupport.expectEqual(RioWellKnownFolder.applications.path(home: home), "/Applications")
    }

    private static func nameMatching() {
        let hw = q("MAT108 homework 6")
        TestSupport.expect(RioFileRanker.nameMatches("MAT108_HW6.pdf", query: hw), "hw alias and digit boundary")
        TestSupport.expect(RioFileRanker.nameMatches("MAT 108 Homework 06 Solutions.pdf", query: hw), "leading zero and spaces")
        TestSupport.expect(RioFileRanker.nameMatches("mat108-homework6.pdf", query: hw), "letter digit boundary")
        TestSupport.expect(!RioFileRanker.nameMatches("MAT108_HW16.pdf", query: hw), "6 is not 16")
        TestSupport.expect(RioFileRanker.nameMatches("HW6.pdf", parent: "MAT108", query: hw), "words may come from the folder name")
        TestSupport.expect(!RioFileRanker.nameMatches("HW6.pdf", parent: "ECS119", query: hw), "wrong folder")
        TestSupport.expect(!RioFileRanker.nameMatches("MAT108_HW6_old.pdf", query: q("MAT108 homework 5")), "wrong number")
        TestSupport.expect(!RioFileRanker.nameMatches("ECS119_HW6.pdf", query: hw), "wrong course")
        TestSupport.expect(RioFileRanker.nameMatches("Omar_Resume_R25.pdf", query: q("resume")), "resume in a longer name")
        TestSupport.expect(RioFileRanker.nameMatches("Omar CV 2026.pdf", query: q("resume")), "cv alias")
        TestSupport.expect(RioFileRanker.nameMatches("R\u{E9}sum\u{E9}.docx", query: q("resume")), "diacritics fold")
        TestSupport.expect(RioFileRanker.nameMatches("Hala_PitchDeck_Aug2026.pdf", query: q("Hala deck")), "camel case split")
        TestSupport.expect(RioFileRanker.nameMatches("Hala_Brochure.pdf", query: q("Hala deck")), "soft tokens are not required")
        TestSupport.expect(!RioFileRanker.nameMatches("Halal_Brochure.pdf", query: q("Hala deck")), "hala is not halal")
        TestSupport.expect(RioFileRanker.nameMatches("Tax Returns 2025.pdf", query: q("tax return")), "plural")
        TestSupport.expect(RioFileRanker.nameMatches("anything.pdf", query: q("latest PDF")), "no core tokens: anything matches")
        TestSupport.expectEqual(RioFileRanker.tokens(of: "MAT108_HW6.pdf"), ["mat", "108", "hw", "6"])
        TestSupport.expectEqual(RioFileRanker.tokens(of: "Hala_PitchDeck_Aug2026.pdf"), ["hala", "pitch", "deck", "aug", "2026"])
        TestSupport.expectEqual(RioFileRanker.tokens(of: "notes.v2.final.txt"), ["notes", "v", "2", "final"])
    }

    private static func predicates() {
        let hw = RioSpotlightPredicates.nameFormat(for: q("MAT108 homework 6"))
        TestSupport.expect(hw != nil, "name predicate exists")
        let text = hw ?? ""
        for expected in [
            "kMDItemFSName CONTAINS[cd] \"mat\"", "kMDItemFSName CONTAINS[cd] \"108\"",
            "kMDItemFSName CONTAINS[cd] \"homework\"", "kMDItemFSName CONTAINS[cd] \"hw\"",
            "kMDItemFSName CONTAINS[cd] \"6\"", " AND ", " OR ",
        ] {
            TestSupport.expect(text.contains(expected), "predicate '\(text)' should contain \(expected)")
        }
        // Only the extension constraint when there are no name words.
        let latest = RioSpotlightPredicates.nameFormat(for: q("latest PDF")) ?? ""
        TestSupport.expect(latest.contains("ENDSWITH[cd] \".pdf\""), "pdf constraint: \(latest)")
        TestSupport.expect(RioSpotlightPredicates.nameFormat(for: q("")) == nil, "empty query has no predicate")
        // Content search: words of 3+ letters, never a bare digit.
        let content = RioSpotlightPredicates.contentFormat(for: q("MAT108 homework 6")) ?? ""
        TestSupport.expect(content.contains("kMDItemTextContent CONTAINS[cd] \"homework\""), "content: \(content)")
        TestSupport.expect(!content.contains("\"6\""), "no single digit content term: \(content)")
        TestSupport.expect(RioSpotlightPredicates.contentFormat(for: q("latest PDF")) == nil, "no words, no content search")
        // A quote in a spoken word can't break out of the predicate.
        let hostile = RioSpotlightPredicates.nameFormat(for: q("a\" OR kMDItemFSName != \"")) ?? ""
        TestSupport.expect(!hostile.contains("!="), "hostile text is dropped to tokens: \(hostile)")
    }

    private static func file(_ path: String, used: Double? = nil, modified: Double? = nil, dir: Bool = false) -> RioFileCandidate {
        RioFileCandidate(path: home + path, lastUsed: used.map(ago), modified: modified.map(ago), isDirectory: dir)
    }

    private static func names(_ ranked: [RioFileCandidate]) -> [String] {
        ranked.map { ($0.path as NSString).lastPathComponent }
    }

    private static func ranking() {
        let hw = q("MAT108 homework 6 PDF")
        let candidates = [
            file("/Downloads/MAT108_HW6.pdf", used: 30),
            file("/Documents/MAT108/HW6.pdf", used: 2),
            file("/Documents/MAT108/MAT108_HW6_solutions.docx", used: 1),
            file("/Documents/MAT108/MAT108_HW16.pdf", used: 0.1),
            file("/Documents/ECS119/ECS119_HW6.pdf", used: 0.2),
        ]
        let ranked = RioFileRanker.rank(candidates, query: hw, home: home, now: now)
        // Every word must be in the file name or its folder name: "HW6.pdf" inside MAT108/ counts,
        // HW16 and the other course don't. A name that carries all the words ranks first.
        TestSupport.expectEqual(names(ranked).first, "MAT108_HW6.pdf")
        TestSupport.expectEqual(Set(names(ranked)), ["MAT108_HW6.pdf", "HW6.pdf", "MAT108_HW6_solutions.docx"])

        // Recency decides between equally good name matches.
        let two = [file("/Documents/Resume_old.pdf", used: 200), file("/Documents/Resume_R25.pdf", used: 1)]
        TestSupport.expectEqual(names(RioFileRanker.rank(two, query: q("resume"), home: home, now: now)), ["Resume_R25.pdf", "Resume_old.pdf"])

        // The explicit type wins over a fresher file of another type.
        let types = [file("/Documents/Resume.docx", used: 1), file("/Documents/Resume.pdf", used: 5)]
        TestSupport.expectEqual(names(RioFileRanker.rank(types, query: q("resume pdf"), home: home, now: now)).first, "Resume.pdf")

        // A shorter, closer name beats a long one.
        let close = [file("/Documents/Hala_Pitch_Investor_Update_Notes_Oct.pdf", used: 3), file("/Documents/Hala Pitch.pdf", used: 3)]
        TestSupport.expectEqual(names(RioFileRanker.rank(close, query: q("Hala pitch"), home: home, now: now)).first, "Hala Pitch.pdf")

        // Deck: the soft word in the name and slide types rank first.
        let deck = [
            file("/Documents/Hala_Brochure.pdf", used: 1),
            file("/Documents/Hala_PitchDeck_Aug2026_4.pdf", used: 20),
            file("/Documents/Hala logo.png", used: 1),
        ]
        TestSupport.expectEqual(names(RioFileRanker.rank(deck, query: q("Hala deck"), home: home, now: now)).first, "Hala_PitchDeck_Aug2026_4.pdf")

        // "latest PDF": no name words, only pdfs, newest first.
        let pdfs = [
            file("/Downloads/a.pdf", used: 9), file("/Downloads/b.pdf", used: 1), file("/Downloads/c.docx", used: 0.01),
        ]
        TestSupport.expectEqual(names(RioFileRanker.rank(pdfs, query: q("latest PDF"), home: home, now: now)), ["b.pdf", "a.pdf"])

        // The last-used date falls back to the modified date.
        let modified = [file("/Documents/Notes_a.txt", modified: 300), file("/Documents/Notes_b.txt", modified: 2)]
        TestSupport.expectEqual(names(RioFileRanker.rank(modified, query: q("notes"), home: home, now: now)).first, "Notes_b.txt")

        // A folder is preferred when the user asked for a folder.
        let mixed = [file("/Documents/Hala.txt", used: 1), file("/Documents/Hala", used: 100, dir: true)]
        TestSupport.expectEqual(names(RioFileRanker.rank(mixed, query: q("Hala folder"), home: home, now: now)).first, "Hala")

        // Ties break deterministically by path.
        let tie = [file("/Documents/B/Resume.pdf", used: 1), file("/Documents/A/Resume.pdf", used: 1)]
        TestSupport.expectEqual(RioFileRanker.rank(tie, query: q("resume"), home: home, now: now).map(\.path),
                                [home + "/Documents/A/Resume.pdf", home + "/Documents/B/Resume.pdf"])

        // Content matches rank by recency alone and need no name match.
        let content = [file("/Documents/x.txt", used: 50), file("/Documents/y.txt", used: 2), file("/Library/z.txt", used: 0.1)]
        TestSupport.expectEqual(names(RioFileRanker.rankContentMatches(content, query: q("visa interview"), home: home, now: now)), ["y.txt", "x.txt"])
    }

    private static func eligibility() {
        let ok: [String] = [
            "/Desktop/Resume.pdf", "/Documents/a/b/c/Resume.pdf",
            "/Library/Mobile Documents/com~apple~CloudDocs/School/Resume.pdf",
            "/Library/Mobile Documents/com~apple~CloudDocs/Resume.pdf",
        ]
        for path in ok {
            TestSupport.expect(RioFileRanker.isEligible(path: home + path, home: home), "\(path) should be eligible")
        }
        let skipped: [String] = [
            "/Library/Caches/Resume.pdf", "/Library/Application Support/x/Resume.pdf",
            "/Library/Mobile Documents/iCloud~md~obsidian/Documents/Resume.md",
            "/.Trash/Resume.pdf", "/Documents/.hidden/Resume.pdf", "/Documents/.Resume.pdf",
            "/Documents/project/node_modules/pkg/Resume.pdf", "/Applications/Foo.app/Contents/Resume.pdf",
            "/Documents/Foo.app", "/Documents/x.photoslibrary/resources/Resume.jpg",
        ]
        for path in skipped {
            TestSupport.expect(!RioFileRanker.isEligible(path: home + path, home: home), "\(path) should be skipped")
        }
        // Outside the home folder is never searched, except the known system folders.
        TestSupport.expect(!RioFileRanker.isEligible(path: "/etc/Resume.pdf", home: home), "outside home")
        TestSupport.expect(!RioFileRanker.isEligible(path: "/Users/other/Documents/Resume.pdf", home: home), "someone else's home")
        TestSupport.expect(!RioFileRanker.isEligible(path: "/Users/testing/Resume.pdf", home: home), "prefix is not containment")
        TestSupport.expect(!RioFileRanker.isEligible(path: home + "/../etc/passwd", home: home), "dot-dot")
    }
}
