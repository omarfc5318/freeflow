import Foundation

/// Transcript -> [RioAction]. Synthetic installed-apps list only: nothing here launches an app,
/// changes the volume or touches the network.
enum RioActionParserTests {
    static let apps: [InstalledApp] = [
        "Google Chrome", "Messages", "Claude", "Warp", "Visual Studio Code", "Spotify", "zoom.us",
        "Granola", "Notes", "Calendar", "System Settings", "Finder", "Mail", "Maps", "Safari",
        "Terminal", "Microsoft Word", "Microsoft Excel", "Music", "Photos", "Reminders", "FaceTime", "TextEdit",
        "Slack", "GitHub Desktop",
    ].map { InstalledApp(name: $0, bundleIdentifier: "test.\(RioText.compact($0))", url: URL(fileURLWithPath: "/Applications/\($0).app")) }

    // MARK: Expectation helpers

    private static func o(_ n: String) -> RioAction { .openApp(name: n) }
    private static func q(_ n: String) -> RioAction { .quitApp(name: n) }
    private static func sw(_ n: String) -> RioAction { .switchToApp(name: n) }
    private static func h(_ n: String) -> RioAction { .hideApp(name: n) }
    private static func w(_ app: String?, _ p: WindowPlacement) -> RioAction { .window(WindowCommand(appName: app, placement: p)) }
    private static func u(_ s: String) -> RioAction { .openURL(URL(string: s)!) }
    private static func a(_ actions: RioAction...) -> RioActionParse { .actions(actions) }
    private static func unk(_ s: String) -> RioActionParse { .unknown(s) }

    private static let gc = "Google Chrome"

