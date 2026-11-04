import Foundation

/// Round 2 fixes for the smart routing and prompts: which prompt a question gets, the live-facts
/// rule, chat apps and the mic, one-key jobs, "answer that", long requests, Arabic answers,
/// currency, named sites and installed-app noise. Fakes only: no LLM, nothing runs.
enum RioSmartRound2Tests {
    private static let now = Date(timeIntervalSince1970: 1_793_714_709)
    private static let utc = TimeZone(identifier: "UTC")!

    private final class RecordingLLM: RioSmartLLMCompleting, @unchecked Sendable {
        var replies: [String]
        var systems: [String] = []
        var users: [String] = []
        init(_ replies: [String]) { self.replies = replies }
        func complete(system: String, user: String, maxOutputTokens: Int?) async throws -> String {
            systems.append(system)
            users.append(user)
            return replies.isEmpty ? "{\"actions\":[]}" : replies.removeFirst()
        }
    }

    private static func resolver(_ llm: RecordingLLM) -> RioSmartResolver {
        RioSmartResolver(llm: llm, isEnabled: { true }, isOnline: { true }, now: { now }, timeZone: { utc })
    }

    private static func plan(_ items: String) -> [RioAction] {
        RioSmartResponseParser.actions(from: "{\"actions\":[\(items)]}", now: now, timeZone: utc)
    }

    static func run() async {
        RioSpokenLanguageMemory.shared.clear()
        testWorldQuestionsGetTheShortPrompt()
        testMacQuestionsKeepTheContext()
        testLiveFactsAreLookedUp()
        testChatAppsNeverGoOverIMessage()
        testMicIsNeverTheSpeakers()
        testOneKeyJobs()
        testAnswerThatHasAPlan()
        testLongCommandsKeepTheirEnd()
        testArabicIsAnsweredInArabic()
        testCurrencyIsLookedUp()
        testNamedSitesAndLocalhost()
        testInstalledAppsMatchWholeWords()
        await testResolverAppliesTheGuards()
        await testResolverSaysWhatWasCut()
        await testResolverAnswersArabicInArabic()
        RioSpokenLanguageMemory.shared.clear()
    }

    // MARK: Finding A: too much context

    private static func testWorldQuestionsGetTheShortPrompt() {
        let world = [
            "explain the pigeonhole principle", "how do I reverse a linked list", "how do I write a for loop in Python?",
            "integrate x squared from 0 to 1", "solve x squared minus 5x plus 6 equals 0", "what's e to the i pi",
            "who won the Lakers game last night", "who won the game last night", "how do you say thank you in Spanish",
            "what day is it", "what year is it", "is it gonna rain tomorrow", "how are you", "tell me a joke",
            "who are you", "what's your name", "what is a convertible note",
            "what's the difference between a safe and a convertible note", "define entropy", "explain recursion",
            "convert 100 USD to QAR", "when is Maghrib prayer",
            // Unchanged world questions.
            "how far is the moon", "what is the capital of France", "who said to be or not to be",
        ]
        for text in world {
            TestSupport.expect(RioQuestionShape.isGeneralQuestion(text), "short prompt: \(text)")
        }
    }

    // MARK: Finding B: too little context

    private static func testMacQuestionsKeepTheContext() {
        let mac = [
            "what's the answer to number 3", "what's the answer to question 3", "how much ram is free",
            "how much storage is left", "is docker running", "how long has the dev server been running",
            "what's the staging url", "how do I turn on my wifi", "how do I fix this", "what does it say",
            "what's in my notes", "what is the note", "explain this", "translate this page", "is this proof right",
            // "answer that" and friends need the screen (finding 73).
            "answer that", "do this", "answer that question", "answer the question on the screen", "reply to that",
            "respond to Ali", "answer this email", "what should I reply",
            // Unchanged owner questions.
            "what did Ali say?", "what did Ali's mom say", "do I have class tomorrow", "what is due on Thursday",
            "when is my next class", "what's on my calendar this week", "what can you do",
        ]
        for text in mac {
            TestSupport.expect(!RioQuestionShape.isGeneralQuestion(text), "full prompt with context: \(text)")
        }
    }

    // MARK: Live facts (findings C and 59)

