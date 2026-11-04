import Foundation

/// Round two: sentence periods, greedy clauses that end at "and then", self-corrections, a
/// second "Rio", stop-listening phrasings, Canvas in a chain, "it" binding, Claude without "to",
/// spoken symbols. Synthetic installed apps only; nothing runs.
enum RioParserClauseTests {
    private static let apps: [InstalledApp] = [
        "Google Chrome", "Warp", "Safari", "Spotify", "Notes", "Notion", "Xcode", "zoom.us", "R", "Messages",
    ].map { InstalledApp(name: $0, bundleIdentifier: "test.\(RioText.compact($0))", url: URL(fileURLWithPath: "/Applications/\($0).app")) }

    private static let parser = RioActionParser(installedApps: apps, isRecordingMacro: false)
    private static let recording = RioActionParser(installedApps: apps, isRecordingMacro: true)
    private static let gc = "Google Chrome"
    nonisolated(unsafe) private static var failures: [String] = []

    private static func o(_ n: String) -> RioAction { .openApp(name: n) }
    private static func u(_ s: String) -> RioAction { .openURL(URL(string: s)!) }
    private static func w(_ app: String?, _ p: WindowPlacement) -> RioAction { .window(WindowCommand(appName: app, placement: p)) }
    private static func a(_ actions: RioAction...) -> RioActionParse { .actions(actions) }

    private static func eq(_ text: String, _ expected: RioActionParse, line: UInt = #line) {
        let actual = parser.parse(text)
        if actual != expected { failures.append("line \(line) \"\(text)\": expected \(expected), got \(actual)") }
    }

    private static func notLocal(_ text: String, line: UInt = #line) {
        let analysis = parser.analyze(text)
        if case .actions = analysis.parse, analysis.isConfident {
            failures.append("line \(line) \"\(text)\": must reach the resolver, got \(analysis.parse)")
        }
    }

    private static func check(_ condition: Bool, _ message: String, line: UInt = #line) {
        if !condition { failures.append("line \(line): \(message)") }
    }

    static func run() {
        failures = []
        let savedBase = RioCanvasConfig.configuredText
        RioCanvasConfig.configuredText = { "" }
        defer { RioCanvasConfig.configuredText = savedBase }
        sentencePeriods()
        greedyClausesEnd()
        emailIsNotAFile()
        corrections()
        interiorName()
        stopListening()
        canvasInChains()
        documentTargets()
        pronounBinding()
        claudeWithoutTo()
        bareDomainsAndSides()
        littleBit()
        envelopeAndSymbols()
        TestSupport.expect(failures.isEmpty, "\(failures.count) clause failures:\n" + failures.joined(separator: "\n"))
    }

    private static func sentencePeriods() {
        eq("Open Chrome. Quit Xcode.", a(o(gc), .quitApp(name: "Xcode")))
        eq("Mute. Lock the screen.", a(.volume(.mute), .lockScreen))
        eq("Open Chrome. Open Chrome.", a(o(gc), o(gc)))
        eq("open github.com", a(u("https://github.com")))
        eq("open hala discover dot com", a(u("https://haladiscover.com")))
        eq("type hello world. This is a test", a(.typeText("hello world. This is a test")))
        eq("text Dr. Kim saying hi", a(.sendMessage(to: "Dr. Kim", body: "hi")))
        eq("open Chrome. Thanks Rio.", a(o(gc)))
        check(RioActionParser.splitClauses("set a reminder for 9 a.m. tomorrow to study").count == 1, "a.m. is not a sentence end")
        check(RioActionParser.splitClauses("set volume to 35.5").count == 1, "a decimal is not a sentence end")
    }

