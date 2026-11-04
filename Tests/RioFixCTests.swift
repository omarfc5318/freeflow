import Foundation

/// Fix round C: parser misroutes from the 397-phrase corpus, audit H3/H4, M8 to M14, the LOW logic
/// items, the Arabic table gaps, and the calendar and reply-confirmation security items.
/// Synthetic data and temp directories only.
enum RioFixCTests {
    private static var failures: [String] = []

    private static func check(_ ok: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
        if !ok() { failures.append(message()) }
    }

    private static func same<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        if actual != expected { failures.append("\(label): expected \(expected), got \(actual)") }
    }

    static func run() {
        failures = []
        parserMisroutes()
        siteSearchAndChains()
        unmatchedOpen()
        envelope()
        windowsAndSystem()
        clipboardAndEmail()
        memoryRouting()
        memoryMatching()
        memoryCorruptFile()
        dateTimes()
        calendarRules()
        calculator()
        undoAndTimers()
        helpCatalogue()
        arabic()
        confirmation()
        notesScript()
        TestSupport.expect(failures.isEmpty, "\(failures.count) fix-round C failures:\n" + failures.joined(separator: "\n"))
    }

    // MARK: Parser

    private static let gc = "Google Chrome"
    private static let apps: [InstalledApp] = RioActionParserTests.apps + ["Calculator", "Preview"].map {
        InstalledApp(name: $0, bundleIdentifier: "test.\($0.lowercased())", url: URL(fileURLWithPath: "/Applications/\($0).app"))
    }
    private static let parser = RioActionParser(installedApps: apps)

    private static func key(_ k: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) -> RioAction {
        .pressKeys(KeyCombo(key: k, command: command, shift: shift, option: option, control: control))
    }

    private static func expectParse(_ text: String, _ expected: RioActionParse) {
        same(parser.parse(text), expected, "\"\(text)\"")
    }

    private static func actions(_ text: String, _ expected: RioAction...) {
        expectParse(text, .actions(expected))
    }

    private static func url(_ text: String) -> RioAction { .openURL(URL(string: text)!) }

    private static func parserMisroutes() {
        // H3: bare "go back" is the browser's back; "go back a song" stays media.
        actions("go back", .browser(.back))
        actions("Rio, go back", .browser(.back))
        actions("go back a song", .media(.previous))
        actions("go back one track", .media(.previous))
        // M10: "the last one" answers "Which one?"; only song or track means the media key.
        actions("the last one", .click(label: "", ordinal: -1))
        actions("last song", .media(.previous))
        actions("play the last track", .media(.previous))
        actions("previous song", .media(.previous))
        // "press tab" is the key; a counted or role-qualified tab is a click.
        actions("press tab", key("tab"))
        actions("hit tab", key("tab"))
        actions("press the second tab", .click(label: "tab", ordinal: 2))
        actions("click the Save button", .click(label: "Save button", ordinal: nil))
        // The colour stays as a hint when nothing else names the thing.
        actions("click the blue button", .click(label: "blue button", ordinal: nil))
        actions("click the blue Submit button", .click(label: "blue Submit button", ordinal: nil))
        actions("stop", .cancelTimer)
        actions("exit full screen", key("f", command: true, control: true))
        actions("leave full screen", key("f", command: true, control: true))
        actions("show desktop", key("f11"))
        actions("show all windows", key("up", control: true))
        actions("sound down", .volume(.down))
        actions("turn it way down", .volume(.down))
        actions("write hello in the search bar", .fillField(label: "search bar", text: "hello"))
    }

    private static func siteSearchAndChains() {
        actions("open the website amazon dot com", url("https://amazon.com"))
        actions("open the site github dot com", url("https://github.com"))
        actions("go to amazon and search for headphones", url("https://www.amazon.com/s?k=headphones"))
        actions("search amazon for usb cables", url("https://www.amazon.com/s?k=usb%20cables"))
        actions("search for usb cables on amazon", url("https://www.amazon.com/s?k=usb%20cables"))
        actions("go to youtube and search for cats", url("https://www.youtube.com/results?search_query=cats"))
        actions("open Chrome and go to youtube and search for cats",
                .openApp(name: gc), url("https://www.youtube.com/results?search_query=cats"))
        actions("open chrome and safari", .openApp(name: gc), .openApp(name: "Safari"))
        actions("open Chrome, Safari and Warp", .openApp(name: gc), .openApp(name: "Safari"), .openApp(name: "Warp"))
        actions("quit Chrome and Safari", .quitApp(name: gc), .quitApp(name: "Safari"))
        // Two apps side by side.
        let left = RioAction.window(WindowCommand(appName: gc, placement: .leftHalf))
        let right = RioAction.window(WindowCommand(appName: "Safari", placement: .rightHalf))
        actions("split screen Chrome and Safari", left, right)
        actions("put Chrome and Safari side by side", left, right)
        actions("open Chrome and Safari and put them side by side", .openApp(name: gc), .openApp(name: "Safari"), left, right)
        // A lone "split screen" has no apps to place: the smart resolver gets it.
        expectParse("split screen", .unknown("split screen"))
    }

    private static func unmatchedOpen() {
        // Not installed, not a site, nothing that names an app: the smart resolver's job.
        expectParse("open camera", .unknown("open camera"))
        expectParse("open the first result", .unknown("open the first result"))
        expectParse("open rio grande", .unknown("open rio grande"))
        // A name that clearly is an app still gets "I couldn't find it".
        actions("open Photoshop", .openApp(name: "Photoshop"))
        actions("open the photoshop app", .openApp(name: "photoshop"))
        actions("open Crome", .openApp(name: gc))
        // Quit of an unknown lowercase thing is no longer a guess either.
        expectParse("quit zorblax", .unknown("quit zorblax"))
    }

    private static func envelope() {
        actions("uhh open uh Chrome", .openApp(name: gc))
        actions("open um Chrome please", .openApp(name: gc))
        actions("Ria open Chrome", .openApp(name: gc))
        actions("Rio's open Chrome", .openApp(name: gc))
        actions("rear open notes", .openApp(name: "Notes"))
        // "riot police" is not the name.
        expectParse("riot police", .unknown("riot police"))
        // A message body keeps its hesitations.
        actions("text mom um I'm late", .sendMessage(to: "mom", body: "um I'm late"))
        // A leading minus before a number survives the envelope ("-2^2").
        same(RioActionParser.stripEnvelope("-2^2"), "-2^2", "leading minus")
        same(RioActionParser.stripEnvelope("Rio, -2^2"), "-2^2", "minus after name")
        same(RioActionParser.stripEnvelope("uh hello").lowercased(), "hello", "leading filler")
    }

    private static func windowsAndSystem() {
        actions("top half", .window(WindowCommand(appName: nil, placement: .topHalf)))
        actions("bottom half", .window(WindowCommand(appName: nil, placement: .bottomHalf)))
        actions("left half", .window(WindowCommand(appName: nil, placement: .leftHalf)))
        RioSystemPhrases.darkModeProbe = { false }
        actions("toggle dark mode", .systemToggle(.darkMode, isOn: true))
        RioSystemPhrases.darkModeProbe = { true }
        actions("toggle dark mode", .systemToggle(.darkMode, isOn: false))
        RioSystemPhrases.darkModeProbe = { false }
    }

    private static func clipboardAndEmail() {
        actions("paste the link", .clipboard(.pasteRecent(matching: "link")))
        actions("paste the address", .clipboard(.pasteRecent(matching: "address")))
        actions("paste my email address", .clipboard(.pasteRecent(matching: "email")))
        actions("paste", key("v", command: true))
        actions("email Sam saying I'm running late", .draftEmail(to: "Sam", subject: nil, body: "I'm running late"))
        actions("draft an email to Sam about lunch", .draftEmail(to: "Sam", subject: "Lunch", body: ""))
        actions("write an email to john at example dot com subject hello saying see you soon",
                .draftEmail(to: "john@example.com", subject: "Hello", body: "See you soon"))
        actions("compose an email", .draftEmail(to: nil, subject: nil, body: ""))
        actions("new email", .draftEmail(to: nil, subject: nil, body: ""))
        // Never sends: even "send an email" only drafts.
        actions("send an email to my boss", .draftEmail(to: "my boss", subject: nil, body: ""))
        // "and" survives: the whole sentence is the body.
        actions("email Sam saying lunch and dinner are on", .draftEmail(to: "Sam", subject: nil, body: "Lunch and dinner are on"))
        // "open email" is still the Mail app.
        actions("open email", .openApp(name: "Mail"))
        // "remember that" with nothing after it is no memory.
        check(RioMemoryPhrases.parse(raw: "remember that", simplified: "remember that") == nil, "remember that")
    }

    // MARK: Memory

    private static func memoryRouting() {
        // H4: calendar questions are not memory recalls.
        for phrase in ["what's my next class", "what's my next appointment", "what's my next call", "what's my upcoming meeting"] {
            actions(phrase, .calendarAgenda(.next))
        }
        // A real recall still works, and so does a forget.
        actions("what's my locker code", .recall(query: "locker code"))
        actions("forget my locker code", .forget(query: "locker code"))
        // Remember still claims the whole sentence.
        actions("remember my locker code is 4321 and my pin is 99", .remember(fact: "my locker code is 4321 and my pin is 99"))
        check(RioMemoryPhrases.parse(raw: "what's my next thing", simplified: "whats my next thing") == nil, "next thing is no recall")
    }

    private static func memoryMatching() {
        let facts = ["my mom's phone number is 111", "my dad's phone number is 222", "my wifi password is banana"]
        // M8: forget needs every content word; recall needs the subject nouns.
        same(RioMemoryMatcher.best(query: "mom's phone number", facts: facts, limit: 3, requireEveryWord: true), [0], "forget mom")
        same(RioMemoryMatcher.best(query: "mom phone number", facts: facts, limit: 3), [0], "recall mom")
        same(RioMemoryMatcher.best(query: "grandma's phone number", facts: facts, limit: 3), [], "recall grandma")
        same(RioMemoryMatcher.best(query: "grandma's phone number", facts: facts, limit: 3, requireEveryWord: true), [], "forget grandma")
        same(RioMemoryMatcher.best(query: "wifi password", facts: facts, limit: 3), [2], "recall wifi")
        same(RioMemoryMatcher.best(query: "phone number", facts: facts, limit: 3), [0, 1], "generic recall keeps both")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rio-fixc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RioMemoryStore(directory: dir)
        _ = store.add("my mom's phone number is 111")
        _ = store.add("my dad's phone number is 222")
        if case .removed(let text) = store.forget("grandma's phone number") { failures.append("forgot \(text) for grandma") }
        if case .removed(let text) = store.forget("mom's phone number") { same(text, "my mom's phone number is 111", "forget mom") } else {
            failures.append("forget mom did not remove one fact")
        }
        same(store.facts.map(\.text), ["my dad's phone number is 222"], "dad survives")
    }

    private static func memoryCorruptFile() {
        // M9: a damaged file is set aside, never overwritten by the next write.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rio-fixc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("memory.json")
        try? Data("{ this is not json".utf8).write(to: file)
        let store = RioMemoryStore(directory: dir)
        check(store.facts.isEmpty, "corrupt file loads empty")
        guard let aside = store.recoveredCorruptFile else { failures.append("corrupt file was not set aside"); return }
        check(aside.lastPathComponent.hasPrefix("memory.corrupt-"), "aside name \(aside.lastPathComponent)")
        _ = store.add("my locker code is 4321")
        check((try? String(contentsOf: aside, encoding: .utf8)) == "{ this is not json", "the damaged copy survives the next write")
        check(RioMemoryStore(directory: dir).facts.count == 1, "the fresh file loads")
    }

    // MARK: Dates

    private static let calendar = RioDateTimeParserTests.calendar
    private static let now = RioDateTimeParserTests.now
    private static func date(_ d: Int, _ h: Int, _ m: Int = 0) -> Date { RioDateTimeParserTests.date(2026, 11, d, h, m) }

    private static func start(_ text: String, at current: Date? = nil) -> Date? {
        RioDateTimeParser.parse(text, now: current ?? now, calendar: calendar)?.start
    }

    private static func dateTimes() {
        // M11: after dark, 12 is midnight and 1 to 4 are the small hours of the next day.
        same(start("party tonight at 12"), date(4, 0), "tonight at 12")
        same(start("party tonight at 1"), date(4, 1), "tonight at 1")
        same(start("party tonight at 12:30 am"), date(4, 0, 30), "tonight at 12:30 am")
        same(start("party tomorrow night at 12"), date(5, 0), "tomorrow night at 12")
        same(start("dinner tonight at 8"), date(3, 20), "tonight at 8 still tonight")
        same(start("dinner tonight at 11 pm"), date(3, 23), "tonight at 11 pm")
        // An implied tonight that has already passed rolls to tomorrow night.
        same(start("dinner tonight at 8", at: date(3, 21)), date(4, 20), "tonight at 8 said at 9 pm")
        // "game night" is a title, not a part of day.
        let game = RioDateTimeParser.parse("game night Friday at 7", now: now, calendar: calendar)
        same(game?.start, date(6, 19), "game night start")
        same(game?.remainder, "game night", "game night title")
        same(RioDateTimeParser.parse("dinner Friday night at 7", now: now, calendar: calendar)?.remainder, "dinner", "friday night is a day part")
        // A booking is a task, not an event.
        let phrase = RioCalendarPhrases.parse(raw: "book a table at Nobu Friday at 8", simplified: "book a table at Nobu Friday at 8", now: now, calendar: calendar)
        check(phrase == nil, "book a table is not an event: \(String(describing: phrase))")
        let named = RioCalendarPhrases.parse(raw: "add game night Friday at 7", simplified: "add game night Friday at 7", now: now, calendar: calendar)
        same(named, .createEvent(title: "Game night", start: date(6, 19), durationMinutes: nil), "add game night")
        // Explicit past times are reported, not silently accepted.
        check(RioCalendarSummary.pastEventMessage(start: date(3, 8), now: now, calendar: calendar) != nil, "past time is flagged")
        check(RioCalendarSummary.pastEventMessage(start: date(3, 11), now: now, calendar: calendar) == nil, "future time is fine")
        check(RioCalendarSummary.pastEventMessage(start: now.addingTimeInterval(-30), now: now, calendar: calendar) == nil, "slack for speaking time")
    }

    // MARK: Calendar meetings

    private static func event(_ id: String, _ start: Date, link: String? = nil, owner: Bool = true, hours: Double = 1) -> RioCalendarEventInfo {
        RioCalendarEventInfo(
            identifier: id, title: "Call \(id)", start: start, end: start.addingTimeInterval(hours * 3600), isAllDay: false,
            location: nil, notes: nil, url: link.flatMap(URL.init(string:)), isDeclined: false, isOwnerCalendar: owner
        )
    }

    private static func calendarRules() {
        let zoom = "https://zoom.us/j/9"
        // Subscribed and read-only calendars never count as the owner's meetings.
        let spam = event("spam", date(3, 10, 5), link: zoom, owner: false)
        let own = event("own", date(3, 10, 10), link: "https://meet.google.com/aaa-bbbb-ccc")
        same(RioMeetingPicker.pick(events: [spam, own], now: now), .join(own, URL(string: "https://meet.google.com/aaa-bbbb-ccc")!), "subscription skipped")
        same(RioMeetingPicker.pick(events: [spam], now: now), .none, "subscription alone is no meeting")
        // The join window is now or the next 15 minutes; later meetings are reported.
        let soon = event("soon", date(3, 10, 14), link: zoom)
        same(RioMeetingPicker.pick(events: [soon], now: now), .join(soon, URL(string: zoom)!), "inside 15 minutes")
        let later = event("later", date(3, 10, 16), link: zoom)
        same(RioMeetingPicker.pick(events: [later], now: now), .later(later), "16 minutes is too early")
        let current = event("current", date(3, 9, 30), link: zoom)
        same(RioMeetingPicker.pick(events: [later, current], now: now), .join(current, URL(string: zoom)!), "in progress")
        let line = RioCalendarSummary.startsLater(later, now: now, calendar: calendar)
        check(line.contains("starts at 10:16 AM") && line.contains("didn't open"), "later wording: \(line)")
    }

    // MARK: Calculator

    private static func calc(_ text: String) -> String? { RioCalculator.evaluate(text)?.value }

    private static func calculator() {
        same(calc("what's .5 plus .25"), "0.75", ".5 plus .25")
        same(calc(".5 times 4"), "2", ".5 times 4")
        same(calc("50% of 50% of 80"), "20", "chained percent")
        same(calc("25 percent of 50 percent of 200"), "25", "chained percent words")
        check(calc("1 divided by 3 billion")?.hasPrefix("0.0000000003") == true, "tiny result keeps digits: \(calc("1 divided by 3 billion") ?? "nil")")
        same(calc("-2^2"), "-4", "-2^2")
        same(calc("what's 15% of 84"), "12.6", "plain percent still works")
        // Through the whole parser the minus survives the envelope.
        actions("-2^2", .calculate(expression: "-2^2"))
    }

    // MARK: Undo and timers

    private static func undoAndTimers() {
        // M13: undoing a timer cancels only that countdown, never "stop" (which stops a task).
        same(RioUndoPlan.disposition(for: .startTimer(seconds: 60, label: nil), snapshot: RioUndoSnapshot()),
             .reversible(.cancelCountdown), "timer inverse")
        check(!RioUndoInverse.cancelCountdown.isRetryableAfterFailure, "a finished timer's record is dropped")
        check(RioUndoInverse.restoreWindow.isRetryableAfterFailure, "other inverses stay retryable")
        same(RioUndoPlan.undoneSummary(for: .cancelCountdown), "Undone: timer cancelled", "undo wording")
        // A second timer says it replaced the first.
        let first = RioTimerCountdown(seconds: 300, label: "pasta", start: now)
        let second = RioTimerCountdown(seconds: 600, label: nil, start: now.addingTimeInterval(120))
        same(second.startedSummary(replacing: first, at: now.addingTimeInterval(120)),
             "Timer set for 10 minutes. That replaces your pasta timer, which had 3 minutes left.", "replacement wording")
        same(second.startedSummary(replacing: nil, at: now), "Timer set for 10 minutes", "no replacement")
        let done = RioTimerCountdown(seconds: 30, label: nil, start: now.addingTimeInterval(-60))
        same(second.startedSummary(replacing: done, at: now), "Timer set for 10 minutes", "a finished timer is not replaced")
        // Task phrasings the clause splitter used to destroy.
        actions("do the laundry booking for me", .runTask(goal: "do the laundry booking"))
        actions("go on Kayak and look for flights to Doha", .runTask(goal: "go on Kayak and look for flights to Doha"))
    }

    // MARK: Help

    private static func helpCatalogue() {
        let titles = Set(RioHelpCatalogue.categories.map(\.title))
        for needed in ["Screen and clicks", "Memory and notes", "Email and messages", "Maths, units and time", "Translator", "Arabic"] {
            check(titles.contains(needed), "help is missing \(needed)")
        }
        let summary = RioHelpCatalogue.spokenSummary.lowercased()
        for word in ["screen", "maths", "remember", "email"] { check(summary.contains(word), "spoken summary lacks \(word)") }
        // Every example of the new categories is something Rio really parses.
        let new: Set<String> = ["Screen and clicks", "Memory and notes", "Email and messages", "Maths, units and time", "Translator"]
        for category in RioHelpCatalogue.categories where new.contains(category.title) {
            for example in category.examples {
                if case .actions = parser.parse(example) { continue }
                failures.append("help example \"\(example)\" (\(category.title)) is not understood")
            }
        }
        for example in RioHelpCatalogue.arabicExamples {
            guard case .offline(let english) = RioCommandTranslationPlan.plan(for: example) else {
                failures.append("Arabic help example \(example) is not in the offline table")
                continue
            }
            if case .actions = parser.parse(RioActionTranscript.stripName(from: english)) { continue }
            failures.append("Arabic help example \(example) -> \"\(english)\" is not understood")
        }
    }

    // MARK: Arabic

    private static func arabic() {
        let cases: [(String, String)] = [
            ("ريو افتح الحاسبة", "Rio open Calculator"),
            ("افتح الحاسبة", "open Calculator"),
            ("ريو شغل مؤقت لمدة خمس دقائق", "Rio set a timer for 5 minutes"),
            ("ريو حط تايمر عشر دقايق", "Rio set a timer for 10 minutes"),
            ("ضبط مؤقت ٣٠ ثانية", "set a timer for 30 seconds"),
            ("شغل مؤقت ساعتين", "set a timer for 2 hours"),
            ("ريو مؤقت ربع ساعة", "Rio set a timer for 15 minutes"),
            ("ريو مؤقت نص ساعة", "Rio set a timer for 30 minutes"),
            ("ريو الغي المؤقت", "Rio cancel the timer"),
            ("ريو كم بقي من الوقت", "Rio how much time is left"),
            ("ريو كم باقي على المؤقت", "Rio how much time is left"),
            ("ريو ماذا يمكنك ان تفعل", "Rio what can you do"),
            ("ريو ايش تسوي", "Rio what can you do"),
            ("ريو ساعدني", "Rio help"),
            ("ريو ابحث عن البيتزا", "Rio search for البيتزا"),
            ("ريو دور على مطاعم قريبة", "Rio search for مطاعم قريبة"),
            ("ريو ابحث في يوتيوب عن قطط", "Rio search youtube for قطط"),
            ("ريو افتح قوقل كروم وسفاري", "Rio open Chrome and Safari"),
        ]
        for (input, expected) in cases {
            same(RioArabicCommandTable.english(for: input), expected, input)
        }
        // And the English lands on the real parser.
        for (input, action) in [
            ("ريو شغل مؤقت لمدة خمس دقائق", RioAction.startTimer(seconds: 300, label: nil)),
            ("ريو كم بقي من الوقت", .timerStatus),
            ("ريو ماذا يمكنك ان تفعل", .showHelp),
            ("ريو ابحث عن البيتزا", .webSearch(query: "البيتزا")),
            ("ريو افتح الحاسبة", .openApp(name: "Calculator")),
        ] {
            guard case .offline(let english) = RioCommandTranslationPlan.plan(for: input) else {
                failures.append("\(input) did not plan offline")
                continue
            }
            same(parser.parse(RioActionTranscript.stripName(from: english)), .actions([action]), input)
        }
        // A command that is not in the table still goes to the LLM, never guessed.
        same(RioCommandTranslationPlan.plan(for: "ريو احجز لي طاولة"), .llm, "unknown Arabic")
    }

    // MARK: Confirmation

    private static func confirmation() {
        let reply = RioAction.replyInConversation(body: "on my way")
        same(RioConfirmationContent.make(for: reply, appName: "Messages", resolvedRecipient: nil, conversationTitle: "Sam")?.title,
             "Reply in Messages (window “Sam”)?", "window title shown as the window's name, not a verified recipient")
        same(RioConfirmationContent.make(for: reply, appName: "Messages", resolvedRecipient: nil, conversationTitle: nil)?.title,
             "Reply in Messages?", "app only")
        same(RioConfirmationContent.make(for: reply, appName: "Messages", resolvedRecipient: nil, conversationTitle: "Messages")?.title,
             "Reply in Messages?", "title equal to the app adds nothing")
        // Outside a recognised messaging app the window title is untrusted (a web page sets it).
        same(RioConfirmationContent.make(for: reply, appName: nil, resolvedRecipient: nil, conversationTitle: "Sam")?.title,
             "Reply in this conversation?", "untrusted title is not shown")
        same(RioConfirmationContent.make(for: reply, appName: nil, resolvedRecipient: nil)?.title,
             "Reply in this conversation?", "nothing known")
        let long = String(repeating: "x", count: 200)
        check((RioConfirmationContent.shortTitle(long)?.count ?? 0) <= RioConfirmationContent.maxTitleLength, "long titles are cut")
        check(RioConfirmationContent.shortTitle("  ") == nil, "blank title is nothing")
    }

    // MARK: Notes

    private static func notesScript() {
        let source = RioNotesScripts.source
        check(source.contains("Deleted"), "notes script checks for Recently Deleted")
        check(source.contains("name of container of theNote"), "notes script reads the note's folder")
    }
}
