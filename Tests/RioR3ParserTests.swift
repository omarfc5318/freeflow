import Foundation

/// Round 3 parser-core follow-ups: take-backs, scoped and pronoun searches, follow-ups after a
/// site search or a chained command, "make it full screen" in a chain, thanks as the message,
/// "do this" lead-ins, stop-listening phrasings, Claude without "tell", and "explain this
/// <noun>". Synthetic installed apps and phrases only; nothing runs.
enum RioR3ParserTests {
    private static let apps: [InstalledApp] = ["Google Chrome", "Warp", "Safari", "Notes", "Xcode", "Spotify"].map {
        InstalledApp(name: $0, bundleIdentifier: "test.\(RioText.compact($0))", url: URL(fileURLWithPath: "/Applications/\($0).app"))
    }
    private static let parser = RioActionParser(installedApps: apps, isRecordingMacro: false)
    private static let gc = "Google Chrome"

    private static func a(_ actions: RioAction...) -> RioActionParse { .actions(actions) }
    private static func w(_ app: String?, _ placement: WindowPlacement) -> RioAction {
        .window(WindowCommand(appName: app, placement: placement))
    }
    private static func u(_ text: String) -> RioAction { .openURL(URL(string: text)!) }

    private static func isLocalAndSure(_ text: String) -> Bool {
        let analysis = parser.analyze(text)
        if case .actions = analysis.parse { return analysis.isConfident }
        return false
    }

    /// Runs `text` the way the coordinator does: the follow-up command text first, then the parser.
    private static func followUp(_ text: String) -> RioActionParse {
        let simplified = RioText.simplify(text)
        let context = RioFollowUpMemory.shared.snapshot()
        return parser.parse(RioFollowUpRewriter.commandText(simplified, context: context) ?? text)
    }

    /// Records a command's actions the way the coordinator does after they ran.
    private static func ran(_ text: String) {
        _ = RioFollowUpMemory.shared.snapshot()
        guard case .actions(let actions) = parser.parse(text) else {
            TestSupport.expect(false, "setup command \"\(text)\" must parse")
            return
        }
        for action in actions { RioFollowUpMemory.shared.record(action) }
    }

    static func run() {
        RioFollowUpMemory.shared.clear()
        defer { RioFollowUpMemory.shared.clear() }
        takeBacks()
        takeBacksKeepTheirWords()
        scopedSearches()
        pronounSearches()
        searchFollowUps()
        chainFollowUps()
        makeItFullScreen()
        followUpMemory()
        thanksIsTheMessage()
        doThisLeadIn()
        stopListening()
        claudeWithoutTell()
        explainThisNoun()
    }

    // MARK: 37 + 38a

    private static func takeBacks() {
        for text in [
            "quit Safari, wait no", "quit Safari wait no", "quit Safari. Wait, no.", "quit Safari. No wait.",
            "close Warp, no, sorry.", "lock my screen... no wait", "close Chrome no stop", "quit Chrome nope",
            "open Chrome wait wait", "quit Xcode... no, don't", "quit Xcode, no wait, don't", "quit Safari. No.",
            "quit Chrome. Oops, no.", "empty the trash. No!", "open Chrome, actually don't", "open Chrome... hold on",
            "Rio quit Safari, no wait", "remind me to call mom, no wait",
        ] {
            ETest.eq(parser.parse(text), .empty, "take-back: \(text)")
        }
        // Only the last command is taken back.
        ETest.eq(parser.parse("open Chrome and quit Safari, wait no"), a(.openApp(name: gc)))
        // The resolver hears the take-back too, never just the command.
        ETest.eq(parser.analyze("quit Xcode, no wait, don't").resolverText.lowercased().contains("don"), true)
    }

