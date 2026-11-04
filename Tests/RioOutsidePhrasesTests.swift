import Foundation

/// Weather, news, music, Notion and Canvas phrases (builder S), including "never steal" checks.
enum RioOutsidePhrasesTests {
    private static func parse(_ text: String) -> RioAction? {
        RioOutsidePhrases.parse(raw: text, simplified: RioText.simplify(text))
    }

    static func run() {
        weather()
        news()
        music()
        notion()
        canvas()
        notStealing()
        throughTheRealParser()
    }

    private static func check(_ cases: [(String, RioAction)]) {
        for (text, expected) in cases {
            TestSupport.expectEqual(parse(text), expected, file: #filePath, line: #line)
        }
    }

    private static func weather() {
        check([
            ("what's the weather", .weather(place: nil)),
            ("weather", .weather(place: nil)),
            ("What's the weather like today?", .weather(place: nil)),
            ("how's the weather", .weather(place: nil)),
            ("what's the weather in Davis", .weather(place: "Davis")),
            ("weather in San Francisco", .weather(place: "San Francisco")),
            ("how's the weather in Doha Qatar", .weather(place: "Doha Qatar")),
            ("what's the weather like in Dubai tomorrow", .weather(place: "Dubai")),
            ("is it going to rain", .weather(place: nil)),
            ("will it rain in Davis", .weather(place: "Davis")),
            ("do I need an umbrella", .weather(place: nil)),
            ("what's the temperature outside", .weather(place: nil)),
            ("what's the forecast", .weather(place: nil)),
            ("forecast for Seattle", .weather(place: "Seattle")),
        ])
    }

    private static func news() {
        check([
            ("what's the news", .news(topic: nil)),
            ("what's in the news", .news(topic: nil)),
            ("tell me the news", .news(topic: nil)),
            ("read me the headlines", .news(topic: nil)),
            ("news about AI", .news(topic: "AI")),
            ("what's the latest news on Qatar", .news(topic: "Qatar")),
            ("any news on the election", .news(topic: "the election")),
        ])
    }

    private static func music() {
        check([
            ("play Blinding Lights", .playMusic(query: "Blinding Lights")),
            ("Play Blinding Lights on Spotify.", .playMusic(query: "Blinding Lights")),
            ("play some jazz", .playMusic(query: "jazz")),
            ("play Taylor Swift on Apple Music", .playMusic(query: "Taylor Swift")),
            ("play the song Blinding Lights", .playMusic(query: "Blinding Lights")),
            ("listen to lo fi beats", .playMusic(query: "lo fi beats")),
            ("play Blinding Lights by The Weeknd", .playMusic(query: "Blinding Lights by The Weeknd")),
        ])
    }

    private static func notion() {
        check([
            ("add buy milk to Notion", .notionAdd(text: "buy milk", page: nil)),
            ("Add Buy milk to my Notion.", .notionAdd(text: "Buy milk", page: nil)),
            ("put call mom in Notion", .notionAdd(text: "call mom", page: nil)),
            ("add finish the essay to my tasks page in Notion", .notionAdd(text: "finish the essay", page: "tasks")),
            ("save build a bear to the ideas page in Notion", .notionAdd(text: "build a bear", page: "ideas")),
            ("add to Notion: read chapter four", .notionAdd(text: "read chapter four", page: nil)),
            ("jot down check visa dates in Notion", .notionAdd(text: "check visa dates", page: nil)),
        ])
    }

    private static func canvas() {
        check([
            ("what's due on Canvas", .canvasDue(range: nil)),
            ("check my Canvas assignments", .canvasDue(range: nil)),
            ("what's due this week", .canvasDue(range: "this week")),
            ("what assignments are due tomorrow", .canvasDue(range: "tomorrow")),
            ("do I have any homework due today", .canvasDue(range: "today")),
            ("what's due next week on Canvas", .canvasDue(range: "next week")),
            ("any assignments due", .canvasDue(range: nil)),
        ])
    }

    private static let leftAlone = [
        "open Chrome", "open Notion", "open Canvas", "open Spotify", "what's on my calendar", "what's next",
        "set a timer for 5 minutes", "volume up", "next song", "play", "pause", "play it", "play that",
        "play the next song", "play the video", "play the video on YouTube", "play the game", "search for best pizza",
        "what's on my screen", "text Ali I'm late", "what time is it", "add milk to my shopping list",
        "add study session tomorrow at 7 pm", "find my resume", "what's the battery", "remind me to buy milk",
        "remember my wifi password is hunter2", "what's my next class", "what's on my clipboard",
        "how do I add a page in Word", "weather app", "play pause", "news app",
    ]

    private static func notStealing() {
        for text in leftAlone {
            TestSupport.expect(parse(text) == nil, "Outside phrases must not claim: \(text) -> \(String(describing: parse(text)))")
        }
    }

    private static func throughTheRealParser() {
        let parser = RioActionParser(installedApps: [])
        TestSupport.expectEqual(parser.parse("Rio, what's the weather in Davis?"), .actions([.weather(place: "Davis")]))
        TestSupport.expectEqual(parser.parse("play Blinding Lights on Spotify"), .actions([.playMusic(query: "Blinding Lights")]))
        TestSupport.expectEqual(parser.parse("what's due on Canvas"), .actions([.canvasDue(range: nil)]))
        TestSupport.expectEqual(parser.parse("add buy milk to Notion"), .actions([.notionAdd(text: "buy milk", page: nil)]))
        TestSupport.expectEqual(parser.parse("what's the news about AI"), .actions([.news(topic: "AI")]))
        TestSupport.expectEqual(parser.parse("play"), .actions([.media(.playPause)]))
        TestSupport.expectEqual(parser.parse("next song"), .actions([.media(.next)]))
        TestSupport.expectEqual(parser.parse("what's on my clipboard"), .actions([.clipboard(.readCurrent)]))
    }
}
