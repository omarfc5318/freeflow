import Foundation

/// Explicit task phrasing only; the broadest parser must never swallow simple commands.
enum RioTaskPhrasesTests {
    private static func parse(_ text: String) -> RioAction? {
        RioTaskPhrases.parse(raw: text, simplified: RioText.simplify(text))
    }

    static func run() {
        claims()
        notStealing()
        throughTheRealParser()
    }

    private static func claims() {
        let cases: [(String, String)] = [
            ("find me a flight to Doha next Friday under $800", "find me a flight to Doha next Friday under $800"),
            ("Find me a flight to Doha next Friday under $800.", "Find me a flight to Doha next Friday under $800"),
            ("Rio, find me a cheap hotel in Dubai", "find me a cheap hotel in Dubai"),
            ("can you find me a table for two tonight", "find me a table for two tonight"),
            ("please book a table at Nobu for Friday at 8", "book a table at Nobu for Friday at 8"),
            ("book a haircut for Saturday morning", "book a haircut for Saturday morning"),
            ("fill in this form with my details", "fill in this form with my details"),
            ("fill out this form", "fill out this form"),
            ("fill in the form using my name and email", "fill in the form using my name and email"),
            ("do this for me find the cheapest charger on Amazon", "find the cheapest charger on Amazon"),
            ("do this for me: order paper towels", "order paper towels"),
            ("do the laundry booking for me", "do the laundry booking"),
            ("go on Kayak and look for flights to Doha", "go on Kayak and look for flights to Doha"),
            ("go to Amazon and find a phone charger", "go to Amazon and find a phone charger"),
            ("go on booking.com and find a hotel in Doha", "go on booking.com and find a hotel in Doha"),
        ]
        for (text, goal) in cases {
            TestSupport.expectEqual(parse(text), .runTask(goal: goal))
        }
    }

    private static func notStealing() {
        let ignored = [
            "open Chrome", "go to google.com", "go to Amazon", "go on Amazon", "go back", "go to sleep",
            "find my resume", "find my tax return", "find me", "find", "book", "book it", "booking",
            "fill", "fill in", "do this for me", "do it for me", "do that for me", "do me a favor",
            "what's the weather", "play some music", "send a message to Ali", "remind me to call mom",
            "turn the volume up", "put Chrome on the left", "translate this", "what time is it in Doha",
            "I would like to find me some peace", "bookmark this page", "bookkeeping", "find the bug in my code",
            "", "Rio", "uh",
        ]
        for text in ignored {
            ETest.eq(parse(text), nil, "\(text) must not become a task")
        }
        // Over-long goals are not claimed (the handler caps at 300 anyway).
        let long = "find me " + String(repeating: "a flight ", count: 60)
        TestSupport.expectEqual(parse(long), nil)
    }

    private static func throughTheRealParser() {
        let parser = RioActionParser(installedApps: [])
        for text in ["open my resume", "go to google.com", "volume up", "what's the weather"] {
            if case .actions(let actions) = parser.parse(text), actions.contains(where: { if case .runTask = $0 { return true } else { return false } }) {
                TestSupport.expect(false, "\(text) must not become runTask")
            }
        }
        if case .actions(let actions) = parser.parse("Rio, find me a flight to Doha under $800") {
            TestSupport.expectEqual(actions, [.runTask(goal: "find me a flight to Doha under $800")])
        } else {
            TestSupport.expect(false, "explicit task phrasing reaches runTask through the real parser")
        }
    }
}