    private static func takeBacksKeepTheirWords() {
        ETest.eq(parser.parse("stop"), a(.cancelTimer), "a bare stop is still a stop")
        ETest.eq(parser.parse("stop, stop") == .empty, false, "stop twice is not a take-back")
        ETest.eq(parser.parse("don't stop the music") == .empty, false)
        ETest.eq(parser.parse("play no surprises"), a(.playMusic(query: "no surprises")))
        ETest.eq(parser.parse("play hold on"), a(.playMusic(query: "hold on")))
        ETest.eq(parser.parse("remind me to stop") == .empty, false)
        ETest.eq(parser.parse("tell him no"), a(.replyInConversation(body: "no")))
        ETest.eq(parser.parse("text Ali saying wait no"), a(.sendMessage(to: "Ali", body: "wait no")))
        ETest.eq(parser.parse("open Chrome. Actually, never mind"), .empty)
        ETest.eq(parser.parse("turn on do not disturb"), a(.doNotDisturb(isOn: true)))
    }

    // MARK: 5 + 24

    private static func scopedSearches() {
        ETest.eq(parser.parse("rio search my files for eigenvalue"), a(.revealFile(query: "eigenvalue")))
        ETest.eq(parser.parse("search my documents for the lease"), a(.revealFile(query: "the lease")))
        ETest.eq(parser.parse("search for eigenvalue in my files"), a(.revealFile(query: "eigenvalue")))
        for text in ["search the codebase for useAuth", "search the repo for useAuth", "search my email for the invoice"] {
            ETest.eq(isLocalAndSure(text), false, "goes to the resolver: \(text)")
            if case .actions(let actions) = parser.parse(text), actions.contains(where: { if case .webSearch = $0 { return true }; return false }) {
                TestSupport.expect(false, "never a web search: \(text)")
            }
        }
        ETest.eq(parser.parse("search google for cats"), a(.webSearch(query: "cats")))
        ETest.eq(parser.parse("search youtube for lofi"), a(u("https://www.youtube.com/results?search_query=lofi")))
        ETest.eq(parser.parse("search for cats"), a(.webSearch(query: "cats")))
        ETest.eq(parser.parse("search my history for the budget"), a(.searchHistory(query: "the budget")))
    }

    // MARK: 40

    private static func pronounSearches() {
        RioFollowUpMemory.shared.clear()
        for text in ["search that on Amazon", "search it on YouTube", "google that", "look that up", "search that on GitHub",
                     "search youtube for that"] {
            ETest.eq(isLocalAndSure(text), false, "no previous search: the resolver decides \(text)")
        }
        ran("search for mechanical keyboards")
        ETest.eq(followUp("search that on Amazon"), a(u("https://www.amazon.com/s?k=mechanical%20keyboards")))
        ETest.eq(followUp("search it on YouTube"), a(u("https://www.youtube.com/results?search_query=mechanical%20keyboards")))
        ETest.eq(followUp("search youtube for that"), a(u("https://www.youtube.com/results?search_query=mechanical%20keyboards")))
        ETest.eq(followUp("search that on GitHub"), a(u("https://github.com/search?q=mechanical%20keyboards")))
        RioFollowUpMemory.shared.clear()
    }

    // MARK: 41

    private static func searchFollowUps() {
        RioFollowUpMemory.shared.clear()
        ran("search for swift actors")
        ETest.eq(followUp("do the same on YouTube"), a(u("https://www.youtube.com/results?search_query=swift%20actors")))
        ran("do the same on YouTube")
        ETest.eq(followUp("same thing on GitHub"), a(u("https://github.com/search?q=swift%20actors")))
        ETest.eq(followUp("do the same on GitHub"), a(u("https://github.com/search?q=swift%20actors")))
        ETest.eq(RioFollowUpRewriter.commandText("do the same for kotlin coroutines", context: RioFollowUpMemory.shared.snapshot()), nil,
                 "never rewritten to \"open kotlin coroutines\"")
        ETest.eq(followUp("do the same for kotlin coroutines"), a(u("https://www.youtube.com/results?search_query=kotlin%20coroutines")))
        RioFollowUpMemory.shared.clear()
        ran("search reddit for keyboards")
        ETest.eq(followUp("do the same for mice"), a(.webSearch(query: "mice site:reddit.com")))
        RioFollowUpMemory.shared.clear()
        // A site opened by name is still "open": unchanged.
        RioFollowUpMemory.shared.record(.openURL(URL(string: "https://app.slack.com")!))
        ETest.eq(RioFollowUpRewriter.commandText("do the same for Warp", context: RioFollowUpMemory.shared.snapshot()), "open Warp")
        RioFollowUpMemory.shared.clear()
    }

