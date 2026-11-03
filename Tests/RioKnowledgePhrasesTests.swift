import Foundation

/// Phrase parsing for files, calendar and clipboard, including the "never steal B's phrases" checks.
enum RioKnowledgePhrasesTests {
    private static let now = RioDateTimeParserTests.now
    private static let calendar = RioDateTimeParserTests.calendar

    private static func parse(_ text: String) -> RioAction? {
        RioKnowledgePhrases.parse(raw: text, simplified: RioText.simplify(text), now: now, calendar: calendar)
    }

    private static func d(_ month: Int, _ day: Int, _ h: Int, _ m: Int = 0) -> Date {
        RioDateTimeParserTests.date(2026, month, day, h, m)
    }

    static func run() {
        files()
        folders()
        calendarPhrases()
        clipboardPhrases()
        notStealing()
        throughTheRealParser()
    }

    private static func files() {
        let cases: [(String, RioAction)] = [
            ("open my resume", .openFile(query: "resume")),
            ("Open my resume.", .openFile(query: "resume")),
            ("open the MAT108 homework 6 PDF", .openFile(query: "MAT108 homework 6 PDF")),
            ("Open the MAT108 homework six PDF", .openFile(query: "MAT108 homework six PDF")),
            ("open up the Hala deck", .openFile(query: "Hala deck")),
            ("open my Hala pitch deck", .openFile(query: "Hala pitch deck")),
            ("pull up my ECS119 syllabus", .openFile(query: "ECS119 syllabus")),
            ("bring up my lease", .openFile(query: "lease")),
            ("show me the Hala deck", .openFile(query: "Hala deck")),
            ("open the latest PDF", .openFile(query: "latest PDF")),
            ("open resume.pdf", .openFile(query: "resume.pdf")),
            ("open my resume dot pdf", .openFile(query: "resume.pdf")),
            ("open my tax return", .openFile(query: "tax return")),
            ("open the invoice from Apple", .openFile(query: "invoice from Apple")),
            ("open my lecture notes", .openFile(query: "lecture notes")),
            ("open the MAT108 midterm", .openFile(query: "MAT108 midterm")),
            ("open the MAT108 homework 6 PDF in Preview", .openFile(query: "MAT108 homework 6 PDF")),
            ("show me the Hala deck in Finder", .revealFile(query: "Hala deck")),
            ("show me the Hala deck in the Finder", .revealFile(query: "Hala deck")),
            ("find my tax return", .revealFile(query: "tax return")),
            ("find my resume", .revealFile(query: "resume")),
            ("where is my resume", .revealFile(query: "resume")),
            ("where's the MAT108 homework 6 PDF", .revealFile(query: "MAT108 homework 6 PDF")),
            ("locate my ECS119 syllabus", .revealFile(query: "ECS119 syllabus")),
            ("reveal my resume in Finder", .revealFile(query: "resume")),
            ("open my resume in Finder", .revealFile(query: "resume")),
            ("show the latest PDF in Finder", .revealFile(query: "latest PDF")),
        ]
        for (text, expected) in cases {
            TestSupport.expectEqual(parse(text), expected)
        }
    }

    private static func folders() {
        let cases: [(String, RioAction)] = [
            ("open my downloads folder", .openFile(query: "downloads folder")),
            ("open the Downloads folder", .openFile(query: "Downloads folder")),
            ("open my documents folder", .openFile(query: "documents folder")),
            ("open my desktop", .openFile(query: "desktop")),
            ("open my downloads", .openFile(query: "downloads")),
            ("open downloads", .openFile(query: "downloads")),
            ("open documents", .openFile(query: "documents")),
            ("open my home folder", .openFile(query: "home folder")),
            ("open my pictures folder", .openFile(query: "pictures folder")),
            ("open the iCloud Drive folder", .openFile(query: "iCloud Drive folder")),
            ("show me my downloads folder", .openFile(query: "downloads folder")),
            ("show my downloads in Finder", .revealFile(query: "downloads")),
        ]
        for (text, expected) in cases {
            TestSupport.expectEqual(parse(text), expected)
        }
    }

