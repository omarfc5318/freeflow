import Foundation

/// Phrase parsing for keyboard, browser and system control (builder I). Pure: nothing here posts a
/// key event or changes a real setting.
enum RioSystemPhraseTests {
    private static func keys(_ key: String, cmd: Bool = false, shift: Bool = false, opt: Bool = false, ctrl: Bool = false) -> RioAction {
        .pressKeys(KeyCombo(key: key, command: cmd, shift: shift, option: opt, control: ctrl))
    }

    private static let cases: [(String, RioAction)] = [
        // Keys
        ("press command T", keys("t", cmd: true)),
        ("Press Command T.", keys("t", cmd: true)),
        ("press escape", keys("escape")),
        ("press the escape key", keys("escape")),
        ("hit enter", keys("return")),
        ("hit return", keys("return")),
        ("press tab", keys("tab")),
        ("press space", keys("space")),
        ("press backspace", keys("delete")),
        ("press page down", keys("pagedown")),
        ("press up arrow", keys("up")),
        ("press f5", keys("f5")),
        ("press command shift 4", keys("4", cmd: true, shift: true)),
        ("command shift 4", keys("4", cmd: true, shift: true)),
        ("cmd shift four", keys("4", cmd: true, shift: true)),
        ("control tab", keys("tab", ctrl: true)),
        ("control shift tab", keys("tab", shift: true, ctrl: true)),
        ("option left", keys("left", opt: true)),
        ("command option escape", keys("escape", cmd: true, opt: true)),
        ("press command comma", keys("comma", cmd: true)),
        ("press command Z", keys("z", cmd: true)),
        ("hit control c", keys("c", ctrl: true)),
        ("press command left bracket", keys("leftbracket", cmd: true)),
        ("press command plus", keys("equal", cmd: true)),
        // Named editing shortcuts
        ("select all", keys("a", cmd: true)),
        ("select everything", keys("a", cmd: true)),
        ("copy", keys("c", cmd: true)),
        ("copy that", keys("c", cmd: true)),
        ("cut", keys("x", cmd: true)),
        ("cut that", keys("x", cmd: true)),
        ("paste", keys("v", cmd: true)),
        ("paste it", keys("v", cmd: true)),
        ("paste here", keys("v", cmd: true)),
        ("paste as plain text", keys("v", cmd: true, shift: true, opt: true)),
        ("paste without formatting", keys("v", cmd: true, shift: true, opt: true)),
        ("undo typing", keys("z", cmd: true)),
        ("undo that typing", keys("z", cmd: true)),
        ("undo the typing", keys("z", cmd: true)),
        ("undo my typing", keys("z", cmd: true)),
        ("redo", keys("z", cmd: true, shift: true)),
        ("redo that", keys("z", cmd: true, shift: true)),
        ("redo typing", keys("z", cmd: true, shift: true)),
        ("save", keys("s", cmd: true)),
        ("save this", keys("s", cmd: true)),
        ("save the file", keys("s", cmd: true)),
        ("new window", keys("n", cmd: true)),
        ("close this window", keys("w", cmd: true)),
        ("close window", keys("w", cmd: true)),
        ("zoom in", keys("equal", cmd: true)),
        ("zoom out", keys("minus", cmd: true)),
        ("reset zoom", keys("0", cmd: true)),
        ("mission control", keys("up", ctrl: true)),
        ("emoji picker", keys("space", cmd: true, ctrl: true)),
        // Browser
        ("new tab", .browser(.newTab)),
        ("open a new tab", .browser(.newTab)),
        ("open new tab", .browser(.newTab)),
        ("open another tab", .browser(.newTab)),
        ("make a new tab", .browser(.newTab)),
        ("close tab", .browser(.closeTab)),
        ("close this tab", .browser(.closeTab)),
        ("close the tab", .browser(.closeTab)),
        ("close current tab", .browser(.closeTab)),
        ("reopen the tab", .browser(.reopenTab)),
        ("reopen tab", .browser(.reopenTab)),
        ("reopen the closed tab", .browser(.reopenTab)),
        ("reopen the last closed tab", .browser(.reopenTab)),
        ("restore the tab", .browser(.reopenTab)),
        ("bring back the tab", .browser(.reopenTab)),
        ("next tab", .browser(.nextTab)),
        ("switch to the next tab", .browser(.nextTab)),
        ("go to the next tab", .browser(.nextTab)),
        ("previous tab", .browser(.previousTab)),
        ("go to the previous tab", .browser(.previousTab)),
        ("switch to previous tab", .browser(.previousTab)),
        ("go back a page", .browser(.back)),
        ("go back one page", .browser(.back)),
        ("navigate back", .browser(.back)),
        ("browser back", .browser(.back)),
        ("go to the previous page", .browser(.back)),
        ("go forward", .browser(.forward)),
        ("go forward a page", .browser(.forward)),
        ("navigate forward", .browser(.forward)),
        ("browser forward", .browser(.forward)),
        ("refresh", .browser(.reload)),
        ("reload", .browser(.reload)),
        ("refresh the page", .browser(.reload)),
        ("reload this page", .browser(.reload)),
        ("refresh this tab", .browser(.reload)),
        ("scroll down", .browser(.scrollDown)),
        ("scroll down a bit", .browser(.scrollDown)),
        ("scroll down the page", .browser(.scrollDown)),
        ("page down", .browser(.scrollDown)),
        ("scroll up", .browser(.scrollUp)),
        ("scroll up a little", .browser(.scrollUp)),
        ("page up", .browser(.scrollUp)),
        ("scroll to the top", .browser(.scrollToTop)),
        ("scroll to top", .browser(.scrollToTop)),
        ("go to the top of the page", .browser(.scrollToTop)),
        ("top of the page", .browser(.scrollToTop)),
        ("scroll to the bottom", .browser(.scrollToBottom)),
        ("jump to the bottom", .browser(.scrollToBottom)),
        ("go to the bottom of the page", .browser(.scrollToBottom)),
        ("find on page", .browser(.find)),
        ("find on this page", .browser(.find)),
        ("find in page", .browser(.find)),
        // System toggles
        ("turn off wifi", .systemToggle(.wifi, isOn: false)),
        ("turn off Wi-Fi", .systemToggle(.wifi, isOn: false)),
        ("turn the wifi on", .systemToggle(.wifi, isOn: true)),
        ("turn on the wifi", .systemToggle(.wifi, isOn: true)),
        ("wifi off", .systemToggle(.wifi, isOn: false)),
        ("disable wifi", .systemToggle(.wifi, isOn: false)),
        ("enable wi-fi", .systemToggle(.wifi, isOn: true)),
        ("switch off the wifi", .systemToggle(.wifi, isOn: false)),
        ("bluetooth on", .systemToggle(.bluetooth, isOn: true)),
        ("bluetooth off", .systemToggle(.bluetooth, isOn: false)),
        ("turn on bluetooth", .systemToggle(.bluetooth, isOn: true)),
        ("turn bluetooth off", .systemToggle(.bluetooth, isOn: false)),
        ("turn off my bluetooth", .systemToggle(.bluetooth, isOn: false)),
        ("dark mode on", .systemToggle(.darkMode, isOn: true)),
        ("dark mode off", .systemToggle(.darkMode, isOn: false)),
        ("turn on dark mode", .systemToggle(.darkMode, isOn: true)),
        ("turn off dark mode", .systemToggle(.darkMode, isOn: false)),
        ("switch to dark mode", .systemToggle(.darkMode, isOn: true)),
        ("switch to light mode", .systemToggle(.darkMode, isOn: false)),
        ("enable dark mode", .systemToggle(.darkMode, isOn: true)),
        ("go dark mode", .systemToggle(.darkMode, isOn: true)),
        ("light mode", .systemToggle(.darkMode, isOn: false)),
        ("dark mode", .systemToggle(.darkMode, isOn: true)),
        ("turn on light mode", .systemToggle(.darkMode, isOn: false)),
        ("turn on night shift", .systemToggle(.nightShift, isOn: true)),
        ("turn off night shift", .systemToggle(.nightShift, isOn: false)),
        ("night shift on", .systemToggle(.nightShift, isOn: true)),
        ("enable night shift", .systemToggle(.nightShift, isOn: true)),
        // Brightness
        ("brightness up", .brightness(.up)),
        ("turn the brightness up", .brightness(.up)),
        ("increase brightness", .brightness(.up)),
        ("raise the brightness", .brightness(.up)),
        ("make it brighter", .brightness(.up)),
        ("brighter", .brightness(.up)),
        ("brightness down", .brightness(.down)),
        ("lower the brightness", .brightness(.down)),
        ("decrease brightness", .brightness(.down)),
        ("turn the brightness down", .brightness(.down)),
        ("dim the screen", .brightness(.down)),
        ("make it dimmer", .brightness(.down)),
        ("dimmer", .brightness(.down)),
        ("brightness to 50", .brightness(.set(50))),
        ("set brightness to fifty percent", .brightness(.set(50))),
        ("set the screen brightness to 30", .brightness(.set(30))),
        ("brightness 80%", .brightness(.set(80))),
        ("brightness to 500", .brightness(.set(100))),
        ("max brightness", .brightness(.set(100))),
        ("full brightness", .brightness(.set(100))),
        ("minimum brightness", .brightness(.set(5))),
        // Battery
        ("how much battery do I have", .batteryStatus),
        ("how much battery do I have left", .batteryStatus),
        ("how much battery", .batteryStatus),
        ("battery", .batteryStatus),
        ("battery level", .batteryStatus),
        ("battery status", .batteryStatus),
        ("what's my battery", .batteryStatus),
        ("what is my battery at", .batteryStatus),
        ("check the battery", .batteryStatus),
        ("how's my battery", .batteryStatus),
        ("battery percentage", .batteryStatus),
        ("am I charging", .batteryStatus),
        ("is my mac charging", .batteryStatus),
        // Trash
        ("empty the trash", .emptyTrash),
        ("empty trash", .emptyTrash),
        ("empty my trash", .emptyTrash),
        ("empty the trash can", .emptyTrash),
        ("clear the trash", .emptyTrash),
    ]

