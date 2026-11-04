import Foundation

/// The help sheet must never promise something Rio can't do: every example goes through the real
/// parser (and, for texts from the iPhone, the real "starts with Rio" filter) and must land on the
/// action it advertises.
enum RioHelpCatalogueTests {
    private static let apps = ["Google Chrome", "Spotify", "Messages", "Slack", "Notes", "Safari", "Zoom"].map {
        InstalledApp(name: $0, bundleIdentifier: nil, url: URL(fileURLWithPath: "/Applications/\($0).app"))
    }

    /// What an example must turn into.
    private enum Expected {
        /// Exactly these actions.
        case actions([RioAction])
        /// Not a built-in phrase: it goes to the smart resolver with these words (a question,
        /// "remind me to ..."), which answers or plans it.
        case brain(String)
    }

    private static func key(_ key: String) -> KeyCombo {
        KeyCombo(key: key, command: true, shift: false, option: false, control: false)
    }

    /// Every example in the catalogue, with what it must parse to. The test fails on an example
    /// that is missing here, so a new phrase can't ship unchecked.
    private static let expectations: [String: Expected] = [
        // Apps and websites
        "open Chrome": .actions([.openApp(name: "Google Chrome")]),
        "switch to Messages": .actions([.switchToApp(name: "Messages")]),
        "quit Spotify": .actions([.quitApp(name: "Spotify")]),
        "hide Slack": .actions([.hideApp(name: "Slack")]),
        "search for best pizza near me": .actions([.webSearch(query: "best pizza near me")]),
        // Mac controls
        "volume up": .actions([.volume(.up)]),
        "next song": .actions([.media(.next)]),
        "turn off wifi": .actions([.systemToggle(.wifi, isOn: false)]),
        "set the volume to 40": .actions([.volume(.set(40))]),
        "dark mode on": .actions([.systemToggle(.darkMode, isOn: true)]),
        "how much battery do I have": .actions([.batteryStatus]),
        // Windows
        "put Chrome on the left": .actions([.window(WindowCommand(appName: "Google Chrome", placement: .leftHalf))]),
        "maximize Safari": .actions([.window(WindowCommand(appName: "Safari", placement: .maximize))]),
        "move this to the other screen": .actions([.window(WindowCommand(appName: nil, placement: .nextScreen))]),
        "minimize Notes": .actions([.window(WindowCommand(appName: "Notes", placement: .minimize))]),
        // Timers
        "set a timer for 10 minutes": .actions([.startTimer(seconds: 600, label: nil)]),
        "how much time is left": .actions([.timerStatus]),
        "cancel the timer": .actions([.cancelTimer]),
        "timer 30 seconds called pasta": .actions([.startTimer(seconds: 30, label: "pasta")]),
        // Keys and browser
        "new tab": .actions([.browser(.newTab)]),
        "go back": .actions([.browser(.back)]),
        "press command T": .actions([.pressKeys(key("t"))]),
        "scroll down": .actions([.browser(.scrollDown)]),
        "refresh": .actions([.browser(.reload)]),
        // Files and calendar
        "open my resume": .actions([.openFile(query: "resume")]),
        "what's on my calendar today": .actions([.calendarAgenda(.today)]),
        "join my meeting": .actions([.joinNextMeeting]),
        "what's next": .actions([.calendarAgenda(.next)]),
        "what's on my clipboard": .actions([.clipboard(.readCurrent)]),
        // Screen and clicks
        "what's on my screen": .actions([.describeScreen(question: nil)]),
        "click the Submit button": .actions([.click(label: "Submit button", ordinal: nil)]),
        "find me a flight to Doha": .actions([.runTask(goal: "find me a flight to Doha")]),
        "the second one": .actions([.click(label: "", ordinal: 2)]),
        "fill in the name field with Omar": .actions([.fillField(label: "name field", text: "Omar")]),
        "take a screenshot": .actions([.screenshot(.fullScreen)]),
        // Memory and notes
        "remember my locker code is 4321": .actions([.remember(fact: "my locker code is 4321")]),
        "what's my locker code": .actions([.recall(query: "locker code")]),
        "note that I need to buy eggs": .actions([.addNote(text: "I need to buy eggs")]),
        "forget my locker code": .actions([.forget(query: "locker code")]),
        // Email and messages
        "text mom I'm late": .actions([.sendMessage(to: "mom", body: "I'm late")]),
        "reply saying sounds good": .actions([.replyInConversation(body: "sounds good")]),
        "email Sam saying I'm running late": .actions([.draftEmail(to: "Sam", subject: nil, body: "I'm running late")]),
        "draft an email to Sam saying hi": .actions([.draftEmail(to: "Sam", subject: nil, body: "Hi")]),
        // Maths, units and time
        "what's 15% of 84": .actions([.calculate(expression: "what's 15% of 84")]),
        "5 miles in kilometers": .actions([.calculate(expression: "5 miles in kilometers")]),
        "what time is it in Tokyo": .actions([.calculate(expression: "what time is it in Tokyo")]),
        "what's 20 percent tip on 45": .actions([.calculate(expression: "what's 20 percent tip on 45")]),
        // Translator
        "translate what's being said": .actions([.startTranslation]),
        "say it": .actions([.speakLastTranslation]),
        "stop translating": .actions([.stopTranslation]),
        "translate this to Arabic": .actions([.selectionTask(.translate(language: "Arabic"))]),
        // Smart help
        "summarize this": .actions([.selectionTask(.summarize)]),
        "explain this": .actions([.selectionTask(.explain)]),
        "remind me to call mom at 5": .actions([RioReminderPhrases.parse("remind me to call mom at 5")!]),
        "read me the last message": .actions([.readAloud(.lastMessage)]),
        // Follow-ups and history (the sheet's story: "open Chrome" ran just before)
        "open it again": .actions([.openApp(name: "Google Chrome")]),
        "do the same for Spotify": .actions([.openApp(name: "Spotify")]),
        "what did I say about the budget": .actions([.searchHistory(query: "the budget")]),
        "search my history for the budget": .actions([.searchHistory(query: "the budget")]),
        // Writing
        "make that more formal": .actions([.editLastDictation(instruction: "make it more formal")]),
        "paste that as bullet points": .actions([.smartPaste(instruction: "as bullet points")]),
        "write a reply saying I'm in": .actions([.writeForMe(instruction: "a reply saying I'm in")]),
        "make that shorter": .actions([.editLastDictation(instruction: "make it shorter")]),
        "paste that in Arabic": .actions([.smartPaste(instruction: "in arabic")]),
        // Automations
        "every weekday at 8:50 open Zoom": .actions([.scheduleCommand(command: "open Zoom", when: "every weekday at 8:50")]),
        "when AirPods connect open Spotify": .actions([.addTrigger(command: "open Spotify", trigger: "audio:AirPods")]),
        "watch me": .actions([.recordMacro(name: "")]),
        "run the morning setup macro": .actions([.runMacro(name: "morning setup")]),
        "stop watching": .actions([.stopRecordingMacro]),
        "list my automations": .actions([.listAutomations]),
        // Find and tidy
        "find the PDF Ali sent me last week": .actions([.findThing(query: "the PDF Ali sent me last week")]),
        "clean up my downloads": .actions([.organizeDownloads]),
        "copy the text from this image": .actions([.copyTextFromScreen]),
        "copy the text from the screen": .actions([.copyTextFromScreen]),
        // Outside world
        "what's the weather in Doha": .actions([.weather(place: "Doha")]),
        "play my Discover Weekly": .actions([.playMusic(query: "my Discover Weekly")]),
        "what's due on Canvas": .actions([.canvasDue(range: nil)]),
        "what's the news": .actions([.news(topic: nil)]),
        "will it rain tomorrow": .actions([.weather(place: nil)]),
        "add call Ali to my roadmap in Notion": .actions([.notionAdd(text: "call Ali", page: "roadmap")]),
        // Meetings
        "start the meeting copilot": .actions([.meeting(.start)]),
        "what did they just say": .actions([.meeting(.whatWasSaid)]),
        "what are the action items": .actions([.meeting(.actionItems)]),
        "recap the meeting": .actions([.meeting(.recap)]),
        "stop the meeting copilot": .actions([.meeting(.stop)]),
        // Claude Code
        "tell Claude to fix the failing test": .actions([.claudeCode(.send("fix the failing test"))]),
        "what's Claude doing": .actions([.claudeCode(.status)]),
        "approve that": .actions([.claudeCode(.approve)]),
        "deny that": .actions([.claudeCode(.deny)]),
        // Undo and help ("stop" with no timer only stops music or speech; AppState decides)
        "undo": .actions([.undoLast]),
        "put it back": .actions([.undoLast]),
        "what can you do": .actions([.showHelp]),
        "stop": .actions([.cancelTimer]),
        // Conversation mode and the iPhone ("Rio, ..." as heard or texted)
        "Rio, how far is the moon": .brain("how far is the moon"),
        "Rio, open Chrome": .actions([.openApp(name: "Google Chrome")]),
        "Rio, stop listening": .actions([.stopListening]),
        "Rio, what's the weather": .actions([.weather(place: nil)]),
        "Rio, open Spotify": .actions([.openApp(name: "Spotify")]),
    ]