    private static func greedyClausesEnd() {
        notLocal("search for cats and open the first result")
        eq("search google for flights to doha and then open warp", a(.webSearch(query: "flights to doha"), o("Warp")))
        notLocal("search youtube for lofi and play the first one")
        eq("search youtube for lofi then put chrome on the left",
           a(u("https://www.youtube.com/results?search_query=lofi"), w(gc, .leftHalf)))
        eq("text ali saying hi and then open chrome", a(.sendMessage(to: "ali", body: "hi"), o(gc)))
        eq("reply saying sounds good and send it", a(.replyInConversation(body: "sounds good")))
        eq("reply saying that I'll be there at 3", a(.replyInConversation(body: "I'll be there at 3")))
        // Plain "and" inside a query or a body stays.
        eq("search for cats and dogs", a(.webSearch(query: "cats and dogs")))
        eq("text Ali saying I'm late and I'll call", a(.sendMessage(to: "Ali", body: "I'm late and I'll call")))
        eq("text ali saying never mind", a(.sendMessage(to: "ali", body: "never mind")))
    }

    private static func emailIsNotAFile() {
        notLocal("Rio can you open Chrome and then go to my Gmail and find the email from Professor Kim about the midterm and then reply saying that I'll be there at 3 and also set a reminder for tomorrow at 9 to study for it")
        check(RioFilesPhrases.parse(simplified: "find the email from Professor Kim about the midterm") == nil, "an email is not a file")
        check(RioFilesPhrases.parse(simplified: "find my messages from Ali") == nil, "messages are not files")
        check(RioFilesPhrases.parse(simplified: "find my midterm study guide") != nil, "a study guide is still a file")
    }

    private static func corrections() {
        eq("open Chrome... wait no, Safari", a(o("Safari")))
        eq("open chrome no I mean safari", a(o("Safari")))
        eq("Rio open Chrome sorry I mean Safari", a(o("Safari")))
        eq("open Chrome, actually Safari", a(o("Safari")))
        eq("Rio open Chrome... actually never mind", .empty)
        eq("open Chrome and Warp, never mind", .empty)
        eq("open Chrome comma Warp", a(o(gc), o("Warp")))
        check(parser.parse("never mind") != .empty, "a bare never mind still reaches undo")
        check(RioActionParser.splitClauses("remind me to actually study") == ["remind me to actually study"], "a bare actually is not a correction")
    }

    private static func interiorName() {
        eq("Rio open chrome Rio quit xcode", a(o(gc), .quitApp(name: "Xcode")))
        if case .actions(let steps) = parser.parse("Rio stop. Rio open Chrome.") {
            check(steps.count == 2 && steps.last == o(gc), "stop, then open Chrome: \(steps)")
        } else {
            check(false, "Rio stop. Rio open Chrome. is two commands")
        }
        eq("Rio open Chrome, Rio play some music", a(o(gc), .media(.play)))
        eq("Rio mute. Rio lock the screen.", a(.volume(.mute), .lockScreen))
        eq("Rio open Chrome and Rio open Warp", a(o(gc), o("Warp")))
        eq("Rio open Warp. Rio, put it on the left.", a(o("Warp"), w("Warp", .leftHalf)))
        check(RioActionParser.splitClauses("do this, Rio answer that") == ["do this", "answer that"], "the second Rio is a break")
        eq("text Rio saying hi", a(.sendMessage(to: "Rio", body: "hi")))
    }

    private static func stopListening() {
        for text in ["Rio stop listening. Thanks Rio.", "stop listening thanks rio", "stop listening to me", "stop conversation",
                     "mic off", "turn the mic off", "go away", "leave me alone", "quit listening", "we're done here",
                     "that's it for now", "okay that's it", "I'm done"] {
            eq(text, a(.stopListening))
            check(RioConversationCommands.isStopListening(text), "conversation mode stops on \"\(text)\"")
        }
        for text in ["exit", "sleep", "turn off"] {
            check(parser.parse(text) != a(.stopListening), "\"\(text)\" is ambiguous and stays out")
        }
        check(recording.parse("I'm done") == a(.stopRecordingMacro), "while recording, I'm done ends the recording")
        check(recording.parse("that's it") == a(.stopRecordingMacro), "while recording, that's it ends the recording")
        check(parser.parse("open Chrome and that's it") != a(o(gc), .stopListening), "that's it only ends a whole sentence")
    }