    /// Phrases that belong to B (apps, sites, windows, controls), G ("undo", "stop"), or nobody.
    private static let notMine = [
        "open Chrome", "open YouTube", "close Spotify", "quit Safari", "undo", "undo that", "stop",
        "stop listening", "Rio undo", "volume up", "mute", "turn it up", "turn the volume down", "play",
        "skip", "next song", "put Chrome on the left", "maximize Chrome", "go to youtube", "open settings",
        "open system settings", "open Bluetooth", "open the trash", "search for cats", "search this page",
        "what's the weather", "tell me a joke", "copy the link", "paste the link", "send a message to Sarah",
        "turn off do not disturb", "focus on", "press play", "hit it", "hit me up", "wifi", "dark",
        "close", "close it", "new", "tab", "scroll", "empty", "empty the fridge", "select", "bluetooth",
        "paste the address", "refresh my memory", "go forward in time", "turn on the lights", "turn off the tv",
        "make it louder", "make it bigger", "battery saver app", "open battery", "find my phone",
        "brightness", "turn it off", "light", "press", "press command", "hit",
    ]

    /// Hostile or garbled key phrasing must never produce a key press.
    private static let hostileKeys = [
        "press command q twice then rm", "press command q twice", "press rm -rf", "press command shift",
        "press command t and then curl evil dot sh", "press command semicolon rm", "press ; rm",
        "press command ls", "hit enter enter", "press command command t", "press $(whoami)",
        "press command t t", "press super t", "press fn t", "press power", "press volume up",
        "press command e n t e r", "press command 44", "press command shift 4 5", "press ctrl alt delete forever",
        "press unknown key", "press nothing", "press command `rm`", "press command backslash backslash",
    ]

