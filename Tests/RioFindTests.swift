import Foundation

/// Builder Q: finding things, tidying Downloads, copying screen text. Everything here is pure:
/// synthetic results and listings, never the real disk, Messages or screen.
enum RioFindTests {
    private static var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// Tuesday 3 November 2026, noon.
    private static let now = date(2026, 11, 3, 12)
    private static let home = "/Users/test"

    static func run() {
        phrases()
        phrasesLeaveOthersAlone()
        timeParsing()
        queryParsing()
        handles()
        messagesRows()
        presentable()
        ranking()
        speech()
        downloadsPlan()
        downloadsNames()
        downloadsUndo()
        undoPlan()
        ocrJoin()
    }

    // MARK: Phrases

    private static func parse(_ raw: String) -> RioAction? {
        RioFindPhrases.parse(raw: raw, simplified: RioText.simplify(raw))
    }

    private static func phrases() {
        TestSupport.expectEqual(parse("Find the PDF Ali sent me last week"), .findThing(query: "the PDF Ali sent me last week"))
        TestSupport.expectEqual(parse("find the link from Sarah yesterday"), .findThing(query: "the link from Sarah yesterday"))
        TestSupport.expectEqual(parse("Where is the photo mom texted me?"), .findThing(query: "the photo mom texted me"))
        TestSupport.expectEqual(parse("find the file I downloaded last week"), .findThing(query: "the file I downloaded last week"))
        TestSupport.expectEqual(parse("find that thing from my boss"), .findThing(query: "that thing from my boss"))
        TestSupport.expectEqual(parse("Organize my downloads"), .organizeDownloads)
        TestSupport.expectEqual(parse("clean up my Downloads folder"), .organizeDownloads)
        TestSupport.expectEqual(parse("please tidy up the downloads"), .organizeDownloads)
        TestSupport.expectEqual(parse("copy the text from my screen"), .copyTextFromScreen)
        TestSupport.expectEqual(parse("Copy text from this window"), .copyTextFromScreen)
        TestSupport.expectEqual(parse("grab all the text on the screen"), .copyTextFromScreen)
        TestSupport.expectEqual(parse("OCR the screen"), .copyTextFromScreen)
        TestSupport.expectEqual(parse("copy everything on this window to my clipboard"), .copyTextFromScreen)
    }

    private static func phrasesLeaveOthersAlone() {
        let notMine = [
            "find my resume", "open my resume", "find the pdf", "show me the hala deck", "find my tax return",
            "find the file from downloads", "show me the homework from my desktop", "open downloads", "show my downloads",
            "clean up my desktop", "organize my calendar", "copy that", "copy the text", "copy this text to the clipboard",
            "what's on my screen", "read the screen", "find me a good pizza place", "find me a flight from Doha to Dubai", "show me the weather from yesterday", "find the slides",
            "where is the pdf from the downloads folder", "search for cats", "look for the file called notes",
        ]
        for phrase in notMine {
            TestSupport.expect(parse(phrase) == nil, "Q must not claim \"\(phrase)\"")
        }
        // H still owns its own phrases when the whole parser chain runs.
        TestSupport.expectEqual(RioExtraPhrases.parse(raw: "find my resume", simplified: "find my resume"), .revealFile(query: "resume"))
        TestSupport.expectEqual(RioExtraPhrases.parse(raw: "open my resume", simplified: "open my resume"), .openFile(query: "resume"))
    }

    // MARK: Time