    static func run() {
        RioFollowUpMemory.shared.clear()
        testEveryCategoryHasExamples()
        testCatalogueCoversTheAbilities()
        testExamplesParseToTheirActions()
        testArabicExamples()
        testTipsAndPhoneTexts()
        testKeys()
        testSpokenSummary()
        testHelpPhrases()
        RioFollowUpMemory.shared.clear()
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
            for shown in category.examples.prefix(RioHelpCatalogue.shownExamples) {
                TestSupport.expect(shown.count <= 35, "\"\(shown)\" fits its column on the sheet")
            }
        }
        // Three columns of at most seven rows fit a laptop screen.
        TestSupport.expect(RioHelpCatalogue.categories.count <= 21, "the sheet fits on a laptop screen")
    }

    private static func testCatalogueCoversTheAbilities() {
        let titles = Set(RioHelpCatalogue.categories.map(\.title))
        let needed = [
            "Apps and websites", "Mac controls", "Windows", "Timers", "Keys and browser", "Files and calendar",
            "Smart help", "Undo and help", "Follow-ups and history", "Writing", "Automations", "Find and tidy",
            "Outside world", "Meetings", "Claude Code",
        ]
        for title in needed {
            TestSupport.expect(titles.contains(title), "missing category \(title)")
        }
        // Every wave 4-5 ability has at least one example of its own.
        let parser = RioActionParser(installedApps: apps)
        RioFollowUpMemory.shared.record(.openApp(name: "Google Chrome"))
        let examples = RioHelpCatalogue.categories.flatMap(\.examples) + RioHelpCatalogue.tips.flatMap(\.examples)
        let kinds = Set(examples.flatMap { example -> [String] in
            guard case .actions(let actions) = parser.parse(RioActionTranscript.stripName(from: example)) else { return [] }
            return actions.map(kind)
        })
        for ability in [
            "searchHistory", "editLastDictation", "writeForMe", "smartPaste", "scheduleCommand", "addTrigger",
            "recordMacro", "runMacro", "listAutomations", "findThing", "organizeDownloads", "copyTextFromScreen",
            "weather", "news", "playMusic", "notionAdd", "canvasDue", "meeting", "claudeCode", "stopListening",
        ] {
            TestSupport.expect(kinds.contains(ability), "the help sheet shows no \(ability) example")
        }
        RioFollowUpMemory.shared.clear()
    }

    private static func testExamplesParseToTheirActions() {
        let parser = RioActionParser(installedApps: apps)
        let examples = RioHelpCatalogue.categories.filter { $0.title != "Arabic" }.flatMap(\.examples)
            + RioHelpCatalogue.tips.flatMap(\.examples)
        for example in examples {
            // Follow-ups point at the last command: "open Chrome", just before each example.
            RioFollowUpMemory.shared.record(.openApp(name: "Google Chrome"))
            guard let expected = expectations[example] else {
                TestSupport.expect(false, "help example \"\(example)\" has no expected action in the test")
                continue
            }
            let parsed = parser.parse(RioActionTranscript.stripName(from: example))
            switch (expected, parsed) {
            case let (.actions(want), .actions(got)):
                TestSupport.expect(got == want, "help example \"\(example)\": expected \(want), got \(got)")
            case let (.brain(words), .unknown(text)):
                TestSupport.expect(text == words, "help example \"\(example)\" reaches the brain as \"\(words)\", got \"\(text)\"")
            default:
                TestSupport.expect(false, "help example \"\(example)\": expected \(expected), got \(parsed)")
            }
        }
        RioFollowUpMemory.shared.clear()
    }

    /// Arabic examples go through the offline table to English the parser understands.
    private static func testArabicExamples() {
        let parser = RioActionParser(installedApps: apps)
        for example in RioHelpCatalogue.arabicExamples {
            guard case .offline(let english) = RioCommandTranslationPlan.plan(for: example) else {
                TestSupport.expect(false, "Arabic help example \"\(example)\" isn't in the offline table")
                continue
            }
            guard case .actions = parser.parse(RioActionTranscript.stripName(from: english)) else {
                TestSupport.expect(false, "Arabic help example \"\(example)\" (\(english)) isn't understood")
                continue
            }
        }
    }

    private static func testTipsAndPhoneTexts() {
        let titles = RioHelpCatalogue.tips.map(\.title)
        TestSupport.expect(titles.contains("Conversation mode"), "conversation mode is explained")
        TestSupport.expect(titles.contains("From your iPhone"), "texting Rio from the iPhone is explained")
        for tip in RioHelpCatalogue.tips {
            TestSupport.expect(!tip.symbol.isEmpty, "\(tip.title) has an icon")
            TestSupport.expect(!tip.detail.isEmpty && tip.detail.count <= 100, "\(tip.title) detail is one short line")
            TestSupport.expect(!tip.examples.isEmpty, "\(tip.title) has examples")
            for example in tip.examples {
                TestSupport.expect(example.hasPrefix("Rio, "), "\"\(example)\" starts with the name, as it must be said or texted")
            }
        }
        // A text from the iPhone runs only when it starts with "Rio".
        for example in RioHelpCatalogue.tips.first(where: { $0.title == "From your iPhone" })?.examples ?? [] {
            TestSupport.expect(RioPhoneText.commandText(example) != nil, "the iPhone text \"\(example)\" is accepted")
        }
    }

    private static func testKeys() {
        let keys = RioHelpCatalogue.keys.map(\.keys)
        for needed in ["Hold Fn", "Double-tap Fn", "Hold Fn + Control", "Fn + Control + Option", "Right Command"] {
            TestSupport.expect(keys.contains(needed), "the sheet shows \(needed)")
        }
        TestSupport.expect(RioHelpCatalogue.keys.allSatisfy { !$0.meaning.isEmpty }, "every key says what it does")
        // The chord on the sheet is the chord the matcher listens for: left Fn, Control and Option.
        TestSupport.expect(ShortcutConfiguration.conversationChordKeyCodes == [63, 59, 58], "chord keys")
    }

    private static func testSpokenSummary() {
        let line = RioHelpCatalogue.spokenSummary
        TestSupport.expect(!line.isEmpty && line.count < 140, "one short line: \(line)")
        TestSupport.expect(line.lowercased().contains("timer"), "mentions a headline ability")
        TestSupport.expect(line.lowercased().contains("question"), "mentions that Rio answers questions")
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

    /// "openApp" for `.openApp(name: "Spotify")`.
    private static func kind(_ action: RioAction) -> String {
        let text = String(describing: action)
        return String(text.prefix { $0 != "(" })
    }
}