    private static var cases: [(String, RioActionParse)] {
        [
            // Opening apps, Whisper-style phrasing
            ("Open Chrome.", a(o(gc))),
            ("open chrome", a(o(gc))),
            ("Open up Chrome", a(o(gc))),
            ("launch Chrome", a(o(gc))),
            ("Start Chrome", a(o(gc))),
            ("fire up Chrome", a(o(gc))),
            ("run Chrome", a(o(gc))),
            ("Rio, open Chrome.", a(o(gc))),
            ("Ryo open Chrome", a(o(gc))),
            ("Reo, open chrome.", a(o(gc))),
            ("hey Rio open chrome", a(o(gc))),
            ("yo Rio, open Chrome", a(o(gc))),
            ("Yo, Rio. Open Chrome, bro.", a(o(gc))),
            ("open Chrome please", a(o(gc))),
            ("Open Chrome bro", a(o(gc))),
            ("Could you please open Chrome?", a(o(gc))),
            ("can you open chrome for me", a(o(gc))),
            ("okay Rio, go ahead and open Chrome", a(o(gc))),
            ("open Crome", a(o(gc))),
            ("open V S code", a(o("Visual Studio Code"))),
            ("open VS Code", a(o("Visual Studio Code"))),
            ("open vscode", a(o("Visual Studio Code"))),
            ("open visual studio code", a(o("Visual Studio Code"))),
            ("open spotify", a(o("Spotify"))),
            ("Open Spotify.", a(o("Spotify"))),
            ("launch warp", a(o("Warp"))),
            ("open messages", a(o("Messages"))),
            ("open iMessage", a(o("Messages"))),
            ("open system settings", a(o("System Settings"))),
            ("open settings", a(o("System Settings"))),
            ("open system preferences", a(o("System Settings"))),
            ("open finder", a(o("Finder"))),
            ("open notes", a(o("Notes"))),
            ("open calendar", a(o("Calendar"))),
            ("open zoom", a(o("zoom.us"))),
            ("open granola", a(o("Granola"))),
            ("open claude", a(o("Claude"))),
            ("open the Chrome app", a(o(gc))),
            ("open my notes", a(o("Notes"))),
            ("open word", a(o("Microsoft Word"))),
            ("open terminal", a(o("Terminal"))),
            ("open Zorblax", a(o("Zorblax"))),
            ("open the door", unk("open the door")),
            ("open a new tab", a(.browser(.newTab))),
            ("Start a timer", unk("Start a timer")),
            ("Start recording", unk("Start recording")),

            // Websites vs apps
            ("open YouTube", a(u("https://www.youtube.com"))),
            ("open you tube", a(u("https://www.youtube.com"))),
            ("open gmail", a(u("https://mail.google.com"))),
            ("open GitHub", a(u("https://github.com"))),
            ("open Netflix", a(u("https://www.netflix.com"))),
            ("open google", a(u("https://www.google.com"))),
            ("open reddit", a(u("https://www.reddit.com"))),
            ("open Notion", a(u("https://www.notion.so"))),
            ("open slack", a(o("Slack"))),
            ("open maps", a(o("Maps"))),
            ("open hala discover dot com", a(u("https://haladiscover.com"))),
            ("open github.com", a(u("https://github.com"))),
            ("open example dot org", a(u("https://example.org"))),
            ("open w w w dot google dot com", a(u("https://www.google.com"))),
            ("open file dot txt", unk("open file dot txt")),
            ("go to youtube", a(u("https://www.youtube.com"))),
            ("open youtube in the browser", a(u("https://www.youtube.com"))),
            ("visit wikipedia", a(u("https://www.wikipedia.org"))),

            // Quit, hide, switch
            ("quit Chrome", a(q(gc))),
            ("close Spotify", a(q("Spotify"))),
            ("kill Zoom", a(q("zoom.us"))),
            ("Quit chrome.", a(q(gc))),
            ("Rio, close Messages", a(q("Messages"))),
            ("shut down chrome", a(q(gc))),
            ("close this window", a(.pressKeys(KeyCombo(key: "w", command: true, shift: false, option: false, control: false)))),
            ("close everything", unk("close everything")),
            ("quit all apps", unk("quit all apps")),
            ("shut down the computer", unk("shut down the computer")),
            ("shut down", unk("shut down")),
            ("quit", unk("quit")),
            ("hide Chrome", a(h(gc))),
            ("hide Spotify please", a(h("Spotify"))),
            ("hide this", unk("hide this")),
            ("switch to Chrome", a(sw(gc))),
            ("go to Messages", a(sw("Messages"))),
            ("show me Warp", a(sw("Warp"))),
            ("show me Notes", a(sw("Notes"))),
            ("switch to Crome", a(sw(gc))),
            ("jump to Slack", a(sw("Slack"))),
            ("switch to zorblax", unk("switch to zorblax")),
            ("show me a picture of a cat", unk("show me a picture of a cat")),
            ("go to the store", unk("go to the store")),

            // Compound commands
            ("open Chrome and Spotify", a(o(gc), o("Spotify"))),
            ("Open Chrome, Spotify and Warp", a(o(gc), o("Spotify"), o("Warp"))),
            ("open chrome and then open spotify", a(o(gc), o("Spotify"))),
            ("quit Chrome and Spotify", a(q(gc), q("Spotify"))),
            ("open Chrome and tell me a joke", unk("open Chrome and tell me a joke")),
            ("put Chrome on the left and Warp on the right", a(w(gc, .leftHalf), w("Warp", .rightHalf))),
            ("Put Chrome on the left, and Warp on the right.", a(w(gc, .leftHalf), w("Warp", .rightHalf))),
            ("open Chrome and put it on the left", a(o(gc), w(gc, .leftHalf))),
            ("open Chrome and set volume to 30", a(o(gc), .volume(.set(30)))),
            ("mute and open spotify", a(.volume(.mute), o("Spotify"))),
            ("open chrome and search for cats", a(o(gc), .webSearch(query: "cats"))),
            ("search for cats and dogs", a(.webSearch(query: "cats and dogs"))),
            ("open chrome then volume up then play", a(o(gc), .volume(.up), .media(.play))),

            // Search
            ("search for pizza near me", a(.webSearch(query: "pizza near me"))),
            ("Search for the best pizza in Doha.", a(.webSearch(query: "the best pizza in Doha"))),
            ("google swift concurrency", a(.webSearch(query: "swift concurrency"))),
            ("Google how to tie a tie", a(.webSearch(query: "how to tie a tie"))),
            ("look up the weather in Doha", a(.weather(place: "Doha"))),
            ("look up cats", a(.webSearch(query: "cats"))),
            ("search the web for rust", a(.webSearch(query: "rust"))),
            ("search cats", a(.webSearch(query: "cats"))),
            ("Rio, search for dog food, please", a(.webSearch(query: "dog food"))),
            ("search YouTube for lofi beats", a(u("https://www.youtube.com/results?search_query=lofi%20beats"))),
            ("search for lofi beats on YouTube", a(u("https://www.youtube.com/results?search_query=lofi%20beats"))),
            ("youtube search cats", a(u("https://www.youtube.com/results?search_query=cats"))),
            ("google chrome", unk("google chrome")),
            ("google docs", unk("google docs")),
            ("search", unk("search")),
            ("search for", unk("search for")),

            // Type and stop listening
            ("type hello world", a(.typeText("hello world"))),
            ("Type: hello, how are you?", a(.typeText("hello, how are you?"))),
            ("write thanks for the update.", a(.typeText("thanks for the update"))),
            ("type hello and goodbye", a(.typeText("hello and goodbye"))),
            ("Rio, type see you at five please", a(.typeText("see you at five please"))),
            ("write a poem about the sea", unk("write a poem about the sea")),
            ("write me an email", unk("write me an email")),
            ("type", unk("type")),
            ("stop listening", a(.stopListening)),
            ("Rio, stop listening.", a(.stopListening)),
            ("that's all", a(.stopListening)),
            ("That\u{2019}s all.", a(.stopListening)),
            ("go to sleep", a(.stopListening)),
            ("okay Rio you can stop listening", a(.stopListening)),

            // Volume
            ("volume up", a(.volume(.up))),
            ("volume down", a(.volume(.down))),
            ("turn it up", a(.volume(.up))),
            ("turn it down", a(.volume(.down))),
            ("turn up the volume", a(.volume(.up))),
            ("turn the volume down", a(.volume(.down))),
            ("make it louder", a(.volume(.up))),
            ("quieter", a(.volume(.down))),
            ("lower the volume", a(.volume(.down))),
            ("raise the volume a bit", a(.volume(.up))),
            ("volume 40", a(.volume(.set(40)))),
            ("set volume to 40%", a(.volume(.set(40)))),
            ("volume to 60 percent", a(.volume(.set(60)))),
            ("set the volume to fifty", a(.volume(.set(50)))),
            ("set the volume to forty five percent", a(.volume(.set(45)))),
            ("volume 150", a(.volume(.set(100)))),
            ("volume zero", a(.volume(.set(0)))),
            ("max volume", a(.volume(.set(100)))),
            ("volume max", a(.volume(.set(100)))),
            ("turn the volume to 25", a(.volume(.set(25)))),
            ("turn it all the way up", a(.volume(.set(100)))),
            ("mute", a(.volume(.mute))),
            ("Mute the sound.", a(.volume(.mute))),
            ("unmute", a(.volume(.unmute))),
            ("un mute", a(.volume(.unmute))),
            ("turn the sound off", a(.volume(.mute))),
            ("turn the sound on", a(.volume(.unmute))),
            ("volume", unk("volume")),
            ("turn the lights off", unk("turn the lights off")),
            ("turn up the heat", unk("turn up the heat")),
            ("turn it", unk("turn it")),

            // Media
            ("play", a(.media(.play))),
            ("Pause.", a(.media(.pause))),
            ("pause the music", a(.media(.pause))),
            ("play music", a(.media(.play))),
            ("resume", a(.media(.play))),
            ("play pause", a(.media(.playPause))),
            ("toggle playback", a(.media(.playPause))),
            ("stop playing", a(.media(.pause))),
            ("stop playing this song", a(.media(.pause))),
            ("stop spotify please", a(.media(.pause))),
            ("next song", a(.media(.next))),
            ("skip", a(.media(.next))),
            ("skip this song", a(.media(.next))),
            ("next track", a(.media(.next))),
            ("play the next song", a(.media(.next))),
            ("previous song", a(.media(.previous))),
            ("go back", a(.browser(.back))),
            ("play taylor swift", .actions([.playMusic(query: "taylor swift")])),
            ("stop the music", a(.media(.pause))),

            // Lock and screenshots
            ("lock my screen", a(.lockScreen)),
            ("lock screen", a(.lockScreen)),
            ("lock the computer", a(.lockScreen)),
            ("lock", unk("lock")),
            ("lock the door", unk("lock the door")),
            ("take a screenshot", a(.screenshot(.fullScreen))),
            ("screenshot", a(.screenshot(.fullScreen))),
            ("take a screen shot", a(.screenshot(.fullScreen))),
            ("take a screenshot of the window", a(.screenshot(.window))),
            ("grab a screenshot of this window", a(.screenshot(.window))),
            ("screenshot of the selection", a(.screenshot(.selection))),
            ("take a screenshot of a selection", a(.screenshot(.selection))),
            ("screenshot of the whole screen", a(.screenshot(.fullScreen))),
            ("capture the screen", a(.screenshot(.fullScreen))),
            ("take a screenshot of my dog", unk("take a screenshot of my dog")),

            // Do not disturb
            ("turn on do not disturb", a(.doNotDisturb(isOn: true))),
            ("Turn off Do Not Disturb.", a(.doNotDisturb(isOn: false))),
            ("turn do not disturb on", a(.doNotDisturb(isOn: true))),
            ("enable do not disturb", a(.doNotDisturb(isOn: true))),
            ("disable focus mode", a(.doNotDisturb(isOn: false))),
            ("turn on focus", a(.doNotDisturb(isOn: true))),
            ("turn off focus mode", a(.doNotDisturb(isOn: false))),
            ("do not disturb", a(.doNotDisturb(isOn: true))),
            ("turn on the lights", unk("turn on the lights")),

            // Windows
            ("move Chrome to the left", a(w(gc, .leftHalf))),
            ("put Warp on the right", a(w("Warp", .rightHalf))),
            ("snap chrome right", a(w(gc, .rightHalf))),
            ("move this window to the left", a(w(nil, .leftHalf))),
            ("put it on the right", a(w(nil, .rightHalf))),
            ("put Chrome on top", a(w(gc, .topHalf))),
            ("put chrome on the bottom half", a(w(gc, .bottomHalf))),
            ("maximize Chrome", a(w(gc, .maximize))),
            ("maximize", a(w(nil, .maximize))),
            ("maximize the window", a(w(nil, .maximize))),
            ("full screen Chrome", a(w(gc, .maximize))),
            ("make Chrome full screen", a(w(gc, .maximize))),
            ("go full screen", a(w(nil, .maximize))),
            ("center Chrome", a(w(gc, .center))),
            ("center the window", a(w(nil, .center))),
            ("put chrome in the center", a(w(gc, .center))),
            ("minimize Chrome", a(w(gc, .minimize))),
            ("minimize", a(w(nil, .minimize))),
            ("minimise warp", a(w("Warp", .minimize))),
            ("move Chrome to the other screen", a(w(gc, .nextScreen))),
            ("move it to the next screen", a(w(nil, .nextScreen))),
            ("send Warp to my other monitor", a(w("Warp", .nextScreen))),
            ("move chrome to the top left", unk("move chrome to the top left")),
            ("minimize everything", unk("minimize everything")),

            // Nothing to do
            ("Rio.", .empty),
            ("Rio", .empty),
            ("Hey Rio,", .empty),
            ("okay Rio", .empty),
            ("uh", .empty),
            ("", .empty),
            ("   ", .empty),

            // Not an action: left for the smart resolver
            ("what's the weather", .actions([.weather(place: nil)])),
            ("tell me a joke", unk("tell me a joke")),
            ("chrome", unk("chrome")),
            ("hello there", unk("hello there")),
            ("send the report to Sarah", unk("send the report to Sarah")),
            ("remind me to call mom", .actions([.createReminder(title: "Call mom", due: nil)])),
            ("summarize the news", unk("summarize the news")),
        ]
    }