    private static func timeParsing() {
        func interval(_ text: String) -> DateInterval? {
            RioFindTime.extract(from: text, now: now, calendar: calendar)?.interval
        }
        TestSupport.expectEqual(interval("yesterday"), DateInterval(start: date(2026, 11, 2), end: date(2026, 11, 3)))
        TestSupport.expectEqual(interval("today"), DateInterval(start: date(2026, 11, 3), end: now))
        // Last week starts at the beginning of the previous calendar week (Monday 26 October) and runs to now.
        TestSupport.expectEqual(interval("last week"), DateInterval(start: date(2026, 10, 26), end: now))
        TestSupport.expectEqual(interval("this week"), DateInterval(start: date(2026, 11, 2), end: now))
        TestSupport.expectEqual(interval("last month"), DateInterval(start: date(2026, 10, 1), end: now))
        TestSupport.expectEqual(interval("in the last three days"), DateInterval(start: date(2026, 10, 31, 12), end: now))
        TestSupport.expectEqual(interval("two days ago"), DateInterval(start: date(2026, 11, 1), end: date(2026, 11, 2)))
        // Monday is yesterday; on Tuesday "tuesday" means last week's.
        TestSupport.expectEqual(interval("on monday"), DateInterval(start: date(2026, 11, 2), end: date(2026, 11, 3)))
        TestSupport.expectEqual(interval("last tuesday"), DateInterval(start: date(2026, 10, 27), end: date(2026, 10, 28)))
        TestSupport.expect(interval("the pdf ali sent") == nil, "no time phrase")
        TestSupport.expectEqual(
            RioFindTime.extract(from: "the pdf ali sent me last week", now: now, calendar: calendar)?.remainder, "the pdf ali sent me"
        )
    }

    // MARK: Query parsing

    private static func query(_ text: String) -> RioFindQuery { RioFindQuery.parse(text, now: now, calendar: calendar) }

    private static func queryParsing() {
        let pdf = query("the PDF Ali sent me last week")
        TestSupport.expectEqual(pdf.person, "ali")
        TestSupport.expectEqual(pdf.kinds, [.pdf])
        TestSupport.expectEqual(pdf.interval, DateInterval(start: date(2026, 10, 26), end: now))
        TestSupport.expect(pdf.keywords.isEmpty, "no stray keywords: \(pdf.keywords)")

        let link = query("the link from Sarah yesterday")
        TestSupport.expectEqual(link.person, "sarah")
        TestSupport.expect(link.wantsLink, "link kind")
        TestSupport.expectEqual(link.interval, DateInterval(start: date(2026, 11, 2), end: date(2026, 11, 3)))

        TestSupport.expectEqual(query("what mom sent me").person, "mom")
        TestSupport.expectEqual(query("the file from my boss").person, "boss")
        TestSupport.expectEqual(query("the pdf that Dr Smith emailed me").person, "dr smith")
        TestSupport.expectEqual(query("the invoice from Amazon").keywords, ["invoice"])
        TestSupport.expectEqual(query("the photo Sam sent me").kinds, [.image])
        TestSupport.expectEqual(query("the document Sam sent me").kinds, [.word, .pdf])
        TestSupport.expectEqual(query("the slides from Ali").kinds, [.slides, .pdf])

        let none = query("the file I downloaded")
        TestSupport.expect(none.person == nil && none.interval == nil && none.kinds.isEmpty, "nothing to go on")
        TestSupport.expect(!none.isSearchable, "not searchable")
        TestSupport.expect(query("the tax pdf from ali").keywords == ["tax"], "keyword kept")
    }

    // MARK: Handles and rows

    private static func handles() {
        TestSupport.expect(RioFindHandles.matches("+15305550100", anyOf: ["(530) 555-0100"]), "country code ignored")
        TestSupport.expect(RioFindHandles.matches("Ali@Example.com", anyOf: ["ali@example.com"]), "email case")
        TestSupport.expect(!RioFindHandles.matches("+15305550101", anyOf: ["(530) 555-0100"]), "different number")
        TestSupport.expect(!RioFindHandles.matches(nil, anyOf: ["ali@example.com"]), "no sender")
        TestSupport.expect(RioFindHandles.key(for: "123") == nil, "too short to be a number")
    }