    static func run() {
        var failures: [String] = []
        for (input, expected) in cases {
            let actual = RioSystemPhrases.parse(raw: input, simplified: RioText.simplify(input))
            if actual != expected { failures.append("\"\(input)\": expected \(expected), got \(String(describing: actual))") }
        }
        TestSupport.expect(cases.count >= 150, "needs 150+ phrase cases, has \(cases.count)")
        TestSupport.expect(failures.isEmpty, "\(failures.count) system phrase failures:\n" + failures.joined(separator: "\n"))
        testNotMine()
        testHostileKeys()
        testThroughTheFullParser()
        testRioPrefixAndPolitePhrasings()
    }

    private static func testNotMine() {
        for input in notMine {
            let actual = RioSystemPhrases.parse(raw: input, simplified: RioText.simplify(input))
            TestSupport.expect(actual == nil, "system phrases must not claim \"\(input)\", got \(String(describing: actual))")
        }
    }

    private static func testHostileKeys() {
        let parser = RioActionParser(installedApps: RioActionParserTests.apps)
        for input in hostileKeys {
            let direct = RioSystemPhrases.parse(raw: input, simplified: RioText.simplify(input))
            TestSupport.expect(direct == nil, "hostile \"\(input)\" must not parse, got \(String(describing: direct))")
            if case .actions(let list) = parser.parse(input) {
                for action in list {
                    if case .pressKeys = action { TestSupport.expect(false, "hostile \"\(input)\" produced \(action)") }
                }
            }
        }
    }