    static func run() {
        let parser = RioActionParser(installedApps: apps)
        var failures: [String] = []
        for (input, expected) in cases {
            let actual = parser.parse(input)
            if actual != expected {
                failures.append("\"\(input)\": expected \(expected), got \(actual)")
            }
        }
        TestSupport.expect(cases.count >= 120, "needs 120+ parser cases, has \(cases.count)")
        TestSupport.expect(failures.isEmpty, "\(failures.count) parser failures:\n" + failures.joined(separator: "\n"))
        testNoActionIsOutsideTheClosedSet(parser)
        testEveryURLIsHTTPS(parser)
        RioParserRoundOneTests.run()
    }

    /// Parser output never contains the smart-only actions.
    private static func testNoActionIsOutsideTheClosedSet(_ parser: RioActionParser) {
        for (input, _) in cases {
            guard case .actions(let list) = parser.parse(input) else { continue }
            for action in list {
                switch action {
                case .sendMessage, .selectionTask:
                    TestSupport.expect(false, "parser emitted a smart-only action for \"\(input)\"")
                default: break
                }
            }
        }
    }

    private static func testEveryURLIsHTTPS(_ parser: RioActionParser) {
        for (input, _) in cases {
            guard case .actions(let list) = parser.parse(input) else { continue }
            for case .openURL(let url) in list {
                TestSupport.expect(RioWebURLs.isSafeWebURL(url), "unsafe URL \(url) for \"\(input)\"")
            }
        }
        let hostile = [
            "open file:///etc/passwd", "open javascript:alert(1)", "open ftp dot example dot com",
            "open x dot sh; reboot", "open evil dot zzz",
        ]
        for input in hostile {
            if case .actions(let list) = parser.parse(input) {
                for case .openURL(let url) in list {
                    TestSupport.expect(RioWebURLs.isSafeWebURL(url), "unsafe URL \(url) for \"\(input)\"")
                }
            }
        }
    }
}