    private static func canvasInChains() {
        let canvas = u("https://canvas.ucdavis.edu")
        eq("open chrome and canvas", a(o(gc), canvas))
        eq("open canvas and chrome", a(canvas, o(gc)))
        eq("open canvas and youtube", a(canvas, u("https://www.youtube.com")))
        eq("open notion and canvas", a(o("Notion"), canvas))
        eq("open spotify and canvas", a(o("Spotify"), canvas))
        // Finding 27: the named browser is opened, then the link goes to it.
        eq("open canvas in chrome", a(o(gc), canvas))
        eq("open canvas in safari", a(o("Safari"), canvas))
        RioCanvasConfig.configuredText = { "canvas.example.edu" }
        eq("open chrome and canvas", a(o(gc), u("https://canvas.example.edu")))
        RioCanvasConfig.configuredText = { "" }
    }

    private static func documentTargets() {
        eq("open my MAT 108 notes", a(.openFile(query: "MAT 108 notes")))
        eq("open zoom and my MAT 108 notes", a(o("zoom.us"), .openFile(query: "MAT 108 notes")))
        eq("open my lecture notes for MAT 108", a(.openFile(query: "lecture notes for MAT 108")))
        eq("open notes", a(o("Notes")))
        eq("open my notes", a(o("Notes")))
    }

    private static func pronounBinding() {
        eq("open chrome and then quit it", a(o(gc), .quitApp(name: gc)))
        eq("open warp and hide it", a(o("Warp"), .hideApp(name: "Warp")))
        eq("open the r app and then quit it", a(o("R"), .quitApp(name: "R")))
        eq("move warp to the next screen and maximize it", a(w("Warp", .nextScreen), w("Warp", .maximize)))
        eq("maximize it and move it to the other monitor", a(w(nil, .maximize), w(nil, .nextScreen)))
        notLocal("quit it")
    }

    private static func claudeWithoutTo() {
        let tests = ClaudeCodeCommand.send("refactor the auth module and add tests")
        eq("Hey Rio, tell Claude: refactor the auth module and add tests.", a(.claudeCode(tests)))
        eq("Tell Claude, run the tests.", a(.claudeCode(.send("run the tests"))))
        eq("tell claude refactor the auth module and add tests", a(.claudeCode(tests)))
        eq("claude, add a dark mode toggle", a(.claudeCode(.send("add a dark mode toggle"))))
        eq("tell claude code in warp to run the linter", a(.claudeCode(.send("run the linter"))))
        eq("Rio tell the cloud to push the branch", a(.claudeCode(.send("push the branch"))))
        eq("Rio ask clawed what it's doing", a(.claudeCode(.status)))
        eq("ask Claude what it's doing", a(.claudeCode(.status)))
        // Never an approval from a send body, never a prompt that isn't words.
        notLocal("tell claude 1")
        notLocal("tell claude, /clear the history")
        check(parser.parse("Claude, yes") != a(.claudeCode(.send("yes"))), "a bare yes is not sent")
        notLocal("claude is great")
    }

    private static func bareDomainsAndSides() {
        eq("open chrome, new tab, github.com, then put it on the right",
           a(o(gc), .browser(.newTab), u("https://github.com"), w(nil, .rightHalf)))
        eq("chrome left warp right", a(w(gc, .leftHalf), w("Warp", .rightHalf)))
        eq("Warp right, Chrome left.", a(w(gc, .leftHalf), w("Warp", .rightHalf)))
        notLocal("left right")
    }

    private static func littleBit() {
        eq("Rio turn the volume down a little bit", a(.volume(.down)))
        eq("Rio could you please turn the volume down a little bit", a(.volume(.down)))
        eq("turn it up slightly", a(.volume(.up)))
    }

    private static func envelopeAndSymbols() {
        eq("so yeah Rio open Chrome", a(o(gc)))
        eq("yeah open Chrome", a(o(gc)))
        eq("type cd tilde slash hala", a(.typeText("cd ~/hala")))
        eq("type ls dash la", a(.typeText("ls -la")))
        eq("type git checkout feature slash login", a(.typeText("git checkout feature/login")))
        eq("type cd dot dot", a(.typeText("cd ..")))
        eq("type omar at example dot com", a(.typeText("omar@example.com")))
        eq("type the dash is broken", a(.typeText("the dash is broken")))
        eq("type I'll be there at 3", a(.typeText("I'll be there at 3")))
    }
}