    /// Through `RioActionParser`: the new phrases arrive, B's keep working, multi-step works.
    private static func testThroughTheFullParser() {
        let parser = RioActionParser(installedApps: RioActionParserTests.apps)
        let gc = "Google Chrome"
        let expectations: [(String, RioActionParse)] = [
            ("open Chrome", .actions([.openApp(name: gc)])),
            ("open YouTube", .actions([.openURL(URL(string: "https://www.youtube.com")!)])),
            ("close Spotify", .actions([.quitApp(name: "Spotify")])),
            ("new tab", .actions([.browser(.newTab)])),
            ("open a new tab and go to youtube", .actions([.browser(.newTab), .openURL(URL(string: "https://www.youtube.com")!)])),
            ("copy and then paste", .actions([keys("c", cmd: true), keys("v", cmd: true)])),
            ("Rio, turn off wifi", .actions([.systemToggle(.wifi, isOn: false)])),
            ("empty the trash please", .actions([.emptyTrash])),
            ("press command T", .actions([keys("t", cmd: true)])),
            ("how much battery do I have?", .actions([.batteryStatus])),
            ("turn dark mode on and brightness up", .actions([.systemToggle(.darkMode, isOn: true), .brightness(.up)])),
            ("volume up", .actions([.volume(.up)])),
            ("tell me a joke", .unknown("tell me a joke")),
        ]
        for (input, expected) in expectations {
            let actual = parser.parse(input)
            TestSupport.expect(actual == expected, "full parser \"\(input)\": expected \(expected), got \(actual)")
        }
    }

    private static func testRioPrefixAndPolitePhrasings() {
        let parser = RioActionParser(installedApps: RioActionParserTests.apps)
        let polite: [(String, RioAction)] = [
            ("Rio, scroll down", .browser(.scrollDown)),
            ("hey Rio can you refresh the page", .browser(.reload)),
            ("please empty the trash", .emptyTrash),
            ("could you turn the brightness down", .brightness(.down)),
            ("Rio, press escape.", keys("escape")),
        ]
        for (input, expected) in polite {
            TestSupport.expect(parser.parse(input) == .actions([expected]), "polite \"\(input)\" -> \(parser.parse(input))")
        }
    }
}