/// Round-1 fixes for the envelope, clause and confidence handling (synthetic apps only).
enum RioParserRoundOneTests {
    private static let gc = "Google Chrome"
    private static let apps = RioActionParserTests.apps + ["RStudio", "Simulator", "Zen"].map {
        InstalledApp(name: $0, bundleIdentifier: "test.\(RioText.compact($0))", url: URL(fileURLWithPath: "/Applications/\($0).app"))
    }
    private static let parser = RioActionParser(installedApps: apps, isRecordingMacro: false)
    private static let recording = RioActionParser(installedApps: apps, isRecordingMacro: true)

    private static func key(_ k: String, cmd: Bool = false, shift: Bool = false, option: Bool = false, ctrl: Bool = false) -> RioAction {
        .pressKeys(KeyCombo(key: k, command: cmd, shift: shift, option: option, control: ctrl))
    }
    private static func u(_ s: String) -> RioAction { .openURL(URL(string: s)!) }
    private static func a(_ actions: RioAction...) -> RioActionParse { .actions(actions) }
    private static func w(_ app: String?, _ p: WindowPlacement) -> RioAction { .window(WindowCommand(appName: app, placement: p)) }

    private static func isUnknown(_ parse: RioActionParse) -> Bool {
        if case .unknown = parse { return true }
        return false
    }

