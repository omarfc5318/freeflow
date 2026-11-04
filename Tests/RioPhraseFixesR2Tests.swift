import Foundation

/// Round 2 fixes for the domain phrase parsers: Notion notes, recall before dictation search,
/// topic-only email drafts, other messaging apps, sites and spoken URLs, click ordinals and
/// timer edge numbers. Synthetic phrases only.
enum RioPhraseFixesR2Tests {
    private static let parser = RioActionParser(installedApps: [])

    private static func parse(_ text: String) -> RioActionParse { parser.parse(text) }

    private static func isSure(_ text: String) -> Bool {
        if case .actions = parser.parse(text) { return true }
        return false
    }

    static func run() {
        notion()
        recallFirst()
        topicEmail()
        otherMessagingApps()
        sites()
        spokenURLs()
        ordinals()
        timerEdges()
    }

    @MainActor private final class HistoryExecutor: RioActionExecuting {
        var executed: [RioAction] = []
        var reply: RioActionResult
        init(reply: RioActionResult) { self.reply = reply }
        func execute(_ action: RioAction) async -> RioActionResult {
            executed.append(action)
            return reply
        }
    }

    /// A memory miss looks through the dictations; a hit never does.
    @MainActor static func runAsync() async {
        let missMessage = RioActionResult.failed(message: "I don't have anything saved about the budget.")
        let found = HistoryExecutor(reply: .done(summary: "On Monday you said: the budget is tight"))
        let fromHistory = await RioRecallFallback.resolve(memory: missMessage, query: "the budget", executor: found)
        ETest.eq(fromHistory, .done(summary: "On Monday you said: the budget is tight"))
        ETest.eq(found.executed, [.searchHistory(query: "the budget")])

        let empty = HistoryExecutor(reply: .failed(message: "nothing"))
        let stillMissing = await RioRecallFallback.resolve(memory: missMessage, query: "the budget", executor: empty)
        ETest.eq(stillMissing, missMessage)

        let hit = HistoryExecutor(reply: .done(summary: "unused"))
        let remembered = await RioRecallFallback.resolve(memory: .done(summary: "Your seed round closes December 15"), query: "seed round", executor: hit)
        ETest.eq(remembered, .done(summary: "Your seed round closes December 15"))
        let blank = await RioRecallFallback.resolve(memory: missMessage, query: " ", executor: hit)
        ETest.eq(blank, missMessage)
        ETest.eq(hit.executed, [], "a hit or an empty question never searches the dictations")
    }

    private static func notion() {
        let follow = RioActionParse.actions([.notionAdd(text: "follow up with sequoia", page: nil)])
        ETest.eq(parse("add a note to notion saying follow up with sequoia"), follow)
        ETest.eq(parse("take a note in notion saying follow up with sequoia"), follow)
        ETest.eq(parse("note in notion follow up with sequoia"), follow)
        ETest.eq(parse("add to notion fix the onboarding bug"), .actions([.notionAdd(text: "fix the onboarding bug", page: nil)]))
        ETest.eq(parse("take a note in Notion: call Ali and Sam"), .actions([.notionAdd(text: "call Ali and Sam", page: nil)]))
        // Rio Notes keep working.
        ETest.eq(parse("take a note buy milk"), .actions([.addNote(text: "Buy milk")]))
        ETest.eq(RioMemoryPhrases.parse(raw: "add a note to notion saying hi", simplified: "add a note to notion saying hi"), nil)
    }

    private static func recallFirst() {
        let saved = RioRememberedFacts.provider
        defer { RioRememberedFacts.provider = saved }
        RioRememberedFacts.provider = { ["our seed round closes december 15", "the staging url is staging dot hala dot app"] }
        ETest.eq(parse("what did I say about the seed round"), .actions([.recall(query: "the seed round")]))
        ETest.eq(parse("what did I tell you about the seed round"), .actions([.recall(query: "the seed round")]))
        ETest.eq(parse("what's the staging url"), .actions([.recall(query: "staging url")]))
        ETest.eq(parse("what is our seed round"), .actions([.recall(query: "seed round")]))
        // Nothing remembered about it: the dictation timeline, as before.
        ETest.eq(parse("what did I say about the budget"), .actions([.searchHistory(query: "the budget")]))
        if case .actions(let list) = parse("what's the capital of France") {
            TestSupport.expect(!list.contains(.recall(query: "capital of france")), "general question became recall")
        }
        RioRememberedFacts.provider = { [] }
        ETest.eq(parse("what did I say about the seed round"), .actions([.searchHistory(query: "the seed round")]))
    }