    private static func testLiveFactsAreLookedUp() {
        let system = RioSmartPrompt.system(now: now, timeZone: utc)
        let question = RioSmartPrompt.question(now: now, timeZone: utc)
        for prompt in [system, question] {
            for fact in ["prayer times", "sunrise and sunset", "flight status", "exchange rates", "sports results",
                         "opening hours", "use webSearch, never memory"] {
                TestSupport.expect(prompt.contains(fact), "live fact rule: \(fact)")
            }
        }
        TestSupport.expect(system.contains("are recall"), "the owner's own facts are recall")
        TestSupport.expect(system.contains("I can't check that yet"), "Mac state is never made up")
        TestSupport.expect(system.count < 8_700, "the full prompt stays compact (\(system.count))")
        TestSupport.expect(question.count < 1_500, "the question prompt stays short (\(question.count))")
    }

    // MARK: Finding 13: chat apps

    private static func testChatAppsNeverGoOverIMessage() {
        let system = RioSmartPrompt.system(now: now, timeZone: utc)
        TestSupport.expect(system.contains("sendMessage is iMessage or SMS only"), "prompt rule")
        let send = RioAction.sendMessage(to: "Ali", body: "call me when you're free")
        let cases: [(String, String)] = [
            ("message ali on whatsapp saying call me when you're free", "WhatsApp"),
            ("slack ahmed saying PR is up", "Slack"), ("send ahmed a slack saying PR is up", "Slack"),
            ("dm sarah on slack saying standup in 5", "Slack"), ("whatsapp mom saying I'll call you tonight", "WhatsApp"),
            ("text Ali on Telegram saying hi", "Telegram"), ("message the team on Teams saying hi", "Microsoft Teams"),
        ]
        for (command, app) in cases {
            ETest.eq(RioSmartPlanGuards.namedChatApp(command), app, command)
            ETest.eq(RioSmartPlanGuards.apply([send], command: command),
                     [.switchToApp(name: app), .answer(RioSmartPlanGuards.otherAppAnswer(app))], command)
        }
        // The app already in the plan is not switched to twice.
        ETest.eq(RioSmartPlanGuards.apply([.switchToApp(name: "WhatsApp"), send], command: "whatsapp ali saying hi"),
                 [.switchToApp(name: "WhatsApp"), .answer(RioSmartPlanGuards.otherAppAnswer("WhatsApp"))])
        // An app named only in the message, or a plain text, sends as before.
        for command in ["text mom saying check whatsapp", "tell Ali the signal is bad", "text Ali saying I'm on teams now", "text Ali I'm late"] {
            ETest.eq(RioSmartPlanGuards.apply([send], command: command), [send], command)
        }
        // A reply in the open conversation is left alone.
        ETest.eq(RioSmartPlanGuards.apply([.replyInConversation(body: "lgtm")], command: "reply on slack saying lgtm"),
                 [.replyInConversation(body: "lgtm")])
    }

    // MARK: Finding 23: mic and camera

    private static func testMicIsNeverTheSpeakers() {
        let system = RioSmartPrompt.system(now: now, timeZone: utc)
        TestSupport.expect(system.contains("never the mic"), "prompt rule")
        for command in ["mute my mic", "unmute me", "turn off my camera", "mute my microphone", "share my screen"] {
            ETest.eq(RioSmartPlanGuards.apply([.volume(.mute)], command: command), [.answer(RioSmartPlanGuards.micAnswer)], command)
        }
        ETest.eq(RioSmartPlanGuards.apply([.volume(.unmute), .volume(.up)], command: "unmute me"), [.answer(RioSmartPlanGuards.micAnswer)])
        // Speaker requests keep their volume step.
        for command in ["mute", "mute the video", "turn the volume down", "mute the sound and turn off my camera"] {
            ETest.eq(RioSmartPlanGuards.apply([.volume(.mute)], command: command), [.volume(.mute)], command)
        }
        ETest.eq(RioSmartPlanGuards.apply([.answer("ok")], command: "mute my mic"), [.answer("ok")], "no volume, nothing to change")
    }

    // MARK: Findings 20 and 34: one-key jobs