    private static func messagesRows() {
        let nanos = RioMessagesAttachments.storedDate(for: date(2026, 11, 1, 9))
        let incoming = RioMessagesAttachments.Row(
            filename: "~/Library/Messages/Attachments/ab/11/GUID/report.pdf", date: nanos, isFromMe: false, handle: "+15305550100"
        )
        let result = RioMessagesAttachments.result(from: incoming, home: home)
        TestSupport.expectEqual(result?.path, "/Users/test/Library/Messages/Attachments/ab/11/GUID/report.pdf")
        TestSupport.expectEqual(result?.sender, "+15305550100")
        TestSupport.expectEqual(result?.sources, [.messages])
        TestSupport.expectEqual(result?.date, date(2026, 11, 1, 9))

        let outgoing = RioMessagesAttachments.Row(filename: incoming.filename, date: nanos, isFromMe: true, handle: "+15305550100")
        TestSupport.expect(RioMessagesAttachments.result(from: outgoing, home: home)?.sender == nil, "my own sends have no sender")
        TestSupport.expect(RioMessagesAttachments.result(from: .init(filename: nil, date: 0, isFromMe: false, handle: nil), home: home) == nil, "no file")
        TestSupport.expect(RioMessagesAttachments.result(from: .init(filename: "relative/x.pdf", date: 0, isFromMe: false, handle: nil), home: home) == nil, "relative path")

        // Older databases store seconds, not nanoseconds.
        TestSupport.expectEqual(RioMessagesAttachments.date(fromStored: 1_000), Date(timeIntervalSince1970: 978_307_200 + 1_000))
        TestSupport.expectEqual(RioMessagesAttachments.date(fromStored: nanos), date(2026, 11, 1, 9))
    }

    // MARK: Presentable (the allowlist)

