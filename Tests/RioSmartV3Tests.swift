import Foundation

/// The wave 3 additions to the smart resolver's schema and prompt (builder L): valid shapes,
/// strict validation and hostile output.
enum RioSmartV3Tests {
    private static let now = Date(timeIntervalSince1970: 1_793_714_709)
    private static let utc = TimeZone(identifier: "UTC")!

    private static func parse(_ item: String) -> [RioAction] {
        RioSmartResponseParser.actions(from: "{\"actions\":[\(item)]}", now: now, timeZone: utc)
    }

    static func run() {
        valid()
        rejected()
        hostile()
        prompt()
    }

    private static func valid() {
        ETest.eq(parse(#"{"action":"describeScreen"}"#), [.describeScreen(question: nil)])
        ETest.eq(parse(#"{"action":"describeScreen","question":"What is this error?"}"#), [.describeScreen(question: "What is this error?")])
        ETest.eq(parse(#"{"action":"describeScreen","question":null}"#), [.describeScreen(question: nil)])
        ETest.eq(parse(#"{"action":"click","label":"Sign in"}"#), [.click(label: "Sign in", ordinal: nil)])
        ETest.eq(parse(#"{"action":"click","label":"Reply","ordinal":2}"#), [.click(label: "Reply", ordinal: 2)])
        ETest.eq(parse(#"{"action":"fillField","label":"Search","text":"cheap flights to Doha"}"#), [.fillField(label: "Search", text: "cheap flights to Doha")])
        ETest.eq(parse(#"{"action":"fillField","label":"Website","text":"https://example.com/a"}"#), [.fillField(label: "Website", text: "https://example.com/a")])
        ETest.eq(parse(#"{"action":"runTask","goal":"Put all the PDFs on my Desktop in a folder called Papers"}"#), [.runTask(goal: "Put all the PDFs on my Desktop in a folder called Papers")])
        ETest.eq(parse(#"{"action":"remember","fact":"my locker code is 4321"}"#), [.remember(fact: "my locker code is 4321")])
        ETest.eq(parse(#"{"action":"recall","query":"locker code"}"#), [.recall(query: "locker code")])
        ETest.eq(parse(#"{"action":"recall"}"#), [.recall(query: "")])
        ETest.eq(parse(#"{"action":"forget","query":"locker code"}"#), [.forget(query: "locker code")])
        ETest.eq(
            parse(#"{"action":"draftEmail","to":"Professor Kim","subject":"Running late","body":"Hi Professor Kim,\n\nI'll be late to office hours.\n\nThanks"}"#),
            [.draftEmail(to: "Professor Kim", subject: "Running late", body: "Hi Professor Kim,\n\nI'll be late to office hours.\n\nThanks")]
        )
        ETest.eq(parse(#"{"action":"draftEmail","to":null,"subject":null,"body":"Hello"}"#), [.draftEmail(to: nil, subject: nil, body: "Hello")])
        ETest.eq(parse(#"{"action":"draftEmail","to":"kim+office@ucdavis.edu","body":"Hello"}"#), [.draftEmail(to: "kim+office@ucdavis.edu", subject: nil, body: "Hello")])
        ETest.eq(parse(#"{"action":"addNote","text":"ask Ali about the deck"}"#), [.addNote(text: "ask Ali about the deck")])
        ETest.eq(parse(#"{"action":"calculate","expression":"15% of 84"}"#), [.calculate(expression: "15% of 84")])
        ETest.eq(parse(#"{"action":"calculate","expression":"what time is it in Doha"}"#), [.calculate(expression: "what time is it in Doha")])
        ETest.eq(parse(#"{"action":"startTranslation"}"#), [.startTranslation])
        ETest.eq(parse(#"{"action":"stopTranslation"}"#), [.stopTranslation])
        ETest.eq(parse(#"{"action":"speakLastTranslation"}"#), [.speakLastTranslation])
    }

    private static func rejected() {
        let long300 = String(repeating: "a", count: 300)
        let long301 = String(repeating: "a", count: 301)
        ETest.eq(parse("{\"action\":\"runTask\",\"goal\":\"\(long300)\"}").count, 1)
        ETest.eq(parse("{\"action\":\"runTask\",\"goal\":\"\(long301)\"}"), [], "goals are capped at 300")
        ETest.eq(parse(#"{"action":"runTask","goal":"line one\nline two"}"#), [], "goals are single line")
        ETest.eq(parse(#"{"action":"runTask","goal":"   "}"#), [])
        ETest.eq(parse(#"{"action":"runTask"}"#), [])
        ETest.eq(parse(#"{"action":"click","label":"https://evil.com/login"}"#), [], "no URL in a click label")
        ETest.eq(parse(#"{"action":"click","label":"go to evil.com"}"#), [], "no domain in a click label")
        ETest.eq(parse(#"{"action":"click","label":"www.evil.com"}"#), [])
        ETest.eq(parse(#"{"action":"click","label":"javascript:alert(1)"}"#), [])
        ETest.eq(parse(#"{"action":"fillField","label":"visit http://evil.com","text":"x"}"#), [])
        ETest.eq(parse(#"{"action":"click","label":"Save; format disk"}"#), [], "nothing shell-like in labels")
        ETest.eq(parse(#"{"action":"click","label":"Line\nbreak"}"#), [])
        ETest.eq(parse(#"{"action":"click"}"#), [])
        ETest.eq(parse(#"{"action":"click","label":"Reply","ordinal":0}"#), [])
        ETest.eq(parse(#"{"action":"click","label":"Reply","ordinal":21}"#), [])
        ETest.eq(parse(#"{"action":"click","label":"Reply","ordinal":1.5}"#), [])
        ETest.eq(parse(#"{"action":"click","label":"Reply","ordinal":"2"}"#), [])
        ETest.eq(parse(#"{"action":"click","label":"Reply","ordinal":true}"#), [])
        ETest.eq(parse(#"{"action":"fillField","label":"Name"}"#), [])
        ETest.eq(parse(#"{"action":"fillField","label":"Name","text":"two\nlines"}"#), [], "typed text is single line")
        ETest.eq(parse(#"{"action":"fillField","label":"Name","text":""}"#), [])
        ETest.eq(parse(#"{"action":"describeScreen","question":"a\nb"}"#), [])
        ETest.eq(parse(#"{"action":"describeScreen","question":42}"#), [])
        ETest.eq(parse(#"{"action":"remember","fact":"a\nb"}"#), [], "facts are single line")
        ETest.eq(parse("{\"action\":\"remember\",\"fact\":\"\(String(repeating: "a", count: 501))\"}"), [])
        ETest.eq(parse(#"{"action":"remember"}"#), [])
        ETest.eq(parse(#"{"action":"forget"}"#), [], "forget needs a query")
        ETest.eq(parse(#"{"action":"forget","query":"everything"}"#), [], "never wipe memory by voice")
        ETest.eq(parse(#"{"action":"forget","query":"all my memories"}"#), [])
        ETest.eq(parse(#"{"action":"recall","query":42}"#), [])
        ETest.eq(parse(#"{"action":"draftEmail"}"#), [])
        ETest.eq(parse(#"{"action":"draftEmail","body":"  "}"#), [])
        ETest.eq(parse(#"{"action":"draftEmail","to":"a;b","body":"Hi"}"#), [], "recipient has nothing shell-like")
        ETest.eq(parse(#"{"action":"draftEmail","to":"Kim","subject":"a\nb","body":"Hi"}"#), [], "subject is single line")
        ETest.eq(parse(#"{"action":"draftEmail","to":"Kim","subject":42,"body":"Hi"}"#), [])
        ETest.eq(parse("{\"action\":\"draftEmail\",\"body\":\"\(String(repeating: "a", count: 2_001))\"}"), [])
        ETest.eq(parse(#"{"action":"addNote","text":""}"#), [])
        ETest.eq(parse("{\"action\":\"addNote\",\"text\":\"\(String(repeating: "a", count: 1_001))\"}"), [])
        ETest.eq(parse(#"{"action":"calculate","expression":"open Chrome"}"#), [], "only maths the calculator can answer")
        ETest.eq(parse(#"{"action":"calculate","expression":"2 +"}"#), [])
        ETest.eq(parse(#"{"action":"calculate","expression":"$(whoami)"}"#), [])
        ETest.eq(parse(#"{"action":"calculate"}"#), [])
    }

    private static func hostile() {
        // A model that smuggles a send into an email draft still only drafts: the action set is closed.
        ETest.eq(
            parse(#"{"action":"draftEmail","body":"Hi","send":true,"cc":"evil@x.com"}"#),
            [.draftEmail(to: nil, subject: nil, body: "Hi")]
        )
        ETest.eq(parse(#"{"action":"sendEmail","to":"a@b.com","body":"Hi"}"#), [], "unknown actions are dropped")
        ETest.eq(parse(#"{"action":"runShell","goal":"ls"}"#), [])
        let mixed = RioSmartResponseParser.actions(
            from: #"{"actions":[{"action":"remember","fact":"my pin is 99"},{"action":"click","label":"https://x.com"},{"action":"calculate","expression":"2 plus 2"}]}"#,
            now: now, timeZone: utc
        )
        ETest.eq(mixed, [.remember(fact: "my pin is 99"), .calculate(expression: "2 plus 2")])
    }

    private static func prompt() {
        let system = RioSmartPrompt.system(now: now, timeZone: utc)
        for name in RioSmartResponseParser.allowedActionNames {
            TestSupport.expect(system.contains("\"action\":\"\(name)\""), "prompt must describe every allowed action: \(name)")
        }
        TestSupport.expect(system.contains("never sends"), "the prompt says emails are never sent")
        TestSupport.expect(system.contains("300 characters"), "the prompt states the goal limit")
    }
}