    private static func testOneKeyJobs() {
        func combo(_ key: String, command: Bool = true, shift: Bool = false) -> KeyCombo {
            KeyCombo(key: key, command: command, shift: shift, option: false, control: false)
        }
        ETest.eq(plan(#"{"action":"pressKeys","key":"n","modifiers":["command","shift"]}"#), [.pressKeys(combo("n", shift: true))])
        ETest.eq(plan(#"{"action":"pressKeys","key":"r","modifiers":["command","shift"]}"#), [.pressKeys(combo("r", shift: true))])
        ETest.eq(plan(#"{"action":"pressKeys","key":"p","modifiers":["command","shift"]}"#), [.pressKeys(combo("p", shift: true))])
        ETest.eq(plan(#"{"action":"pressKeys","key":"tab","modifiers":["command"]}"#), [.pressKeys(combo("tab"))])
        // Still refused: printing, pasting, quitting, select-all.
        for key in ["p", "v", "q", "a"] {
            ETest.eq(plan(#"{"action":"pressKeys","key":"\#(key)","modifiers":["command"]}"#), [], "command \(key) stays off")
        }
        ETest.eq(plan(#"{"action":"pressKeys","key":"tab","modifiers":["command","shift"]}"#), [])
        let system = RioSmartPrompt.system(now: now, timeZone: utc)
        for line in ["command shift n", "shift r (hard reload)", "shift p (command palette)", "command tab (once: back to the previous app)"] {
            TestSupport.expect(system.contains(line), "prompt lists \(line)")
        }
    }

    // MARK: Finding 73: "answer that"

    private static func testAnswerThatHasAPlan() {
        let system = RioSmartPrompt.system(now: now, timeZone: utc)
        for rule in ["describeScreen \"answer the question on screen\"", "readAloud lastMessage", "suggest a reply to the open conversation",
                     "Never invent a reply body"] {
            TestSupport.expect(system.contains(rule), "prompt rule: \(rule)")
        }
        // The window title stays reserved for window, tab and page commands.
        TestSupport.expect(!RioSmartContextPolicy.commandRefersToWindow("answer that"), "bare that is not the window")
    }

    // MARK: Finding 74: long requests

    private static func testLongCommandsKeepTheirEnd() {
        let middle = String(repeating: "and then there was this whole thing at work which is kind of stressful ", count: 11)
        let command = "so first open my notes " + middle + "maybe remind me in an hour to take a break and drink some water"
        TestSupport.expect(command.count > 800, "a long request (\(command.count))")
        TestSupport.expect(RioSmartPrompt.isClipped(command), "it is clipped")
        let sent = RioSmartPrompt.clipped(command)
        TestSupport.expect(sent.count <= RioSmartPrompt.maxCommandCharacters, "within the limit (\(sent.count))")
        TestSupport.expect(sent.hasPrefix("so first open my notes"), "the start survives")
        TestSupport.expect(sent.hasSuffix("take a break and drink some water"), "the closing request survives:\n\(sent)")
        TestSupport.expect(sent.contains(" \u{2026} "), "the cut is marked")
        let user = RioSmartPrompt.user(request: RioSmartRequest(command: command, context: RioSmartContext()))
        TestSupport.expect(user.contains("drink some water\nCOMMAND"), "the user message ends with the request")
        TestSupport.expect(user.contains("\u{2026}"), "the ellipsis is not cut off")
        ETest.eq(RioSmartPrompt.clipped("open Notes"), "open Notes", "short commands are whole")
        TestSupport.expect(!RioSmartPrompt.isClipped(String(repeating: "a", count: RioSmartPrompt.maxCommandCharacters)), "exactly the limit fits")
        // Seven valid steps: six run and the cut is reported.
        let seven = (0..<7).map { _ in #"{"action":"browser","command":"nextTab"}"# }.joined(separator: ",")
        let parsed = RioSmartResponseParser.plan(from: "{\"actions\":[\(seven)]}", now: now, timeZone: utc)
        ETest.eq(parsed.actions.count, 6)
        TestSupport.expect(parsed.wasCut, "the cut is known")
        let six = (0..<6).map { _ in #"{"action":"browser","command":"nextTab"}"# }.joined(separator: ",") + ",\"junk\""
        TestSupport.expect(!RioSmartResponseParser.plan(from: "{\"actions\":[\(six)]}", now: now, timeZone: utc).wasCut, "junk is not a step")
        ETest.eq(RioSmartPlanGuards.notices(planWasCut: true, commandWasClipped: true),
                 [.answer(RioSmartPlanGuards.cutAnswer), .answer(RioSmartPlanGuards.clippedAnswer)])
        ETest.eq(RioSmartPlanGuards.notices(planWasCut: false, commandWasClipped: false), [])
    }

    // MARK: Finding 55: Arabic

    private static func testArabicIsAnsweredInArabic() {
        let arabic = "ريو وش الجو اليوم"
        ETest.eq(RioSpokenLanguage.detect(transcript: arabic, plan: .llm), .arabic)
        ETest.eq(RioSpokenLanguage.detect(transcript: arabic, plan: .offline("Rio what's the weather today")), .arabic)
        ETest.eq(RioSpokenLanguage.detect(transcript: "Rio what's the weather", plan: .unchanged), .english)
        ETest.eq(RioSpokenLanguage.detect(transcript: "Rio type مرحبا", plan: .unchanged), .english, "an English frame is English")

        let memory = RioSpokenLanguageMemory()
        memory.record(.arabic, english: "Rio who won the Al Hilal match yesterday", at: now)
        ETest.eq(memory.language(forCommand: "who won the Al Hilal match yesterday", now: now.addingTimeInterval(2)), .arabic)
        ETest.eq(memory.language(forCommand: "open Chrome", now: now.addingTimeInterval(2)), .english, "another command is English")
        ETest.eq(memory.language(forCommand: "who won the Al Hilal match yesterday", now: now.addingTimeInterval(RioSpokenLanguageMemory.lifetime + 1)),
                 .english, "it expires")
        memory.record(.english, english: "who won the Al Hilal match yesterday", at: now)
        ETest.eq(memory.language(forCommand: "who won the Al Hilal match yesterday", now: now), .english, "the next English command resets it")

        let system = RioSmartPrompt.system(now: now, timeZone: utc, spokenLanguage: .arabic)
        let question = RioSmartPrompt.question(now: now, timeZone: utc, spokenLanguage: .arabic)
        TestSupport.expect(system.hasSuffix(RioSmartPrompt.arabicAnswerRule), "full prompt asks for Arabic")
        TestSupport.expect(question.hasSuffix(RioSmartPrompt.arabicAnswerRule), "question prompt asks for Arabic")
        TestSupport.expect(!RioSmartPrompt.system(now: now, timeZone: utc).contains("Gulf Arabic"), "English stays English")
        TestSupport.expect(!RioSmartPrompt.question(now: now, timeZone: utc).contains("Gulf Arabic"), "English stays English")

        TestSupport.expect(RioArabicVoiceChooser.needsArabicVoice("الجو مشمس اليوم في الدوحة"), "Arabic answer")
        TestSupport.expect(!RioArabicVoiceChooser.needsArabicVoice("It's sunny in Doha"), "English answer")
        let voices = [
            RioVoiceCandidate(identifier: "en.ava", name: "Ava", language: "en-US", quality: .premium),
            RioVoiceCandidate(identifier: "ar.maged", name: "Maged", language: "ar-SA", quality: .standard),
            RioVoiceCandidate(identifier: "ar.laila", name: "Laila", language: "ar-001", quality: .enhanced),
        ]
        ETest.eq(RioArabicVoiceChooser.pick(from: voices)?.identifier, "ar.laila", "best quality first")
        ETest.eq(RioArabicVoiceChooser.pick(from: Array(voices.prefix(2)))?.identifier, "ar.maged")
        ETest.eq(RioArabicVoiceChooser.pick(from: Array(voices.prefix(1))), nil, "no Arabic voice installed")
    }

    // MARK: Finding 56: currency

    private static func testCurrencyIsLookedUp() {
        for expression in ["100 USD to QAR", "50 euros to dollars", "how much is 100 dollars in riyals"] {
            ETest.eq(plan(#"{"action":"calculate","expression":"\#(expression)"}"#), [.webSearch(query: expression)], expression)
        }
        ETest.eq(plan(#"{"action":"calculate","expression":"15% of 84"}"#), [.calculate(expression: "15% of 84")], "maths still calculates")
        for junk in ["open Chrome", "2 +", "$(whoami)", "rm -rf ../ 5"] {
            ETest.eq(plan(#"{"action":"calculate","expression":"\#(junk)"}"#), [], "still dropped: \(junk)")
        }
        let system = RioSmartPrompt.system(now: now, timeZone: utc)
        TestSupport.expect(system.contains("currency conversions"), "currency is a live fact")
    }

    // MARK: Findings 2 and 19: named sites

    private static func testNamedSitesAndLocalhost() {
        let system = RioSmartPrompt.system(now: now, timeZone: utc)
        TestSupport.expect(system.contains("https://vercel.com"), "well-known sites by their official address")
        TestSupport.expect(system.contains("localhost and 127.0.0.1 aren't available here"), "localhost is explained")
        ETest.eq(plan(#"{"action":"openURL","url":"http://localhost:3000"}"#), [], "localhost stays owner-only")
    }

    // MARK: Finding 26: installed-app noise

    private static func testInstalledAppsMatchWholeWords() {
        let installed = ["Apps", "Freeform", "Image Playground", "WhatsApp", "Google Chrome", "TextEdit", "zoom.us", "Arc"]
        ETest.eq(RioSmartContextPolicy.relevantApps(installed, command: "message ali on whatsapp saying hi"), ["WhatsApp"])
        ETest.eq(RioSmartContextPolicy.relevantApps(installed, command: "am I free at 3"), [])
        ETest.eq(RioSmartContextPolicy.relevantApps(installed, command: "who won the first round"), [])
        ETest.eq(RioSmartContextPolicy.relevantApps(installed, command: "open text edit"), ["TextEdit"])
        ETest.eq(RioSmartContextPolicy.relevantApps(installed, command: "open zoom"), ["zoom.us"])
        ETest.eq(RioSmartContextPolicy.relevantApps(installed, command: "switch to arc"), ["Arc"])
        ETest.eq(RioSmartContextPolicy.relevantApps(installed, command: "close both chromes"), ["Google Chrome"])
        ETest.eq(RioSmartContextPolicy.relevantApps(installed, command: "open freeform"), ["Freeform"])
    }

    // MARK: Resolver wiring

    private static func testResolverAppliesTheGuards() async {
        let llm = RecordingLLM([
            #"{"actions":[{"action":"sendMessage","to":"Ali","body":"call me"}]}"#,
            #"{"actions":[{"action":"volume","mode":"mute"}]}"#,
            #"{"actions":[{"action":"calculate","expression":"100 USD to QAR"}]}"#,
        ])
        let resolver = resolver(llm)
        let whatsapp = await resolver.resolve(RioSmartRequest(command: "message ali on whatsapp saying call me", context: RioSmartContext()))
        ETest.eq(whatsapp, .actions([.switchToApp(name: "WhatsApp"), .answer(RioSmartPlanGuards.otherAppAnswer("WhatsApp"))]))
        let mic = await resolver.resolve(RioSmartRequest(command: "mute my mic", context: RioSmartContext()))
        ETest.eq(mic, .actions([.answer(RioSmartPlanGuards.micAnswer)]))
        let money = await resolver.resolve(RioSmartRequest(command: "convert 100 USD to QAR", context: RioSmartContext()))
        ETest.eq(money, .actions([.webSearch(query: "100 USD to QAR")]))
    }

    private static func testResolverSaysWhatWasCut() async {
        let seven = (0..<7).map { _ in #"{"action":"browser","command":"nextTab"}"# }.joined(separator: ",")
        let llm = RecordingLLM(["{\"actions\":[\(seven)]}", "{\"actions\":[]}"])
        let resolver = resolver(llm)
        let result = await resolver.resolve(RioSmartRequest(command: "next tab seven times", context: RioSmartContext()))
        ETest.eq(result, .actions(Array(repeating: RioAction.browser(.nextTab), count: 6) + [.answer(RioSmartPlanGuards.cutAnswer)]))
        let long = String(repeating: "word ", count: 150)
        let empty = await resolver.resolve(RioSmartRequest(command: long, context: RioSmartContext()))
        ETest.eq(empty, .actions([]), "nothing to do stays empty, no notice alone")
    }

    private static func testResolverAnswersArabicInArabic() async {
        let llm = RecordingLLM([#"{"actions":[{"action":"answer","text":"الجو مشمس"}]}"#, #"{"actions":[]}"#])
        let resolver = resolver(llm)
        RioSpokenLanguageMemory.shared.record(.arabic, english: "Rio what's the weather today", at: Date())
        let request = RioSmartRequest(command: "what's the weather today", context: RioSmartContext())
        ETest.eq(request.spokenLanguage, .arabic, "the request reads what the translator recorded")
        _ = await resolver.resolve(request)
        RioSpokenLanguageMemory.shared.clear()
        _ = await resolver.resolve(RioSmartRequest(command: "what's the weather today", context: RioSmartContext()))
        ETest.eq(llm.systems.count, 2)
        TestSupport.expect(llm.systems[0].contains(RioSmartPrompt.arabicAnswerRule), "Arabic answer asked for")
        TestSupport.expect(!llm.systems[1].contains(RioSmartPrompt.arabicAnswerRule), "English after it is cleared")
    }
}