    private static func calendarPhrases() {
        let agenda: [(String, CalendarRange)] = [
            ("what's on my calendar", .today),
            ("What's on my calendar today?", .today),
            ("what is on my calendar today", .today),
            ("what's on my schedule", .today),
            ("what's on my calendar tomorrow", .tomorrow),
            ("what's on my calendar for tomorrow", .tomorrow),
            ("what's on my schedule tomorrow", .tomorrow),
            ("what do I have today", .today),
            ("what do I have tomorrow", .tomorrow),
            ("what do I have on my calendar tomorrow", .tomorrow),
            ("what do I have going on today", .today),
            ("what have I got today", .today),
            ("what's my schedule today", .today),
            ("what's my schedule tomorrow", .tomorrow),
            ("what's my day look like", .today),
            ("what does my day look like", .today),
            ("how does tomorrow look", .tomorrow),
            ("what's tomorrow look like", .tomorrow),
            ("do I have anything today", .today),
            ("do I have anything tomorrow", .tomorrow),
            ("read my calendar", .today),
            ("check my calendar", .today),
            ("read me my agenda", .today),
            ("what's next", .next),
            ("What's next?", .next),
            ("what's next on my calendar", .next),
            ("what's next on my schedule", .next),
            ("what's my next meeting", .next),
            ("what is my next event", .next),
            ("what's my next class", .next),
            ("what's my next appointment", .next),
            ("when is my next meeting", .next),
            ("when's my next class", .next),
            ("what's coming up", .next),
            ("what's up next", .next),
            ("what do I have next", .next),
        ]
        for (text, range) in agenda {
            TestSupport.expectEqual(parse(text), .calendarAgenda(range))
        }
        let join = [
            "join my next meeting", "join my meeting", "join the meeting", "join my next call", "Join my next meeting.",
            "join my zoom meeting", "join the zoom", "jump on my next call", "hop on my meeting", "join my next class",
            "I need to join my next meeting", "open my next meeting link", "start my next meeting", "dial into my next meeting",
        ]
        for text in join {
            TestSupport.expectEqual(parse(text), .joinNextMeeting)
        }
        let create: [(String, RioAction)] = [
            ("add study session tomorrow at 7 pm", .createEvent(title: "Study session", start: d(11, 4, 19), durationMinutes: nil)),
            ("Add study session tomorrow at 7 PM.", .createEvent(title: "Study session", start: d(11, 4, 19), durationMinutes: nil)),
            ("add lunch with Sarah Friday at 1", .createEvent(title: "Lunch with Sarah", start: d(11, 6, 13), durationMinutes: nil)),
            ("schedule a meeting with Sarah on Friday at 1 pm for an hour",
             .createEvent(title: "Meeting with Sarah", start: d(11, 6, 13), durationMinutes: 60)),
            ("put dentist appointment on my calendar for tomorrow at 3 PM",
             .createEvent(title: "Dentist appointment", start: d(11, 4, 15), durationMinutes: nil)),
            ("create an event called Hala sync tomorrow at 10 am",
             .createEvent(title: "Hala sync", start: d(11, 4, 10), durationMinutes: nil)),
            ("add MAT108 office hours Thursday at 2 pm to my calendar",
             .createEvent(title: "MAT108 office hours", start: d(11, 5, 14), durationMinutes: nil)),
            ("add a study group tomorrow from 3 to 5 pm",
             .createEvent(title: "Study group", start: d(11, 4, 15), durationMinutes: 120)),
            ("book a haircut next Tuesday at 11:30 am",
             .createEvent(title: "Haircut", start: d(11, 10, 11, 30), durationMinutes: nil)),
            ("schedule call with Ali tonight at 9 for 30 minutes",
             .createEvent(title: "Call with Ali", start: d(11, 3, 21), durationMinutes: 30)),
        ]
        for (text, expected) in create {
            TestSupport.expectEqual(parse(text), expected)
        }
        let notEvents = [
            "add milk to my shopping list", "add this to my reminders tomorrow at 7 pm", "add study session",
            "schedule a text to Mom tomorrow at 5", "add tomorrow at 7 pm", "put Chrome on the left",
            "add a song to my playlist", "schedule it", "add standup tomorrow at 8", "create a timer for 5 minutes",
            "remind me tomorrow at 7 pm to call Ali", "put it on my calendar",
        ]
        for text in notEvents {
            TestSupport.expect(parse(text) == nil, "'\(text)' must not create an event: \(String(describing: parse(text)))")
        }
    }