    // MARK: 42

    private static func chainFollowUps() {
        RioFollowUpMemory.shared.clear()
        ran("open Chrome and put it on the left")
        ETest.eq(followUp("do the same for Warp"), a(.openApp(name: "Warp"), w("Warp", .leftHalf)))
        ETest.eq(followUp("and Warp too"), a(.openApp(name: "Warp"), w("Warp", .leftHalf)))
        // One step: as before.
        ran("open Chrome")
        ETest.eq(followUp("do the same for Warp"), a(.openApp(name: "Warp")))
        // Steps about different apps: only the last one is repeated, as before.
        ran("open Chrome and quit Safari")
        ETest.eq(followUp("do the same for Warp"), a(.quitApp(name: "Warp")))
        RioFollowUpMemory.shared.clear()
    }

    // MARK: 39

    private static func makeItFullScreen() {
        RioFollowUpMemory.shared.clear()
        ran("put xcode in the middle")
        ETest.eq(parser.parse("Rio open Notes and make it full screen"), a(.openApp(name: "Notes"), w("Notes", .maximize)))
        RioFollowUpMemory.shared.clear()
        ran("quit Warp")
        ETest.eq(parser.parse("open Notes and make it full screen"), a(.openApp(name: "Notes"), w("Notes", .maximize)))
        ETest.eq(parser.parse("make it full screen"), a(w(nil, .maximize)), "Warp was quit: the front window")
        ETest.eq(parser.parse("open it again"), a(.openApp(name: "Warp")), "reopening the quit app still works")
        RioFollowUpMemory.shared.clear()
        ran("hide Spotify")
        ETest.eq(parser.parse("make it bigger"), a(w(nil, .maximize)), "a hidden app is not \"it\"")
        RioFollowUpMemory.shared.clear()
        ran("open Notes")
        ETest.eq(parser.parse("make it bigger"), a(w("Notes", .maximize)), "a fresh app still is")
        RioFollowUpMemory.shared.clear()
    }

    private static func followUpMemory() {
        let now = Date(timeIntervalSince1970: 1_793_714_709)
        let memory = RioFollowUpMemory()
        memory.record(.openApp(name: "Chrome"), now: now)
        memory.record(w("Chrome", .leftHalf), now: now)
        ETest.eq(memory.snapshot(now: now)?.lastChain, [.openApp(name: "Chrome"), w("Chrome", .leftHalf)])
        // Reading the context closes the chain: the next command starts a new one.
        memory.record(.volume(.up), now: now)
        ETest.eq(memory.snapshot(now: now)?.lastChain, [.volume(.up)])
        memory.beginCommand()
        memory.record(.quitApp(name: "Chrome"), now: now)
        ETest.eq(memory.snapshot(now: now)?.lastChain, [.quitApp(name: "Chrome")])
        ETest.eq(memory.snapshot(now: now)?.isLastAppGone, true)
        memory.record(.openApp(name: "Chrome"), now: now)
        ETest.eq(memory.snapshot(now: now)?.isLastAppGone, false)
        memory.record(u("https://www.youtube.com/results?search_query=swift%20actors"), now: now)
        ETest.eq(memory.snapshot(now: now)?.lastSearchQuery, "swift actors")
        memory.record(.webSearch(query: "site:reddit.com keyboards"), now: now)
        ETest.eq(memory.snapshot(now: now)?.lastSearchQuery, "keyboards")
        memory.record(u("https://www.youtube.com/watch?v=abc"), now: now)
        ETest.eq(memory.snapshot(now: now)?.lastSearchQuery, nil)
    }

    // MARK: 22

    private static func thanksIsTheMessage() {
        ETest.eq(parser.analyze("say thanks").resolverText, "say thanks")
        ETest.eq(parser.analyze("Rio, say thanks").resolverText, "say thanks")
        ETest.eq(parser.analyze("tell Ahmed thank you").resolverText, "tell Ahmed thank you")
        ETest.eq(parser.analyze("respond thanks").resolverText, "respond thanks")
        ETest.eq(parser.parse("tell claude thanks"), a(.claudeCode(.send("thanks"))))
        ETest.eq(parser.parse("tell claude thank you"), a(.claudeCode(.send("thank you"))))
        ETest.eq(parser.parse("open Chrome thanks"), a(.openApp(name: gc)), "a thanks after a command still goes")
        ETest.eq(parser.parse("text Ali thanks"), a(.sendMessage(to: "Ali", body: "thanks")))
    }

