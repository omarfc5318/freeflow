import Foundation

/// Screen phrases (builder J): "what's on my screen", click by voice, fill a field, pick a number.
enum RioScreenPhrasesTests {
    private static func parse(_ raw: String) -> RioAction? {
        RioScreenPhrases.parse(raw: raw, simplified: RioText.simplify(raw))
    }

    /// Through the real parser (all builders' phrases), so stealing and being stolen both show up.
    private static func viaParser(_ raw: String) -> RioActionParse {
        RioActionParser(installedApps: []).parse(raw)
    }

    static func run() {
        testDescribe()
        testClicks()
        testChecks()
        testFill()
        testPicks()
        testNotStealing()
        testThroughRealParser()
        testTypeIntoFieldThroughRealParser()
    }

    /// The lead let B's "type …" step aside for "type X into the Y box", so J's fill phrasing wins.
    private static func testTypeIntoFieldThroughRealParser() {
        let parser = RioActionParser(installedApps: [])
        TestSupport.expectEqual(
            parser.parse("type hello into the search box"),
            .actions([.fillField(label: "search box", text: "hello")])
        )
        TestSupport.expectEqual(parser.parse("type hello world"), .actions([.typeText("hello world")]))
        TestSupport.expectEqual(parser.parse("type meet me in the lobby"), .actions([.typeText("meet me in the lobby")]))
    }

    private static func testDescribe() {
        let plain = [
            "what's on my screen", "What is on my screen?", "whats on the screen", "what's on my screen right now",
            "what do you see", "what do you see on my screen", "what am I looking at", "what am I looking at?",
            "describe my screen", "describe the screen", "tell me what's on my screen", "look at my screen",
            "summarize this window", "summarize my screen", "summarize this page", "explain this window",
            "explain my screen", "what's this window", "what is this page", "what's going on on my screen",
        ]
        for input in plain { ETest.eq(parse(input), .describeScreen(question: nil), input) }

        let questions: [(String, String)] = [
            ("what does this error mean", "what does this error mean"),
            ("What does this error say?", "What does this error say"),
            ("what does that warning mean", "what does that warning mean"),
            ("what does this popup mean.", "what does this popup mean"),
            ("what's this error", "what's this error"),
            ("what is the error on my screen", "what is the error on my screen"),
            ("what's the total on this page", "what's the total on this page"),
            ("look at my screen and tell me what the error is", "what the error is"),
            ("look at the screen and what's the price", "what's the price"),
        ]
        for (input, question) in questions { ETest.eq(parse(input), .describeScreen(question: question), input) }
    }

    private static func testClicks() {
        let cases: [(String, String, Int?)] = [
            ("click Send", "Send", nil),
            ("Click send.", "send", nil),
            ("click on Send", "Send", nil),
            ("click the Send button", "Send button", nil),
            ("click the blue Submit button", "blue Submit button", nil),
            ("click the blue button", "blue button", nil),
            ("click the big round blue Next link", "blue Next link", nil),
            ("click the red delete button", "red delete button", nil),
            ("tap Reply", "Reply", nil),
            ("press the Done button", "Done button", nil),
            ("hit the Save button", "Save button", nil),
            ("click the second link", "link", 2),
            ("click on the third Reply button", "Reply button", 3),
            ("click the first tab", "tab", 1),
            ("click the last link", "link", -1),
            ("click the 2nd link", "link", 2),
            ("click number three", "", 3),
            ("click Send please", "Send", nil),
            ("click the Sign in button for me", "Sign in button", nil),
            ("click the plus icon", "plus icon", nil),
            ("click Compose", "Compose", nil),
        ]
        for (input, label, ordinal) in cases {
            ETest.eq(parse(input), .click(label: label, ordinal: ordinal), input)
        }
        for input in ["click", "click the", "click please", "press the button", "tap"] {
            // A bare role word is still a valid target ("press the button" = the only button).
            if input == "press the button" {
                ETest.eq(parse(input), .click(label: "button", ordinal: nil), input)
            } else {
                ETest.eq(parse(input), nil, input)
            }
        }
    }

    private static func testChecks() {
        let cases: [(String, String, Int?)] = [
            ("check remember me", "check remember me", nil),
            ("check the second box", "check checkbox", 2),
            ("check the second checkbox", "check checkbox", 2),
            ("check the I agree box", "check I agree checkbox", nil),
            ("check the remember me checkbox", "check remember me checkbox", nil),
            ("uncheck remember me", "uncheck remember me", nil),
            ("uncheck the first box", "uncheck checkbox", 1),
            ("tick the terms box", "tick terms checkbox", nil),
            ("untick the newsletter checkbox", "untick newsletter checkbox", nil),
            ("check I agree", "check I agree", nil),
            ("click the check box", "checkbox", nil),
            ("click the second check box", "checkbox", 2),
        ]
        for (input, label, ordinal) in cases {
            ETest.eq(parse(input), .click(label: label, ordinal: ordinal), input)
        }
    }

