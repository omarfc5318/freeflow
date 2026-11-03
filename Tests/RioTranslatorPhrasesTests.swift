import Foundation

/// Translator phrases, the direction rules and the language list.
enum RioTranslatorPhrasesTests {
    private static func parse(_ raw: String) -> RioAction? {
        RioTranslatorPhrases.parse(raw: raw, simplified: RioText.simplify(raw))
    }

    static func run() {
        testStart()
        testStop()
        testSay()
        testNotStealing()
        testThroughRealParser()
        testLanguages()
        testDirection()
    }

    private static func testStart() {
        let phrases = [
            "translate what is being said", "Translate what's being said.", "translate what they're saying",
            "translate what he is saying", "translate what people are saying", "translate everything",
            "translate the conversation", "translate this conversation", "translate the room",
            "translate", "start translating", "start translation", "begin translating", "turn on translator mode",
            "translator mode", "translator mode on", "live translation", "live translate",
            "enable live translation", "be my translator", "interpret for me", "translate for me",
            "translate what is being said to Arabic", "please translate what is being said",
            "translate what they say", "translate what im hearing", "translate what i hear",
        ]
        for phrase in phrases {
            TestSupport.expectEqualNamed(parse(phrase), .startTranslation, phrase)
        }
    }

    private static func testStop() {
        let phrases = [
            "stop translating", "Stop translating.", "stop translation", "end translation", "turn off translator mode",
            "translator mode off", "stop the translator", "stop interpreting", "disable live translation",
            "that's enough translating", "no more translating", "cancel translation", "exit translator mode",
        ]
        for phrase in phrases {
            TestSupport.expectEqualNamed(parse(phrase), .stopTranslation, phrase)
        }
    }

    private static func testSay() {
        let phrases = [
            "say it", "say that", "say it out loud", "say that out loud", "say it again", "say the translation",
            "speak the translation", "say it aloud", "say the last translation",
        ]
        for phrase in phrases {
            TestSupport.expectEqualNamed(parse(phrase), .speakLastTranslation, phrase)
        }
    }

    private static func testNotStealing() {
        // E's selection task and everything else that merely sounds close stays unclaimed.
        let unclaimed = [
            "translate this to French", "translate that into Arabic", "translate it in Spanish",
            "translate to Arabic", "translate the selection to French", "translate the selected text into German",
            "open Chrome", "stop", "stop the music", "stop listening", "stop the timer", "say hello", "say hello to Ali",
            "read that aloud", "what did he say", "translate this", "translate that email",
            "translate this page to Arabic", "how do you say thanks in Arabic", "volume up", "mute",
            "start a timer for five minutes", "start recording", "stop talking",
        ]
        for phrase in unclaimed {
            TestSupport.expectEqualNamed(parse(phrase), nil, phrase)
        }
    }

    private static func testThroughRealParser() {
        let parser = RioActionParser(installedApps: [])
        TestSupport.expectEqual(parser.parse("Rio, translate what is being said"), .actions([.startTranslation]))
        TestSupport.expectEqual(parser.parse("Rio stop translating"), .actions([.stopTranslation]))
        TestSupport.expectEqual(parser.parse("hey Rio say it"), .actions([.speakLastTranslation]))
        TestSupport.expectEqual(
            parser.parse("Rio translate this to French"), .actions([.selectionTask(.translate(language: "French"))])
        )
    }

    private static func testLanguages() {
        TestSupport.expectEqual(RioTranslatorLanguage.named("Arabic"), .arabic)
        TestSupport.expectEqual(RioTranslatorLanguage.named("ar"), .arabic)
        TestSupport.expectEqual(RioTranslatorLanguage.named(" arabic "), .arabic)
        TestSupport.expectEqual(RioTranslatorLanguage.named("english"), .english)
        TestSupport.expectEqual(RioTranslatorLanguage.named("French")?.code, "fr")
        TestSupport.expectEqual(RioTranslatorLanguage.named("fr")?.voiceLocale, "fr-FR")
        TestSupport.expectEqual(RioTranslatorLanguage.named("Hindi")?.code, "hi")
        TestSupport.expect(RioTranslatorLanguage.named("klingon") == nil, "unknown language")
        TestSupport.expect(RioTranslatorLanguage.named(nil) == nil, "nil language")
        TestSupport.expect(!RioTranslatorLanguage.all.contains(.english), "english is not an 'other language'")
        TestSupport.expect(RioTranslatorLanguage.all.contains(.arabic), "arabic is offered")
    }

    private static func testDirection() {
        let arabic = RioTranslatorLanguage.arabic
        let french = RioTranslatorLanguage.named("French")!
        func route(_ language: String?, _ text: String, _ other: RioTranslatorLanguage = arabic) -> RioTranslationRoute {
            RioTranslationDirection.route(detected: language, text: text, other: other)
        }
        // Non-English becomes English.
        TestSupport.expectEqual(route("arabic", "مرحبا كيف حالك"), .translate(from: "arabic", to: .english))
        TestSupport.expectEqual(route("ar", "مرحبا"), .translate(from: "ar", to: .english))
        TestSupport.expectEqual(route("french", "bonjour"), .translate(from: "french", to: .english))
        TestSupport.expectEqual(route("hindi", "namaste"), .translate(from: "hindi", to: .english))
        // English goes to the owner's other language.
        TestSupport.expectEqual(route("english", "where is the station"), .translate(from: "english", to: arabic))
        TestSupport.expectEqual(route("en", "hello", french), .translate(from: "en", to: french))
        // The other language itself still goes to English.
        TestSupport.expectEqual(route("french", "bonjour", french), .translate(from: "french", to: .english))
        // No detected language: the script decides.
        TestSupport.expectEqual(route(nil, "where is the station"), .translate(from: nil, to: arabic))
        TestSupport.expectEqual(route(nil, "كيف حالك"), .translate(from: nil, to: .english))
        // Nothing worth translating.
        TestSupport.expectEqual(route("english", "  "), .skip)
        TestSupport.expectEqual(route("english", "..."), .skip)
        TestSupport.expectEqual(route(nil, ""), .skip)
        // A misconfigured "other language" of English falls back to Arabic.
        TestSupport.expectEqual(route("english", "hello", .english), .translate(from: "english", to: arabic))
    }
}
