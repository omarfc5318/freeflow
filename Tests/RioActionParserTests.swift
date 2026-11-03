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
            ("open a new tab", unk("open a new tab")),
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
            ("close this window", unk("close this window")),
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
            ("switch to zorblax", a(sw("zorblax"))),
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
            ("open Chrome and put it on the left", a(o(gc), w(nil, .leftHalf))),
            ("open Chrome and set volume to 30", a(o(gc), .volume(.set(30)))),
            ("mute and open spotify", a(.volume(.mute), o("Spotify"))),
            ("open chrome and search for cats", a(o(gc), .webSearch(query: "cats"))),
            ("search for cats and dogs", a(.webSearch(query: "cats and dogs"))),
            ("open chrome then volume up then play", a(o(gc), .volume(.up), .media(.playPause))),

            // Search
            ("search for pizza near me", a(.webSearch(query: "pizza near me"))),
            ("Search for the best pizza in Doha.", a(.webSearch(query: "the best pizza in Doha"))),
            ("google swift concurrency", a(.webSearch(query: "swift concurrency"))),
            ("Google how to tie a tie", a(.webSearch(query: "how to tie a tie"))),
            ("look up the weather in Doha", a(.webSearch(query: "the weather in Doha"))),
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
            ("play", a(.media(.playPause))),
            ("Pause.", a(.media(.playPause))),
            ("pause the music", a(.media(.playPause))),
            ("play music", a(.media(.playPause))),
            ("resume", a(.media(.playPause))),
            ("next song", a(.media(.next))),
            ("skip", a(.media(.next))),
            ("skip this song", a(.media(.next))),
            ("next track", a(.media(.next))),
            ("play the next song", a(.media(.next))),
            ("previous song", a(.media(.previous))),
            ("go back", a(.media(.previous))),
            ("play taylor swift", unk("play taylor swift")),
            ("stop the music", unk("stop the music")),

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
            ("what's the weather", unk("what's the weather")),
            ("tell me a joke", unk("tell me a joke")),
            ("chrome", unk("chrome")),
            ("hello there", unk("hello there")),
            ("send a message to Sarah saying hi", unk("send a message to Sarah saying hi")),
            ("remind me to call mom", unk("remind me to call mom")),
            ("summarize this", unk("summarize this")),
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
    }

    /// Parser output never contains the smart-only actions.
    private static func testNoActionIsOutsideTheClosedSet(_ parser: RioActionParser) {
        for (input, _) in cases {
            guard case .actions(let list) = parser.parse(input) else { continue }
            for action in list {
                switch action {
                case .sendMessage, .createReminder, .selectionTask:
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