    // MARK: 20a

    private static func doThisLeadIn() {
        ETest.eq(parser.parse("do this, open chrome"), a(.openApp(name: gc)))
        ETest.eq(parser.parse("do this: put chrome on the left"), a(w(gc, .leftHalf)))
        ETest.eq(parser.parse("can you do this for me, open Safari"), a(.openApp(name: "Safari")))
        ETest.eq(parser.parse("do me a favor and open chrome"), a(.openApp(name: gc)))
        ETest.eq(parser.analyze("Rio, do this. Reply to Sarah saying I'll be there at 5").resolverText.hasPrefix("Reply to Sarah"), true)
        ETest.eq(parser.parse("do this"), .unknown("do this"), "a bare \"do this\" stays whole")
        ETest.eq(RioActionParser.splitClauses("do this, Rio answer that"), ["do this", "answer that"])
    }

    // MARK: 64 + 97b

    private static func stopListening() {
        for text in ["Rio sleep", "Rio take a break", "Rio okay you can go now", "Rio turn yourself off", "Rio off",
                     "Rio quiet mode", "Rio mute yourself", "goodbye", "good night", "bye Rio", "go to sleep",
                     "stop listening", "Rio go to sleep for a bit", "turn off your mic"] {
            ETest.eq(parser.parse(text), a(.stopListening), "stops listening: \(text)")
        }
        for text in ["Rio, mic off", "turn off the mic", "mute the mic", "turn the mic off", "turn off",
                     "put my mac to sleep", "open Chrome and sleep"] {
            ETest.eq(parser.parse(text) == a(.stopListening), false, "not Rio's own off switch: \(text)")
        }
    }

    // MARK: 65

    private static func claudeWithoutTell() {
        ETest.eq(parser.parse("Rio cloud run the tests"), a(.claudeCode(.send("run the tests"))))
        ETest.eq(parser.parse("Rio Claude run the tests"), a(.claudeCode(.send("run the tests"))))
        ETest.eq(parser.parse("clawed fix the failing test"), a(.claudeCode(.send("fix the failing test"))))
        ETest.eq(parser.parse("Rio cloud code status"), a(.claudeCode(.status)))
        ETest.eq(parser.parse("Rio ask Claude how do I center a div"), a(.claudeCode(.send("how do I center a div"))))
        ETest.eq(parser.parse("Rio tell clod to stop"), a(.claudeCode(.send("stop"))), "unchanged")
        for text in ["open the cloud console", "what's a cloud", "cloud storage prices"] {
            if case .actions(let actions) = parser.parse(text), actions.contains(where: { if case .claudeCode = $0 { return true }; return false }) {
                TestSupport.expect(false, "not about Claude: \(text)")
            }
        }
    }

    // MARK: 8a

    private static func explainThisNoun() {
        for text in ["rio explain this theorem", "explain this slide", "explain that proof", "what does this mean",
                     "explain what this means", "solve this problem", "explain the selected code", "explain this function to me"] {
            ETest.eq(parser.parse(text), a(.selectionTask(.explain)), "explain: \(text)")
        }
        for text in ["summarize this pdf", "summarize this document"] {
            ETest.eq(parser.parse(text), a(.selectionTask(.summarize)), "summarize: \(text)")
        }
        ETest.eq(parser.parse("explain this"), a(.selectionTask(.explain)))
        ETest.eq(parser.parse("explain this error"), a(.selectionTask(.explain)))
        ETest.eq(parser.parse("summarize this page"), a(.describeScreen(question: nil)), "the screen parser keeps the page")
        ETest.eq(parser.parse("summarize this meeting"), a(.meeting(.recap)))
        ETest.eq(isLocalAndSure("explain this to Ali"), false)
        ETest.eq(isLocalAndSure("summarize this email and send it"), false)
        ETest.eq(isLocalAndSure("summarize this week"), false)
    }
}