    nonisolated(unsafe) private static var failures: [String] = []

    private static func eq<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", line: UInt = #line) {
        if actual != expected { failures.append("line \(line) \(message): expected \(expected), got \(actual)") }
    }

    private static func check(_ condition: Bool, _ message: String, line: UInt = #line) {
        if !condition { failures.append("line \(line): \(message)") }
    }

    static func run() {
        failures = []
        defer { TestSupport.expect(failures.isEmpty, "\(failures.count) round-one failures:\n" + failures.joined(separator: "\n")) }
        wholeSentences()
        messagesKeepTheirTime()
        writeDownAndTyping()
        trailingFiller()
        hesitations()
        interjections()
        appMatching()
        stopListening()
        windowTargets()
        videoSites()
        findInPage()
        localhost()
        siteSearch()
        keyCombos()
        macroStop()
        catalog()
        macroCaps()
    }

    /// Commas and "and" no longer cut schedules, triggers, macros and Claude prompts.
    private static func wholeSentences() {
        eq(parser.parse("Rio, when I plug in my monitor, open Chrome."), a(.addTrigger(command: "open Chrome", trigger: "display")))
        eq(parser.parse("Rio, every weekday at 9 AM, open Zoom."), a(.scheduleCommand(command: "open Zoom", when: "every weekday at 9 am")))
        eq(parser.parse("Rio, at 5 PM, mute."), a(.scheduleCommand(command: "mute", when: "at 5 pm")))
        eq(parser.parse("Rio, in 10 minutes, lock the screen."), a(.scheduleCommand(command: "lock the screen", when: "in 10 minutes")))
        eq(parser.parse("Rio, whenever I join the Hala Office wifi, open Slack."),
                 a(.addTrigger(command: "open Slack", trigger: "wifi:Hala Office")))
        eq(parser.parse("every weekday at 9am open Warp and VS Code"),
                 a(.scheduleCommand(command: "open Warp and VS Code", when: "every weekday at 9am")))
        eq(parser.parse("when I connect my monitor, open Chrome and Warp"),
                 a(.addTrigger(command: "open Chrome and Warp", trigger: "display")))
        eq(parser.parse("Rio, watch me and call it morning"), a(.recordMacro(name: "morning")))
        eq(parser.parse("Rio, tell Claude to run the tests and fix whatever breaks."),
                 a(.claudeCode(.send("run the tests and fix whatever breaks"))))
        eq(parser.parse("tell Claude to add a loading spinner, and then commit"),
                 a(.claudeCode(.send("add a loading spinner, and then commit"))))
        eq(parser.parse("Rio, tell cloud to run the tests"), a(.claudeCode(.send("run the tests"))))
        // Ordinary compound commands still split.
        eq(parser.parse("open Chrome and Spotify"), a(.openApp(name: gc), .openApp(name: "Spotify")))
        eq(parser.parse("mute and open spotify"), a(.volume(.mute), .openApp(name: "Spotify")))
    }

    /// A message that ends with a time is sent now, with the time words kept.
    private static func messagesKeepTheirTime() {
        for text in ["Rio text my mom that I'm on my way and I'll be there in ten minutes", "Rio text Sarah I'll be home in 20 minutes",
                     "Rio message dad I'll call you in an hour", "Rio text my mom that I love her every day"] {
            if case .actions(let list) = parser.parse(text), list.contains(where: {
                if case .scheduleCommand = $0 { return true }
                return false
            }) {
                check(false, "a message was scheduled: \(text)")
            }
        }
        eq(parser.parse("Rio tell Claude to check back in ten minutes"), a(.claudeCode(.send("check back in ten minutes"))))
        // A leading time or "schedule" still schedules a message.
        eq(parser.parse("in 10 minutes, text mom I'm on my way"),
                 a(.scheduleCommand(command: "text mom I'm on my way", when: "in 10 minutes")))
        eq(parser.parse("schedule text mom good morning every day at 8 am"),
                 a(.scheduleCommand(command: "text mom good morning", when: "every day at 8 am")))
        eq(parser.parse("open Safari in 10 minutes"), a(.scheduleCommand(command: "open Safari", when: "in 10 minutes")))
    }

    private static func writeDownAndTyping() {
        eq(parser.parse("Rio, write down quiz on Friday"), a(.addNote(text: "Quiz on Friday")))
        eq(parser.parse("write down buy milk and eggs"), a(.addNote(text: "Buy milk and eggs")))
        eq(parser.parse("Rio, type git status and press enter."), a(.typeText("git status"), key("return")))
        eq(parser.parse("type git status then press enter"), a(.typeText("git status"), key("return")))
        eq(parser.parse("type ls, then hit return"), a(.typeText("ls"), key("return")))
        eq(parser.parse("open Warp and type git status and press enter"),
                 a(.openApp(name: "Warp"), .typeText("git status"), key("return")))
        eq(parser.parse("write that I'm out of office until Monday"), a(.typeText("I'm out of office until Monday")))
        eq(parser.parse("type I told him to press enter"), a(.typeText("I told him to press enter")))
        check(isUnknown(parser.parse("write that down")), "write that down is not dictation")
        eq(parser.parse("type hello and goodbye"), a(.typeText("hello and goodbye")))
    }

    private static func trailingFiller() {
        eq(parser.parse("Rio play spider man"), a(.playMusic(query: "spider man")))
        eq(parser.parse("play the song candy man"), a(.playMusic(query: "candy man")))
        eq(parser.parse("what's the weather right now"), a(.weather(place: nil)))
        eq(parser.parse("what's the weather like right now"), a(.weather(place: nil)))
        eq(parser.analyze("what's 2 hours and 45 minutes from now").resolverText, "what's 2 hours and 45 minutes from now")
        eq(parser.analyze("remind me to call mom an hour from now").resolverText, "remind me to call mom an hour from now")
        eq(parser.parse("open Chrome now"), a(.openApp(name: gc)))
        eq(parser.parse("open Chrome, man"), a(.openApp(name: gc)))
        eq(parser.parse("open Chrome right now"), a(.openApp(name: gc)))
    }

    private static func hesitations() {
        eq(parser.parse("Rio, uh, open, um, Chrome"), a(.openApp(name: gc)))
        eq(parser.parse("Rio, uh, open, um, Spotify"), a(.openApp(name: "Spotify")))
        eq(parser.parse("Rio, tell Claude, um, to add a loading spinner"), a(.claudeCode(.send("add a loading spinner"))))
        eq(RioActionParser.stripEnvelope("Rio, um, can you, uh, set a timer for 10 minutes"), "set a timer for 10 minutes")
        eq(RioActionParser.stripEnvelope("open the umbrella app"), "open the umbrella app")
        // A message body keeps its words.
        eq(RioActionParser.stripEnvelope("text Ali um I'm late"), "text Ali um I'm late")
    }

    private static func interjections() {
        for text in ["Rio, yalla open chrome", "Rio, habibi open chrome", "Rio, like, open Chrome", "Rio, can you like open Chrome",
                     "Rio yalla open Chrome", "Rio, actually, open Chrome.", "Rio, sorry, open Chrome.", "Rio open Chrome yalla",
                     "Rio open Chrome inshallah", "Rio, never mind, open Chrome.", "oh open chrome", "wallah, open chrome"] {
            eq(parser.parse(text), a(.openApp(name: gc)), text)
        }
        eq(parser.parse("Rio, wait, pause the music."), a(.media(.pause)))
        eq(parser.parse("Rio, oops, undo that."), parser.parse("undo that"))
        eq(parser.parse("Rio, never mind, put it back"), parser.parse("put it back"))
        eq(RioActionParser.stripEnvelope("never mind"), "never mind")
        eq(RioActionParser.stripEnvelope("wait"), "wait")
        eq(RioActionParser.stripEnvelope("right click the Save button"), "right click the Save button")
        eq(RioActionParser.stripEnvelope("like this photo"), "like this photo")
        eq(RioActionParser.stripEnvelope("shoof what's due tomorrow"), "what's due tomorrow")
        eq(RioActionParser.stripEnvelope("Rio, so basically I need a timer for 25 minutes"), "I need a timer for 25 minutes")
        eq(RioActionParser.stripEnvelope("Rio, inshallah remind me to pray Maghrib at 5"), "remind me to pray Maghrib at 5")
        eq(RioActionParser.stripEnvelope("Rio, wallah I need to focus"), "I need to focus")
        eq(parser.parse("shoof what's due tomorrow"), parser.parse("what's due tomorrow"))
        eq(RioActionParser.stripTrailingFiller("when did I say yalla"), "when did I say yalla")
        let whatsApp = apps + [InstalledApp(name: "WhatsApp", bundleIdentifier: "test.whatsapp", url: URL(fileURLWithPath: "/Applications/WhatsApp.app"))]
        eq(RioActionParser(installedApps: whatsApp).parse("Rio open el WhatsApp"), a(.openApp(name: "WhatsApp")))
        eq(parser.parse("open el youtube"), a(u("https://www.youtube.com")))
    }

    private static func appMatching() {
        check(isUnknown(parser.parse("Rio, run the tests.")), "run the tests must not open Messages")
        check(isUnknown(parser.parse("open the tests")), "open the tests must not open Messages")
        check(isUnknown(parser.parse("start the tests")), "start the tests must not open Messages")
        eq(AppNameMatcher.match(for: "tests", in: apps)?.app.name, nil, "aliases need an exact hit")
        eq(AppNameMatcher.match(for: "texts", in: apps)?.app.name, "Messages", "the alias itself still works")
        // A fuzzy match is a guess the resolver sees first.
        let slick = parser.analyze("open slick")
        eq(slick.parse, a(.openApp(name: "Slack")))
        eq(slick.isConfident, false, "fuzzy is never confident")
        eq(parser.analyze("open Slack").isConfident, true)
        eq(parser.parse("open the Zen browser"), a(.openApp(name: "Zen")))
        eq(parser.parse("open Safari browser"), a(.openApp(name: "Safari")))
        let incognito = parser.analyze("open Chrome in incognito")
        eq(incognito.parse, a(.openApp(name: gc)))
        eq(incognito.isConfident, false, "the private mode is the resolver's call")
        eq(parser.parse("open R studio"), a(.openApp(name: "RStudio")))
        eq(parser.parse("open the simulator"), a(.openApp(name: "Simulator")))
        eq(AppNameMatcher.camelParts("TextEdit"), ["text", "edit"])
        eq(AppNameMatcher.camelParts("GitHub Desktop"), ["git", "hub", "desktop"])
        let edit = parser.analyze("maximize edit")
        eq(edit.parse, a(w("TextEdit", .maximize)))
        eq(edit.isConfident, false, "a name part is only a guess")
    }

    private static func stopListening() {
        for text in ["Rio thats all for now", "Rio ok thats all for now", "Rio thanks that's all", "Rio goodbye", "Rio bye",
                     "Rio goodnight", "good night", "that'll be all", "that's all for now, thanks", "stop listening"] {
            eq(parser.parse(text), a(.stopListening), text)
        }
    }

    private static func windowTargets() {
        eq(parser.parse("Rio, open Chrome and put it on the left."), a(.openApp(name: gc), w(gc, .leftHalf)))
        eq(parser.parse("open warp and maximize it"), a(.openApp(name: "Warp"), w("Warp", .maximize)))
        eq(parser.parse("open Safari and make it full screen"), a(.openApp(name: "Safari"), w("Safari", .maximize)))
        eq(parser.parse("put it on the left"), a(w(nil, .leftHalf)), "no app before: the front window")
        eq(parser.parse("open Chrome and set volume to 30 and maximize it"),
                 a(.openApp(name: gc), .volume(.set(30)), w(nil, .maximize)))
    }

    private static func videoSites() {
        eq(parser.parse("Rio, open youtube and play 3blue1brown"), a(u("https://www.youtube.com/results?search_query=3blue1brown")))
        eq(parser.parse("play lofi on youtube"), a(u("https://www.youtube.com/results?search_query=lofi")))
        eq(parser.parse("Rio, go to netflix and play stranger things"), a(u("https://www.netflix.com/search?q=stranger%20things")))
        check(isUnknown(parser.parse("play the video on youtube")), "a bare video stays with the resolver")
    }

    private static func findInPage() {
        eq(parser.parse("Rio, search this page for budget."), a(.browser(.find), .typeText("budget")))
        eq(parser.parse("Rio, find budget on this page."), a(.browser(.find), .typeText("budget")))
        eq(parser.parse("find on page budget"), a(.browser(.find), .typeText("budget")))
        eq(parser.parse("find useEffect on this page"), a(.browser(.find), .typeText("useEffect")))
    }

    private static func localhost() {
        eq(parser.parse("go to localhost 3000"), a(u("http://localhost:3000")))
        eq(parser.parse("open localhost:8081"), a(u("http://localhost:8081")))
        eq(parser.parse("open 127.0.0.1:8080"), a(u("http://127.0.0.1:8080")))
        eq(parser.parse("open Chrome and go to localhost 3000"), a(.openApp(name: gc), u("http://localhost:3000")))
        eq(RioWebURLs.localURL(fromSpoken: "localhost 3000/api"), URL(string: "http://localhost:3000/api"))
        eq(RioWebURLs.localURL(fromSpoken: "localhost 70000"), nil, "port out of range")
        eq(RioWebURLs.localURL(fromSpoken: "localhost 0"), nil, "port 0")
        eq(RioWebURLs.localURL(fromSpoken: "localhost"), nil, "no port")
        eq(RioWebURLs.localURL(fromSpoken: "evil.com 3000"), nil, "only local hosts")
    }

    private static func siteSearch() {
        eq(parser.parse("Rio, search Stack Overflow for swift async let error."),
                 a(u("https://stackoverflow.com/search?q=swift%20async%20let%20error")))
        eq(parser.parse("search GitHub for expo router examples"), a(u("https://github.com/search?q=expo%20router%20examples")))
        eq(parser.parse("search reddit for mechanical keyboards"), a(.webSearch(query: "site:reddit.com mechanical keyboards")))
        eq(parser.parse("Rio look up the weather in Dubai"), a(.weather(place: "Dubai")))
        eq(parser.parse("search the web for rust"), a(.webSearch(query: "rust")))
        eq(parser.parse("search google for rust"), a(.webSearch(query: "rust")))
    }

    private static func keyCombos() {
        eq(parser.parse("Rio, press Cmd+Tab."), a(key("tab", cmd: true)))
        eq(parser.parse("press Command+Shift+T."), a(key("t", cmd: true, shift: true)))
        eq(parser.parse("Rio, press command plus."), a(key("equal", cmd: true)))
        eq(parser.parse("press command plus shift plus t"), a(key("t", cmd: true, shift: true)))
        eq(parser.parse("press enter twice"), a(key("return"), key("return")))
        eq(parser.parse("press the down arrow three times"), a(key("down"), key("down"), key("down")))
        eq(parser.parse("press command A then delete"), a(key("a", cmd: true), key("delete")))
        check(isUnknown(parser.parse("press enter fifty times")), "repeats are capped")
    }

    private static func macroStop() {
        for text in ["Rio, stop recording.", "I'm done", "OK done", "that's it", "done"] {
            eq(recording.parse(text), a(.stopRecordingMacro), text)
            eq(parser.parse(text) == a(.stopRecordingMacro), false, "not recording: \(text)")
        }
        eq(recording.parse("stop recording the macro"), a(.stopRecordingMacro))
        eq(recording.parse("open Chrome"), a(.openApp(name: gc)), "other commands still work while recording")
    }

    private static func catalog() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rio-catalog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Foo.app", "RStudio-2023.09.0-463/RStudio.app", "Setapp/Bar.app", "Utilities/Skip.app", "Deep/Inner/Nope.app"] {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent(path, isDirectory: true), withIntermediateDirectories: true)
        }
        let names = Set(InstalledAppCatalog.appBundles(in: root, scanFolders: true).map { $0.deletingPathExtension().lastPathComponent })
        eq(names, ["Foo", "RStudio", "Bar"], "one level into plain folders")
        let flat = Set(InstalledAppCatalog.appBundles(in: root, scanFolders: false).map { $0.deletingPathExtension().lastPathComponent })
        eq(flat, ["Foo"])
        check(InstalledAppCatalog.searchDirectories().contains { $0.path.hasSuffix("Xcode.app/Contents/Developer/Applications") },
                           "Simulator lives inside Xcode")
    }

    private static func macroCaps() {
        let keystrokes = (0..<2_000).map { _ in RioAction.typeText("x") }
        var steps: [RioAction] = []
        for stroke in keystrokes { steps = RioMacroMapper.compact(steps + [stroke]) }
        eq(RioMacroMapper.typedCharacterCount(steps), RioMacroMapper.maxTypedCharacters, "typing is capped per macro")
        for step in steps {
            if case .typeText(let text) = step {
                check(text.count <= RioMacroMapper.maxTypedCharactersPerStep, "typing is capped per step")
            }
        }
        eq(RioMacroMapper.compact(steps), steps, "compact is stable")
        check(RioMacroMapper.maxRecordingSeconds <= 10 * 60, "a forgotten recording stops listening")
    }
}