    private static func clipboardPhrases() {
        let cases: [(String, RioAction)] = [
            ("what's on my clipboard", .clipboard(.readCurrent)),
            ("What's on my clipboard?", .clipboard(.readCurrent)),
            ("what is in my clipboard", .clipboard(.readCurrent)),
            ("what do I have on my clipboard", .clipboard(.readCurrent)),
            ("read me my clipboard", .clipboard(.readCurrent)),
            ("read my clipboard", .clipboard(.readCurrent)),
            ("what did I just copy", .clipboard(.readCurrent)),
            ("what did I copy", .clipboard(.readCurrent)),
            ("what's copied", .clipboard(.readCurrent)),
            ("show my clipboard history", .clipboard(.showHistory)),
            ("show me my clipboard history", .clipboard(.showHistory)),
            ("clipboard history", .clipboard(.showHistory)),
            ("what did I copy earlier", .clipboard(.showHistory)),
            ("what have I copied recently", .clipboard(.showHistory)),
            ("paste the link I copied earlier", .clipboard(.pasteRecent(matching: "link"))),
            ("Paste the link I copied.", .clipboard(.pasteRecent(matching: "link"))),
            ("paste that link I copied earlier", .clipboard(.pasteRecent(matching: "link"))),
            ("paste the email I copied", .clipboard(.pasteRecent(matching: "email"))),
            ("paste the email address I copied earlier", .clipboard(.pasteRecent(matching: "email"))),
            ("paste the address I copied", .clipboard(.pasteRecent(matching: "address"))),
            ("paste the phone number I copied", .clipboard(.pasteRecent(matching: "phone"))),
            ("paste the tax form I copied earlier", .clipboard(.pasteRecent(matching: "tax form"))),
            ("paste what I copied earlier", .clipboard(.pasteRecent(matching: nil))),
            ("paste the last thing I copied", .clipboard(.pasteRecent(matching: nil))),
            ("paste the previous thing I copied", .clipboard(.pasteRecent(matching: nil))),
            ("paste my last copy", .clipboard(.pasteRecent(matching: nil))),
            ("paste the link from my clipboard history", .clipboard(.pasteRecent(matching: "link"))),
            ("paste the link from earlier", .clipboard(.pasteRecent(matching: "link"))),
        ]
        for (text, expected) in cases {
            TestSupport.expectEqual(parse(text), expected)
        }
        for text in ["paste", "copy", "paste it here", "copy this", "paste and match style", "select all", "clear my clipboard"] {
            TestSupport.expect(parse(text) == nil, "'\(text)' is not a clipboard-history command")
        }
    }

    /// Phrases that belong to B's app and website logic, or to other builders, must fall through.
    private static func notStealing() {
        let theirs = [
            "open Chrome", "open Google Chrome", "open YouTube", "open Spotify", "open hala discover dot com",
            "open System Settings", "open my calendar", "open Calendar", "open Notes", "open the Terminal", "open Google Slides",
            "open Google Docs", "open Microsoft Word", "open PowerPoint", "open Keynote", "open Preview", "open slides",
            "open Pages", "open Finder", "open Music", "open Photos", "open Messages", "open Mail", "open zoom",
            "open the Notes app", "open Visual Studio Code", "open Netflix", "open GitHub", "open Gmail",
            "close Spotify", "quit Chrome", "switch to Chrome", "show me Chrome", "go to Safari", "hide Slack",
            "put Chrome on the left", "put Chrome on the left and Warp on the right", "maximize Chrome",
            "find my iPhone", "find the best pizza near me", "show me the weather", "show me the way", "what's the weather",
            "what time is it", "what's the capital of France", "volume up", "next song", "play music", "take a screenshot",
            "mute", "lock my screen", "type hello", "stop listening", "who is next", "what's new",
            "search for resume templates", "google my resume", "set a timer for 5 minutes",
        ]
        for text in theirs {
            TestSupport.expect(parse(text) == nil, "'\(text)' must not be claimed: \(String(describing: parse(text)))")
        }
    }

    private static let apps: [InstalledApp] = [
        "Google Chrome", "Messages", "Spotify", "Calendar", "Notes", "Finder", "Preview", "Visual Studio Code",
    ].map { InstalledApp(name: $0, bundleIdentifier: nil, url: URL(fileURLWithPath: "/Applications/\($0).app")) }

    /// The full parser, so ordering and clause splitting are exercised too.
    private static func throughTheRealParser() {
        let parser = RioActionParser(installedApps: apps)
        TestSupport.expectEqual(parser.parse("Rio, open my resume."), .actions([.openFile(query: "resume")]))
        TestSupport.expectEqual(parser.parse("open the MAT108 homework 6 PDF"), .actions([.openFile(query: "MAT108 homework 6 PDF")]))
        TestSupport.expectEqual(parser.parse("show me the Hala deck in Finder"), .actions([.revealFile(query: "Hala deck")]))
        TestSupport.expectEqual(parser.parse("what's next"), .actions([.calendarAgenda(.next)]))
        TestSupport.expectEqual(parser.parse("join my next meeting please"), .actions([.joinNextMeeting]))
        TestSupport.expectEqual(parser.parse("what's on my clipboard"), .actions([.clipboard(.readCurrent)]))
        TestSupport.expectEqual(parser.parse("paste the link I copied earlier"), .actions([.clipboard(.pasteRecent(matching: "link"))]))
        TestSupport.expectEqual(parser.parse("open Chrome"), .actions([.openApp(name: "Google Chrome")]))
        TestSupport.expectEqual(parser.parse("open Spotify"), .actions([.openApp(name: "Spotify")]))
        TestSupport.expectEqual(parser.parse("open Calendar"), .actions([.openApp(name: "Calendar")]))
        if case .actions(let actions) = parser.parse("open YouTube"), case .openURL? = actions.first {
        } else {
            fatalError("open YouTube must still reach the website logic")
        }
        if case .actions(let actions) = parser.parse("add study session tomorrow at 7 pm"),
           case .createEvent(let title, _, _)? = actions.first {
            TestSupport.expectEqual(title, "Study session")
        } else {
            fatalError("create event should parse through the real parser")
        }
    }
}