    private static func topicEmail() {
        ETest.eq(RioEmailPhrases.parse("draft an email to investors about the november update"), nil)
        ETest.eq(RioEmailPhrases.parse("draft an email to Sam regarding the offsite"), nil)
        TestSupport.expect(!isSure("draft an email to investors about the november update"), "topic-only email must reach the resolver")
        ETest.eq(RioEmailPhrases.parse("draft an email to sarah saying the deck is attached"),
                 .draftEmail(to: "sarah", subject: nil, body: "The deck is attached"))
        ETest.eq(RioEmailPhrases.parse("email Sam subject lunch body see you at noon"),
                 .draftEmail(to: "Sam", subject: "Lunch", body: "See you at noon"))
        ETest.eq(RioEmailPhrases.parse("email Sam about lunch saying see you at noon"),
                 .draftEmail(to: "Sam", subject: "Lunch", body: "See you at noon"))
    }

    private static func otherMessagingApps() {
        for text in ["text mom on whatsapp saying I'm home", "message mom on whatsapp saying I'm home",
                     "text Ali on Slack saying the build is green", "text mom via telegram that I'm home",
                     "message Sam on WhatsApp I'm home"] {
            if case .actions(let list) = parse(text) {
                TestSupport.expect(!list.contains { if case .sendMessage = $0 { return true } else { return false } },
                                   "'\(text)' must not go out over iMessage: \(list)")
            }
        }
        ETest.eq(parse("text mom on imessage saying I'm home"), .actions([.sendMessage(to: "mom", body: "I'm home")]))
        ETest.eq(parse("text mom saying I'm on whatsapp now"), .actions([.sendMessage(to: "mom", body: "I'm on whatsapp now")]))
        ETest.eq(parse("text mom I'm late"), .actions([.sendMessage(to: "mom", body: "I'm late")]))
    }

    private static func url(_ string: String) -> RioActionParse { .actions([.openURL(URL(string: string)!)]) }

    private static func sites() {
        let cases: [(String, String)] = [
            ("open gradescope", "https://www.gradescope.com"), ("open piazza", "https://piazza.com"),
            ("open Overleaf", "https://www.overleaf.com"), ("open Desmos", "https://www.desmos.com/calculator"),
            ("open Wolfram Alpha", "https://www.wolframalpha.com"), ("open vercel", "https://vercel.com"),
            ("open vercel dashboard", "https://vercel.com/dashboard"), ("open supabase", "https://supabase.com"),
            ("open the supabase dashboard", "https://supabase.com/dashboard"), ("open linear", "https://linear.app"),
            ("open linear dot app", "https://linear.app"), ("open leetcode", "https://leetcode.com"),
            ("open khan academy", "https://www.khanacademy.org"), ("open quizlet", "https://quizlet.com"),
            ("open npm", "https://www.npmjs.com"), ("open gitlab", "https://gitlab.com"),
        ]
        for (text, expected) in cases { ETest.eq(parse(text), url(expected), text) }
    }