    private static func presentable() {
        TestSupport.expect(RioFindRanker.isPresentable(path: home + "/Downloads/a.pdf", home: home), "downloads")
        TestSupport.expect(RioFindRanker.isPresentable(path: home + "/Library/Messages/Attachments/ab/11/G/a.pdf", home: home), "messages attachments")
        TestSupport.expect(RioFindRanker.isPresentable(path: home + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/U/a.pdf", home: home), "mail downloads")
        TestSupport.expect(!RioFindRanker.isPresentable(path: home + "/Library/Messages/chat.db", home: home), "chat.db is never a result")
        TestSupport.expect(!RioFindRanker.isPresentable(path: home + "/Library/Messages/Attachments/../chat.db", home: home), "no traversal")
        TestSupport.expect(!RioFindRanker.isPresentable(path: home + "/Library/Messages/Attachments/ab/.hidden/a.pdf", home: home), "no hidden items")
        TestSupport.expect(!RioFindRanker.isPresentable(path: home + "/Library/Keychains/login.keychain-db", home: home), "other Library")
        TestSupport.expect(!RioFindRanker.isPresentable(path: "/etc/passwd", home: home), "outside home")
        TestSupport.expect(!RioFindRanker.isPresentable(path: home + "/Library/Messages/Attachments", home: home), "the folder itself")
    }

    // MARK: Ranking and merging

    private static let aliHandles = ["+1 (530) 555-0100", "ali@example.com"]

    private static func result(_ path: String, _ date: Date?, sender: String? = nil, _ source: RioFindSource) -> RioFindResult {
        RioFindResult(path: path, date: date, sender: sender, sources: [source])
    }

    private static func ranking() {
        let q = query("the PDF Ali sent me last week")
        let fromAli = result(home + "/Library/Messages/Attachments/aa/01/G1/notes.pdf", date(2026, 10, 30), sender: "+15305550100", .messages)
        let fromSam = result(home + "/Library/Messages/Attachments/aa/02/G2/other.pdf", date(2026, 11, 1), sender: "+15305550999", .messages)
        let tooOld = result(home + "/Library/Messages/Attachments/aa/03/G3/old.pdf", date(2026, 9, 1), sender: "+15305550100", .messages)
        let wrongKind = result(home + "/Library/Messages/Attachments/aa/04/G4/pic.heic", date(2026, 11, 1), sender: "+15305550100", .messages)
        let named = result(home + "/Downloads/Ali-contract.pdf", date(2026, 11, 2), .downloads)
        let unrelated = result(home + "/Downloads/menu.pdf", date(2026, 11, 2), .downloads)
        let ranked = RioFindRanker.rank(
            [unrelated, fromSam, tooOld, wrongKind, named, fromAli], query: q, personHandles: aliHandles, home: home, now: now
        )
        TestSupport.expectEqual(ranked.map(\.path), [fromAli.path, named.path])

        // Same file from Spotlight and Downloads becomes one result with both sources and the newest date.
        let spot = result(home + "/Downloads/Ali-contract.pdf", date(2026, 11, 1), .spotlight)
        let merged = RioFindRanker.rank([named, spot], query: q, personHandles: [], home: home, now: now)
        TestSupport.expectEqual(merged.count, 1)
        TestSupport.expectEqual(merged.first?.sources, [.downloads, .spotlight])
        TestSupport.expectEqual(merged.first?.date, date(2026, 11, 2))

        // Newer beats older when everything else is equal; a keyword beats recency.
        let kq = query("the invoice pdf from Ali")
        let newer = result(home + "/Downloads/ali scan.pdf", date(2026, 11, 2), .downloads)
        let older = result(home + "/Downloads/ali invoice.pdf", date(2026, 10, 20), .downloads)
        TestSupport.expectEqual(
            RioFindRanker.rank([newer, older], query: kq, personHandles: [], home: home, now: now).map(\.path), [older.path, newer.path]
        )
        let plain = query("the pdf from ali")
        TestSupport.expectEqual(
            RioFindRanker.rank([older, newer], query: plain, personHandles: [], home: home, now: now).map(\.path), [newer.path, older.path]
        )

        // Without a person, only the time and kind filter; folders never count.
        let timeOnly = query("the photo from yesterday")
        let photo = result(home + "/Pictures/a.png", date(2026, 11, 2, 8), .spotlight)
        let oldPhoto = result(home + "/Pictures/b.png", date(2026, 10, 1), .spotlight)
        TestSupport.expectEqual(RioFindRanker.rank([oldPhoto, photo], query: timeOnly, personHandles: [], home: home, now: now).map(\.path), [photo.path])
        // A result with no date can't satisfy a time window.
        TestSupport.expect(RioFindRanker.rank([result(home + "/Pictures/c.png", nil, .spotlight)], query: timeOnly, personHandles: [], home: home, now: now).isEmpty, "undated")
    }

    private static func speech() {
        let one = [result(home + "/Downloads/report.pdf", date(2026, 11, 2, 10), .downloads)]
        TestSupport.expectEqual(RioFindSpeech.summary(one, now: now, calendar: calendar), "Found it: report.pdf from yesterday, in Downloads")
        let two = one + [result(home + "/Downloads/b.pdf", date(2026, 10, 20), .spotlight)]
        TestSupport.expectEqual(RioFindSpeech.summary(two, now: now, calendar: calendar), "Found 2. Best is report.pdf from yesterday, in Downloads")
        TestSupport.expectEqual(RioFindSpeech.summary([], now: now, calendar: calendar), "I couldn't find that")
        TestSupport.expectEqual(RioFindSpeech.dayPhrase(date(2026, 10, 31), now: now, calendar: calendar), "Saturday")
        TestSupport.expectEqual(RioFindSpeech.dayPhrase(date(2026, 10, 1), now: now, calendar: calendar), "Oct 1")
    }

    // MARK: Downloads plan

    private static let downloads = "/Users/test/Downloads"
    private static let old = date(2026, 11, 3, 9)

    private static func entry(_ name: String, dir: Bool = false, modified: Date? = nil) -> RioDownloadEntry {
        RioDownloadEntry(name: name, isDirectory: dir, modified: modified ?? old)
    }

    private static func downloadsPlan() {
        let plan = RioDownloadsPlan.build(
            entries: [
                entry("photo.JPG"), entry("report.pdf"), entry("notes.txt"), entry("data.csv"), entry("deck.pptx"),
                entry("backup.zip"), entry("App.dmg"), entry("song.mp3"), entry("clip.mov"),
                entry("fresh.pdf", modified: now.addingTimeInterval(-60)),
                entry("edge.pdf", modified: now.addingTimeInterval(-121)),
                entry("movie.mp4.crdownload"), entry("big.zip.part"), entry(".hidden.pdf"),
                entry("Some Folder", dir: true), entry("Images", dir: true), entry("mystery.xyz"), entry("README"),
            ],
            downloadsPath: downloads, existing: [:], now: now
        )
        let byName = Dictionary(uniqueKeysWithValues: plan.moves.map { ($0.originalName, $0.to) })
        TestSupport.expectEqual(byName["photo.JPG"], downloads + "/Images/photo.JPG")
        TestSupport.expectEqual(byName["report.pdf"], downloads + "/PDFs/report.pdf")
        TestSupport.expectEqual(byName["notes.txt"], downloads + "/Documents/notes.txt")
        TestSupport.expectEqual(byName["data.csv"], downloads + "/Spreadsheets/data.csv")
        TestSupport.expectEqual(byName["deck.pptx"], downloads + "/Presentations/deck.pptx")
        TestSupport.expectEqual(byName["backup.zip"], downloads + "/Archives/backup.zip")
        TestSupport.expectEqual(byName["App.dmg"], downloads + "/Installers/App.dmg")
        TestSupport.expectEqual(byName["song.mp3"], downloads + "/Audio/song.mp3")
        TestSupport.expectEqual(byName["clip.mov"], downloads + "/Video/clip.mov")
        // Exactly two minutes is safe; under two minutes, partial downloads, hidden items, folders and unknown types stay.
        TestSupport.expectEqual(byName["edge.pdf"], downloads + "/PDFs/edge.pdf")
        TestSupport.expect(byName["fresh.pdf"] == nil, "recent file skipped")
        TestSupport.expectEqual(plan.moves.count, 10)
        TestSupport.expectEqual(plan.skippedRecent, 1)
        TestSupport.expectEqual(plan.skippedDownloading, 2)
        TestSupport.expectEqual(plan.skippedOther, 5)
        TestSupport.expect(plan.moves.allSatisfy { $0.from != $0.to }, "no no-op moves")
    }

    private static func downloadsNames() {
        // Collisions: against what is already in the folder, and against other planned moves.
        let plan = RioDownloadsPlan.build(
            entries: [entry("a.pdf"), entry("A.PDF"), entry("b.pdf")],
            downloadsPath: downloads, existing: ["PDFs": ["a.pdf", "a 2.pdf"]], now: now
        )
        let targets = plan.moves.map(\.newName)
        TestSupport.expectEqual(Set(targets.map { $0.lowercased() }).count, 3)
        TestSupport.expect(targets.contains("b.pdf"), "free name kept")
        TestSupport.expect(!targets.contains { $0.lowercased() == "a.pdf" || $0.lowercased() == "a 2.pdf" }, "never overwrite: \(targets)")
        TestSupport.expectEqual(RioDownloadsPlan.uniqueName("x.png", taken: ["x.png", "x 2.png"]), "x 3.png")
        TestSupport.expectEqual(RioDownloadsPlan.uniqueName("x", taken: ["x"]), "x 2")
        TestSupport.expectEqual(RioDownloadsPlan.uniqueName("x.png", taken: []), "x.png")

        // Obvious renames only.
        TestSupport.expectEqual(
            RioDownloadsPlan.tidyName("Screenshot 2026-11-03 at 10.15.22\u{202F}AM.png"), "Screenshot 2026-11-03 at 10.15.22 AM.png"
        )
        TestSupport.expectEqual(RioDownloadsPlan.tidyName("Screen Shot 2019-01-01 at 1.00.00 PM.png"), "Screenshot 2019-01-01 at 1.00.00 PM.png")
        TestSupport.expectEqual(RioDownloadsPlan.tidyName("my  report .pdf"), "my report.pdf")
        TestSupport.expectEqual(RioDownloadsPlan.tidyName("IMG_1234 (1).jpg"), "IMG_1234 (1).jpg")
        TestSupport.expectEqual(RioDownloadsPlan.tidyName("lecture-3.pdf"), "lecture-3.pdf")

        // The confirmation text carries the whole plan, the renames and the promises.
        let shot = RioDownloadsPlan.build(
            entries: [entry("Screen Shot 2019-01-01 at 1.00.00 PM.png"), entry("a.pdf"), entry("fresh.zip", modified: now)],
            downloadsPath: downloads, existing: [:], now: now
        )
        let text = shot.description
        TestSupport.expect(text.contains("Move 2 files"), text)
        TestSupport.expect(text.contains("a.pdf  \u{2192}  PDFs/"), text)
        TestSupport.expect(text.contains("Screen Shot 2019-01-01 at 1.00.00 PM.png  \u{2192}  Images/Screenshot 2019-01-01 at 1.00.00 PM.png"), text)
        TestSupport.expect(text.contains("1 changed in the last 2 minutes"), text)
        TestSupport.expect(text.contains("Nothing is deleted or overwritten"), text)
        TestSupport.expectEqual(shot.confirmationContent.confirmLabel, "Tidy up")
        TestSupport.expectEqual(RioDownloadsPlan().confirmationContent.confirmLabel, "OK")

        let many = RioDownloadsPlan.build(
            entries: (1...50).map { entry("f\($0).pdf") }, downloadsPath: downloads, existing: [:], now: now
        )
        TestSupport.expect(many.description.contains("...and 10 more"), "long plans are capped in the list")
        TestSupport.expect(many.description.contains("Move 50 files"), "but the count is the full count")
    }

    private static func downloadsUndo() {
        let moves = [
            RioDownloadMove(from: downloads + "/a.pdf", to: downloads + "/PDFs/a.pdf", category: .pdfs),
            RioDownloadMove(from: downloads + "/Screen Shot x.png", to: downloads + "/Images/Screenshot x.png", category: .images),
            RioDownloadMove(from: downloads + "/gone.zip", to: downloads + "/Archives/gone.zip", category: .archives),
        ]
        var present: Set<String> = [downloads + "/PDFs/a.pdf", downloads + "/Images/Screenshot x.png"]
        let plan = RioDownloadsUndoPlan.inverse(of: moves, exists: { present.contains($0) })
        TestSupport.expectEqual(plan.missing, 1)
        // Newest first, back under the original name (the rename is undone too).
        TestSupport.expectEqual(plan.restores.map(\.to), [downloads + "/Screen Shot x.png", downloads + "/a.pdf"])
        TestSupport.expectEqual(plan.restores.map(\.from), [downloads + "/Images/Screenshot x.png", downloads + "/PDFs/a.pdf"])

        // Something new now sits at the original spot: the file comes back numbered, never on top.
        present.insert(downloads + "/a.pdf")
        let blocked = RioDownloadsUndoPlan.inverse(of: [moves[0]], exists: { present.contains($0) })
        TestSupport.expectEqual(blocked.restores.map(\.to), [downloads + "/a 2.pdf"])
        // Two files with the same original name don't collide with each other either.
        let twins = [
            RioDownloadMove(from: downloads + "/t.pdf", to: downloads + "/PDFs/t.pdf", category: .pdfs),
            RioDownloadMove(from: downloads + "/t.pdf", to: downloads + "/PDFs/t 2.pdf", category: .pdfs),
        ]
        let twinPresent: Set<String> = [downloads + "/PDFs/t.pdf", downloads + "/PDFs/t 2.pdf"]
        let both = RioDownloadsUndoPlan.inverse(of: twins, exists: { twinPresent.contains($0) })
        TestSupport.expectEqual(Set(both.restores.map { $0.to.lowercased() }).count, 2)
    }

    private static func undoPlan() {
        var snapshot = RioUndoSnapshot()
        snapshot.created = .downloadsMoved(count: 4)
        TestSupport.expectEqual(
            RioUndoPlan.disposition(for: .organizeDownloads, snapshot: snapshot), .reversible(.restoreDownloads)
        )
        // Nothing moved: nothing to undo, and it must not hide an earlier undoable action.
        TestSupport.expectEqual(RioUndoPlan.disposition(for: .organizeDownloads, snapshot: RioUndoSnapshot()), .ignore)
        TestSupport.expectEqual(RioUndoPlan.undoneSummary(for: .restoreDownloads), "Undone: put your files back in Downloads")
        TestSupport.expect(RioUndoInverse.restoreDownloads.isRetryableAfterFailure, "retryable")
        // Finding and copying stay irreversible/no-ops as before.
        TestSupport.expectEqual(RioUndoPlan.disposition(for: .findThing(query: "x"), snapshot: RioUndoSnapshot()), .irreversible)
    }

    // MARK: OCR

    private static func line(_ text: String, x: Double, y: Double, w: Double = 0.2, h: Double = 0.02) -> RioOCRLine {
        RioOCRLine(text: text, minX: x, minY: y, width: w, height: h)
    }

    private static func ocrJoin() {
        // Pieces arrive in any order; rows read top to bottom, left to right.
        let english = RioOCRText.join([
            line("world", x: 0.4, y: 0.80), line("Second line", x: 0.1, y: 0.77), line("Hello", x: 0.1, y: 0.80),
        ])
        TestSupport.expectEqual(english.text, "Hello world\nSecond line")
        TestSupport.expectEqual(english.lineCount, 2)

        // An Arabic row reads right to left: the rightmost piece comes first.
        let arabic = RioOCRText.join([line("مرحبا", x: 0.1, y: 0.5), line("بالعالم", x: 0.5, y: 0.5)])
        TestSupport.expectEqual(arabic.text, "بالعالم مرحبا")
        TestSupport.expectEqual(arabic.lineCount, 1)

        // A mixed screen: an English row and an Arabic row keep their own directions.
        let mixed = RioOCRText.join([
            line("Title", x: 0.1, y: 0.9), line("second", x: 0.5, y: 0.9),
            line("ثاني", x: 0.1, y: 0.87), line("أول", x: 0.6, y: 0.87),
        ])
        TestSupport.expectEqual(mixed.text, "Title second\nأول ثاني")

        // Slightly uneven baselines still count as one row; a big gap starts a new paragraph.
        let uneven = RioOCRText.join([line("a", x: 0.1, y: 0.500), line("b", x: 0.3, y: 0.506), line("c", x: 0.1, y: 0.3)])
        TestSupport.expectEqual(uneven.text, "a b\n\nc")
        TestSupport.expectEqual(uneven.lineCount, 2)

        // Empty and blank pieces are ignored.
        let blank = RioOCRText.join([line("  ", x: 0.1, y: 0.5), line("", x: 0.1, y: 0.4)])
        TestSupport.expectEqual(blank.text, "")
        TestSupport.expectEqual(blank.lineCount, 0)
        TestSupport.expectEqual(RioOCRText.summary(lineCount: 1), "Copied 1 line")
        TestSupport.expectEqual(RioOCRText.summary(lineCount: 12), "Copied 12 lines")
    }
}
