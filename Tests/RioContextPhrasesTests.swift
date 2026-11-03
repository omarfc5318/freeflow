import Foundation

/// Context phrases (builder E): reply, read, summarize/explain/translate/improve, text a contact.
enum RioContextPhrasesTests {
    private static func parse(_ raw: String) -> RioAction? {
        RioContextPhrases.parse(raw: raw, simplified: RioText.simplify(raw))
    }

    static func run() {
        testReply()
        testReading()
        testSelectionTasks()
        testMessages()
        testNegatives()
        testThroughRealParser()
    }

    private static func testReply() {
        let cases: [(String, String)] = [
            ("reply saying I'll be there at 5", "I'll be there at 5"),
            ("Reply with sounds good.", "sounds good"),
            ("reply that I am running late", "I am running late"),
            ("reply to this saying thanks a lot", "thanks a lot"),
            ("reply to them saying on my way", "on my way"),
            ("reply back saying yes please", "yes please"),
            ("tell them I'm running ten minutes late", "I'm running ten minutes late"),
            ("tell him thanks for the help", "thanks for the help"),
            ("tell her I'll call tonight.", "I'll call tonight"),
        ]
        for (input, body) in cases {
            ETest.eq(parse(input), .replyInConversation(body: body), "reply: \(input)")
        }
        ETest.eq(parse("reply"), nil)
        ETest.eq(parse("reply saying"), nil)
        ETest.eq(parse("tell them"), nil)
    }

    private static func testReading() {
        let lastMessage = [
            "read my last message", "read me my last message", "read me the last message",
            "read the latest message", "Read my last text.", "read me my newest message",
            "what did he say", "what did she say?", "what did they say",
        ]
        for input in lastMessage { ETest.eq(parse(input), .readAloud(.lastMessage), input) }
        let page = [
            "read this page", "read me this page", "read this article", "read the page",
            "read this website", "read me this article.", "read this webpage",
        ]
        for input in page { ETest.eq(parse(input), .readAloud(.page), input) }
        let selection = [
            "read the selection", "read my selection", "read me the selected text",
            "read selection", "read this out loud", "read that aloud", "read the highlighted text",
        ]
        for input in selection { ETest.eq(parse(input), .readAloud(.selection), input) }
    }

    private static func testSelectionTasks() {
        for input in ["summarize this", "Summarize that.", "summarise the selection", "sum up this text",
                      "summarize the selected text", "summarize this email", "summarize it"] {
            ETest.eq(parse(input), .selectionTask(.summarize), input)
        }
        for input in ["explain this", "explain that", "explain the selection", "explain this error",
                      "explain this code to me", "explain it"] {
            ETest.eq(parse(input), .selectionTask(.explain), input)
        }
        ETest.eq(parse("translate this to Arabic"), .selectionTask(.translate(language: "Arabic")))
        ETest.eq(parse("translate that into french."), .selectionTask(.translate(language: "French")))
        ETest.eq(parse("translate the selection to Brazilian Portuguese"),
                                .selectionTask(.translate(language: "Brazilian Portuguese")))
        ETest.eq(parse("translate to Spanish"), .selectionTask(.translate(language: "Spanish")))
        ETest.eq(parse("translate this"), nil)
        for input in ["improve this", "improve my selection", "proofread this", "proofread the selection",
                      "polish this", "fix the grammar", "fix the grammar in this", "fix my spelling",
                      "rewrite this better", "improve the writing"] {
            ETest.eq(parse(input), .selectionTask(.improve), input)
        }
    }

    private static func testMessages() {
        let cases: [(String, String, String)] = [
            ("text Ali saying I'll be late", "Ali", "I'll be late"),
            ("Text Sarah that I'm on my way.", "Sarah", "I'm on my way"),
            ("message Mom saying happy birthday", "Mom", "happy birthday"),
            ("send a text to Ali saying see you soon", "Ali", "see you soon"),
            ("send a message to Sarah Khan saying hello there", "Sarah Khan", "hello there"),
            ("send an iMessage to Omar that dinner is ready", "Omar", "dinner is ready"),
            ("text Ali I'll be late", "Ali", "I'll be late"),
            ("text mom: call me when you can", "mom", "call me when you can"),
            ("text Ali with sounds good", "Ali", "sounds good"),
            ("message 555 123 4567 saying hi", "555 123 4567", "hi"),
        ]
        for (input, to, body) in cases {
            ETest.eq(parse(input), .sendMessage(to: to, body: body), input)
        }
        ETest.eq(parse("text Ali"), nil)
        ETest.eq(parse("text Ali saying"), nil)
    }

    /// Nothing B owns (or the other builders' obvious phrasings) may be claimed here.
    private static func testNegatives() {
        let notMine = [
            "open Chrome", "open YouTube", "close Spotify", "quit Chrome", "open messages",
            "open the Messages app", "switch to Slack", "volume up", "mute", "play music",
            "search for cats", "google how to read faster", "type hello world", "write a poem",
            "put Chrome on the left", "take a screenshot", "lock my screen",
            "what's the capital of France", "how many ounces in a cup", "read a book",
            "read the news", "read about swift", "tell me a joke", "tell me the time",
            "text me later", "message me", "open my resume", "set a timer for 5 minutes",
            "undo", "what can you do", "what's next", "what did you say",
            "translate", "summary", "improve", "explain", "reply", "replying",
            "open the page", "open reader", "text editor", "open TextEdit", "open Telegram",
            "messages", "texting is fun", "explain quantum physics",
        ]
        for input in notMine { ETest.eq(parse(input), nil, "must not steal: \(input)") }
    }

    private static func testThroughRealParser() {
        let parser = RioActionParser(installedApps: [
            InstalledApp(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", url: URL(fileURLWithPath: "/Applications/Google Chrome.app")),
            InstalledApp(name: "Messages", bundleIdentifier: "com.apple.MobileSMS", url: URL(fileURLWithPath: "/System/Applications/Messages.app")),
        ])
        ETest.eq(parser.parse("reply saying yes"), .actions([.replyInConversation(body: "yes")]))
        ETest.eq(parser.parse("read my last message"), .actions([.readAloud(.lastMessage)]))
        ETest.eq(parser.parse("translate this to Arabic"), .actions([.selectionTask(.translate(language: "Arabic"))]))
        ETest.eq(parser.parse("text Ali saying running late"), .actions([.sendMessage(to: "Ali", body: "running late")]))
        ETest.eq(parser.parse("open Chrome"), .actions([.openApp(name: "Google Chrome")]))
        ETest.eq(parser.parse("open Messages"), .actions([.openApp(name: "Messages")]))
    }
}