    private static func spokenURLs() {
        let cases: [(String, String)] = [
            ("open github.com/ofarhan", "https://github.com/ofarhan"),
            ("open github dot com slash vercel slash next dot js", "https://github.com/vercel/next.js"),
            ("go to github dot com slash anthropics", "https://github.com/anthropics"),
            ("open hala discover dot com slash about", "https://haladiscover.com/about"),
            ("open hala discover dot com", "https://haladiscover.com"),
            ("open localhost colon 3000", "http://localhost:3000"),
            ("open localhost:8081", "http://localhost:8081"),
            ("open staging dot hala dot app", "https://staging.hala.app"),
        ]
        for (text, expected) in cases { ETest.eq(parse(text), url(expected), text) }
        ETest.eq(RioWebURLs.domainURL(fromSpoken: "github dot com ofarhan"), nil, "a spoken host needs slash before a path")
        ETest.eq(RioWebURLs.domainURL(fromSpoken: "github.com slash a b"), URL(string: "https://github.com/ab"))
        ETest.eq(RioWebURLs.domainURL(fromSpoken: "github.com slash $x"), nil)
        ETest.eq(parse("open youtube dot com and search for lo-fi"), parse("open youtube and search for lo-fi"))
        // Two clauses still split, each URL written out.
        ETest.eq(parse("open github dot com and open gradescope"),
                 .actions([.openURL(URL(string: "https://github.com")!), .openURL(URL(string: "https://www.gradescope.com")!)]))
        // Text that is not an open command is left alone.
        ETest.eq(RioWebURLs.writingSpokenURLs(in: "email john at example dot com"), "email john at example dot com")
        ETest.eq(RioWebURLs.writingSpokenURLs(in: "type go to github dot com"), "type go to github dot com")
    }

    private static func click(_ text: String) -> RioAction? {
        RioScreenPhrases.parse(raw: text, simplified: RioText.simplify(text))
    }

    private static func ordinals() {
        ETest.eq(click("click the second to last link"), .click(label: "link", ordinal: -2))
        ETest.eq(click("click the next to last button"), .click(label: "button", ordinal: -2))
        ETest.eq(click("click the penultimate link"), .click(label: "link", ordinal: -2))
        ETest.eq(click("click the last one"), .click(label: "", ordinal: -1))
        ETest.eq(click("click the 1st one"), .click(label: "", ordinal: 1))
        ETest.eq(click("click the twelfth link"), .click(label: "link", ordinal: 12))
        ETest.eq(click("click the twenty first one"), nil)
        ETest.eq(click("click the 25th link"), nil)
        ETest.eq(click("click the fourth from last link"), nil)
        ETest.eq(click("click the 3rd link"), .click(label: "link", ordinal: 3))
        ETest.eq(click("open the first one"), .click(label: "", ordinal: 1))
        ETest.eq(click("open the 5th result"), .click(label: "link", ordinal: 5))
        ETest.eq(click("select the third option"), .click(label: "option", ordinal: 3))
        ETest.eq(click("choose the last item"), .click(label: "item", ordinal: -1))
        ETest.eq(click("open the twenty first result"), nil)
        ETest.eq(click("open the budget one"), nil)
        // Through the parser: "open it" is still the follow-up layer's, "open the first one" a click.
        ETest.eq(parse("open the first one"), .actions([.click(label: "", ordinal: 1)]))
    }

    private static func timerEdges() {
        func timer(_ text: String) -> RioAction? { RioVoicePhrases.parse(raw: text, simplified: RioText.simplify(text)) }
        ETest.eq(timer("set a timer for 0 minutes"), .answer(RioTimerPhrases.zeroReply))
        ETest.eq(timer("set a timer for 25 hours"), .answer(RioTimerPhrases.tooLongReply))
        ETest.eq(timer("set a timer for 1 million minutes"), .answer(RioTimerPhrases.tooLongReply))
        ETest.eq(timer("set a timer for 5 minutes"), .startTimer(seconds: 300, label: nil))
        ETest.eq(timer("set a timer for 24 hours"), .startTimer(seconds: 86_400, label: nil))
        ETest.eq(RioTimerPhrases.protectingDurations(in: "set a timer for -5 minutes"), "set a timer for minus 5 minutes")
        ETest.eq(RioTimerPhrases.protectingDurations(in: "set the volume to -5"), "set the volume to -5", "only timers")
        ETest.eq(parse("set a timer for -5 minutes"), .actions([.answer(RioTimerPhrases.negativeReply)]))
        ETest.eq(parse("set a timer for 25 hours"), .actions([.answer(RioTimerPhrases.tooLongReply)]))
        ETest.eq(RioTimerDuration.parse("1 million minutes"), nil)
    }
}
