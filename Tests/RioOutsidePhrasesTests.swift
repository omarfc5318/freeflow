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
            // The LLM's English for "ريو كم درجة الحرارة في الدوحة", and other place-first wordings.
            ("What's the temperature in Doha?", .weather(place: "Doha")),
            ("temperature in Doha tomorrow", .weather(place: "Doha")),
            ("what's the temperature like in Davis today", .weather(place: "Davis")),
            ("how hot is it in Doha", .weather(place: "Doha")),
            ("how cold is it in Davis right now", .weather(place: "Davis")),
            ("how hot is it outside", .weather(place: nil)),
            ("what's the temperature", .weather(place: nil)),
            ("what's the forecast like in Dubai", .weather(place: "Dubai")),
        ])
        for notWeather in ["what's the temperature in Fahrenheit", "temperature of the oven", "how hot is it in here", "temp folder"] {
            TestSupport.expect(parse(notWeather) == nil, "not a weather question: \(notWeather) -> \(String(describing: parse(notWeather)))")
        }
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
        // A replay is not a song called "that again".
        for replay in ["play that again", "Rio, play that again.", "play it again", "play this again", "play that song again",
                       "play it one more time", "play that one again"] {
            let text = RioActionParser.stripEnvelope(replay)
            TestSupport.expect(parse(text) == nil, "replay is not a search: \(replay) -> \(String(describing: parse(text)))")
        }
        TestSupport.expectEqual(RioSpotifyLink.safeURL("spotify:track:4uLU6hMCjMI75M1A2tKUQC")?.absoluteString, "spotify:track:4uLU6hMCjMI75M1A2tKUQC")
        TestSupport.expectEqual(RioSpotifyLink.safeURL("spotify:playlist:37i9dQZF1DXcBWIGoYBM5M")?.scheme, "spotify")
        for unsafe in ["file:///Applications/Calculator.app", "https://evil.example/x", "spotify:track:../../etc", "javascript:alert(1)",
                       "spotify:user:abc", "spotify:track:abc def", "x-apple.systempreferences:com.apple.preference", ""] {
            TestSupport.expect(RioSpotifyLink.safeURL(unsafe) == nil, "unsafe Spotify URI must be refused: \(unsafe)")
        }
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
            // The course named filters what's read out.
            ("rio, whats due for mat108", .canvasDue(range: "MAT108")),
            ("when is my ECS119 homework due?", .canvasDue(range: "ECS119")),
            ("what's due on canvas for MAT108?", .canvasDue(range: "MAT108")),
            ("what's due next week for ECS 119?", .canvasDue(range: "next week ECS119")),
            ("is homework 6 due tomorrow", .canvasDue(range: "tomorrow")),
            ("when is quiz 3 due", .canvasDue(range: nil)),
        ])
        // "open/check Canvas" opens the owner's own Canvas, never a generic one.
        let savedBase = RioCanvasConfig.configuredText
        defer { RioCanvasConfig.configuredText = savedBase }
        RioCanvasConfig.configuredText = { "" }
        let ucd = URL(string: "https://canvas.ucdavis.edu")!
        for phrase in ["open Canvas", "Open canvas.", "check canvas", "go to Canvas", "open Canvas for me", "pull up my canvas"] {
            TestSupport.expectEqual(parse(phrase), .openURL(ucd), file: #filePath, line: #line)
        }
        RioCanvasConfig.configuredText = { "canvas.example.edu" }
        TestSupport.expectEqual(parse("open canvas"), .openURL(URL(string: "https://canvas.example.edu")!))
        RioCanvasConfig.configuredText = { "http://insecure.example.edu" }
        TestSupport.expectEqual(parse("open canvas"), .openURL(ucd))
        RioCanvasConfig.configuredText = { "" }
        let parser = RioActionParser(installedApps: [])
        TestSupport.expectEqual(parser.parse("Rio open canvas."), .actions([.openURL(ucd)]))
        TestSupport.expectEqual(parser.parse("Rio, open Canvas for me"), .actions([.openURL(ucd)]))
        TestSupport.expectEqual(parser.parse("check my canvas assignments"), .actions([.canvasDue(range: nil)]))
    }

    private static let leftAlone = [
        "open Chrome", "open Notion", "open Spotify", "what's on my calendar", "what's next",
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
        TestSupport.expectEqual(parser.parse("play"), .actions([.media(.play)]))
        TestSupport.expectEqual(parser.parse("next song"), .actions([.media(.next)]))
        TestSupport.expectEqual(parser.parse("what's on my clipboard"), .actions([.clipboard(.readCurrent)]))
    }
}