    private static func testFill() {
        let cases: [(String, String, String)] = [
            ("fill the search box with hello world", "search box", "hello world"),
            ("fill in the email field with ali@example.com", "email field", "ali@example.com"),
            ("put hello there in the search box", "search box", "hello there"),
            ("put Doha flights in the search bar.", "search bar", "Doha flights"),
            ("enter 12345 in the zip code field", "zip code field", "12345"),
            ("enter my name into the name box", "name box", "my name"),
            ("type hello into the search box", "search box", "hello"),
            ("type Doha to Dubai into the search bar", "search bar", "Doha to Dubai"),
            ("type hello in the subject field", "subject field", "hello"),
        ]
        for (input, label, text) in cases {
            ETest.eq(parse(input), .fillField(label: label, text: text), input)
        }
        // Not a field: plain dictation and prose stay with the other parsers.
        for input in ["type hello world", "type this into the document", "put it in the oven", "enter the room",
                      "fill the tank", "put the phone in my bag"] {
            ETest.eq(parse(input), nil, input)
        }
    }

    private static func testPicks() {
        let cases: [(String, Int)] = [
            ("the second one", 2), ("second one", 2), ("the first one", 1), ("the third one", 3),
            ("the last one", -1), ("number two", 2), ("number 2", 2), ("option 3", 3),
            ("pick the second one", 2), ("choose number three", 3), ("the second", 2), ("Number one.", 1),
            ("the 2nd one", 2),
        ]
        for (input, ordinal) in cases { ETest.eq(parse(input), .click(label: "", ordinal: ordinal), input) }
        for input in ["two", "one", "second", "3", "the one", "number", "pick one"] {
            ETest.eq(parse(input), nil, input)
        }
    }

    /// Everything other builders own must pass straight through.
    private static func testNotStealing() {
        let others = [
            "open Chrome", "quit Spotify", "press command q", "press return", "press escape", "press command shift 4",
            "hit return", "hit enter", "check my battery", "check the weather", "check my calendar",
            "what's the weather", "what time is it", "what's on my calendar", "what's on my calendar today",
            "what's my battery", "what's in my clipboard", "what did he say", "what do you remember about me",
            "explain this", "summarize this", "explain this error", "summarize it", "read this page",
            "type hello world", "write a poem", "volume up", "put Chrome on the left", "enter full screen",
            "put my phone on silent", "turn on dark mode", "tap three times", "describe yourself",
            "what do you see in me", "what am I doing tomorrow", "what does this word mean",
            "take a screenshot", "show me my screen time", "look at my calendar", "look at the weather",
            "click", "hit it", "press play", "press the play button",
        ]
        for input in others {
            let action = parse(input)
            // A few are claimed on purpose (press the play button is a click); none may be a screen action
            // other than the explicit ones.
            if input == "press the play button" {
                ETest.eq(action, .click(label: "play button", ordinal: nil), input)
            } else {
                ETest.eq(action, nil, "screen parser must not claim: \(input)")
            }
        }
    }

    private static func testThroughRealParser() {
        let click = viaParser("Rio, click the blue Submit button")
        ETest.eq(click, .actions([.click(label: "blue Submit button", ordinal: nil)]), "real parser click")
        ETest.eq(viaParser("click Send"), .actions([.click(label: "Send", ordinal: nil)]), "real parser click Send")
        ETest.eq(viaParser("what's on my screen"), .actions([.describeScreen(question: nil)]), "real parser describe")
        ETest.eq(viaParser("what does this error mean"),
                 .actions([.describeScreen(question: "what does this error mean")]), "real parser error")
        ETest.eq(viaParser("check the second box"), .actions([.click(label: "check checkbox", ordinal: 2)]), "real parser check")
        ETest.eq(viaParser("the second one"), .actions([.click(label: "", ordinal: 2)]), "real parser pick")
        ETest.eq(viaParser("fill the search box with hello"),
                 .actions([.fillField(label: "search box", text: "hello")]), "real parser fill")
        // Others still win their own phrasings.
        ETest.eq(viaParser("press command q"),
                 .actions([.pressKeys(KeyCombo(key: "q", command: true, shift: false, option: false, control: false))]),
                 "press command q stays keyboard")
        ETest.eq(viaParser("type hello world"), .actions([.typeText("hello world")]), "type stays typing")
    }
}
