import Foundation

enum WakePhraseExtractorTests {
    private static func check(_ transcript: String, _ expected: String?, line: UInt = #line) {
        TestSupport.expectEqual(WakePhraseExtractor.command(in: transcript), expected, line: line)
    }

    static func run() {
        testBasic()
        testPartialResultsGrowing()
        testNameVariants()
        testGreetings()
        testNameMidSentence()
        testNoNameYieldsNothing()
        testNameAloneYieldsNothing()
        testPunctuationAndCase()
        testRepeatedName()
        testNotANameInsideAWord()
        testPlaceNames()
        testLooseNames()
        testPausesBeforeName()
        testBareName()
        testTiming()
        testTalkingAboutRio()
        testNaturalLeadInsAndSpellings()
    }

    /// Finding 70: TV or room audio about Rio the film, the footballer or the parrot.
    private static func testTalkingAboutRio() {
        check("Rio is a 2011 animated film", nil)
        check("Rio was released in 2011", nil)
        check("Rio 2 came out in 2014", nil)
        check("Rio 2 is my favorite movie", nil)
        check("Rio Ferdinand scored a goal", nil)
        check("Rio the parrot is so cute", nil)
        check("Rio the movie is great", nil)
        check("Rio has a great soundtrack", nil)
        // Still commands: a command word, a question to Rio, or the name set off by a comma.
        check("Rio is it going to rain today", "is it going to rain today")
        check("Rio, is there a meeting at 3", "is there a meeting at 3")
        check("Rio has my package arrived", "has my package arrived")
        check("Rio Open Chrome", "Open Chrome")
        check("Rio, Spotify next song", "Spotify next song")
        check("Rio, 5 minute timer", "5 minute timer")
        check("Rio I need help", "I need help")
        check("Rio I'm cold", "I'm cold")
        check("RIO OPEN CHROME", "OPEN CHROME")
        check("Rio play the next song", "play the next song")
    }

    /// Finding 77.
    private static func testNaturalLeadInsAndSpellings() {
        check("please Rio open Chrome", "open Chrome")
        check("Ria, how's the weather", "how's the weather")
        check("Ria hows the weather", "hows the weather")
        check("Ria where's my phone", "where's my phone")
        // Unchanged: the name at the end, or mid-sentence.
        check("can you open Chrome Rio", nil)
        check("please tell Rio to open Chrome", nil)
    }

    private static func testPlaceNames() {
        check("Rio de Janeiro is beautiful this time of year", nil)
        check("Rio Grande valley weather", nil)
        check("rio tinto shares are up", nil)
        check("Rio do this for me", "do this for me")
        check("Rio, define grande", "define grande")
    }

    private static func testLooseNames() {
        check("Ria open chrome", "open chrome")
        check("Ria what's the weather", "what's the weather")
        check("Rhea open chrome", "open chrome")
        check("Rios open chrome", "open chrome")
        check("Rio's open Chrome", "open Chrome")
        check("Ria, open warp.", "open warp.")
        check("hey Ria open notes", "open notes")
        // Not before a command word, or not at the start: someone's name, or the place.
        check("Ria is my sister", nil)
        check("Rio's beaches", nil)
        check("I called Ria open the door", nil)
        check("Rhea", nil)
    }

    private static func testPausesBeforeName() {
        typealias W = WakePhraseExtractor.TimedWord
        let paused = [W(text: "oh", start: 0.2, duration: 0.2), W(text: "my", start: 0.4, duration: 0.2),
                      W(text: "god", start: 0.6, duration: 0.3), W(text: "Rio", start: 1.8, duration: 0.3),
                      W(text: "help", start: 2.2, duration: 0.3)]
        TestSupport.expectEqual(WakePhraseExtractor.command(in: paused), "help")
        // No pause: still someone talking about Rio.
        let told = [W(text: "I", start: 0.1, duration: 0.1), W(text: "told", start: 0.2, duration: 0.2),
                    W(text: "Rio", start: 0.45, duration: 0.2), W(text: "to", start: 0.7, duration: 0.1),
                    W(text: "open", start: 0.8, duration: 0.2), W(text: "Chrome", start: 1.0, duration: 0.3)]
        TestSupport.expectEqual(WakePhraseExtractor.command(in: told), nil)
        // Without timing (all zero) nothing new is accepted.
        let untimed = ["dude", "Rio", "quit", "Stickies"].map { W(text: $0, start: 0, duration: 0) }
        TestSupport.expectEqual(WakePhraseExtractor.command(in: untimed), nil)
        // A pause inside the command is kept as a space.
        let long = [W(text: "Rio", start: 0.1, duration: 0.3), W(text: "text", start: 0.5, duration: 0.2),
                    W(text: "mom", start: 0.7, duration: 0.2), W(text: "that", start: 0.9, duration: 0.2),
                    W(text: "I'm", start: 2.4, duration: 0.2), W(text: "late", start: 2.6, duration: 0.2)]
        TestSupport.expectEqual(WakePhraseExtractor.command(in: long), "text mom that I'm late")
    }

    private static func testBareName() {
        TestSupport.expect(WakePhraseExtractor.isBareName("Rio"), "bare Rio")
        TestSupport.expect(WakePhraseExtractor.isBareName("hey Rio"), "hey Rio")
        TestSupport.expect(WakePhraseExtractor.isBareName("Rio Rio"), "Rio Rio")
        TestSupport.expect(!WakePhraseExtractor.isBareName("Rio open"), "Rio open")
        TestSupport.expect(!WakePhraseExtractor.isBareName("I like Rio"), "mid sentence")
        TestSupport.expect(!WakePhraseExtractor.isBareName(""), "empty")
    }

    private static func testTiming() {
        TestSupport.expectEqual(WakeListenTiming.silenceToEnd(pendingCommand: nil), WakeListenTiming.silenceWithoutCommand)
        TestSupport.expectEqual(WakeListenTiming.silenceToEnd(pendingCommand: "open Chrome"), WakeListenTiming.silenceAfterCommand)
        TestSupport.expectEqual(
            WakeListenTiming.silenceToEnd(pendingCommand: "text my mom that"), WakeListenTiming.silenceAfterUnfinishedCommand
        )
        TestSupport.expect(WakeListenTiming.silenceAfterCommand > WakeListenTiming.silenceWithoutCommand, "longer once a command started")
        // Finding 88: a bare "Rio" opens the command window only when Rio is not talking.
        TestSupport.expect(!WakeListenTiming.bareNameOpensWindow(isRioSpeaking: true, secondsSinceRioSpoke: nil), "while talking")
        TestSupport.expect(!WakeListenTiming.bareNameOpensWindow(isRioSpeaking: false, secondsSinceRioSpoke: 1), "echo tail")
        TestSupport.expect(WakeListenTiming.bareNameOpensWindow(isRioSpeaking: false, secondsSinceRioSpoke: 10), "later")
        TestSupport.expect(WakeListenTiming.bareNameOpensWindow(isRioSpeaking: false, secondsSinceRioSpoke: nil), "never spoke")

        // Finding 94: fast for the first few empty finals, then backing off to 5 s at most.
        let delays = (1...8).map { WakeListenTiming.emptyFinalDelay(consecutive: $0) }
        TestSupport.expectEqual(delays, [0.25, 0.5, 0.5, 2, 4, 5, 5, 5])
        TestSupport.expectEqual(WakeListenTiming.emptyFinalDelay(consecutive: 0), 0.25)
        TestSupport.expectEqual(WakeListenTiming.emptyFinalDelay(consecutive: 1000), WakeListenTiming.maxEmptyFinalDelay)

        // One loud buffer (a key click) never wakes the listener early; sustained sound does.
        var gate = WakeSoundGate()
        TestSupport.expect(!gate.feed(rms: 0.2, seconds: 0.02), "one loud buffer")
        TestSupport.expect(!gate.feed(rms: 0.001, seconds: 0.02), "silence resets the run")
        TestSupport.expect(!gate.feed(rms: 0.2, seconds: 0.05), "loud again, too short")
        TestSupport.expect(!gate.feed(rms: 0.2, seconds: 0.05), "still too short")
        TestSupport.expect(gate.feed(rms: 0.2, seconds: 0.05), "sustained sound")
        var quiet = WakeSoundGate()
        TestSupport.expect(!(0..<100).contains { _ in quiet.feed(rms: 0.01, seconds: 0.02) }, "a quiet fan never counts")
    }

    private static func testBasic() {
        check("Rio open Chrome", "open Chrome")
        check("rio put chrome on the left", "put chrome on the left")
        check("Rio, open Chrome.", "open Chrome.")
        check("Rio: volume up", "volume up")
    }

    private static func testPartialResultsGrowing() {
        let partials = ["Rio", "Rio open", "Rio open Chr", "Rio open Chrome"]
        let results = partials.map { WakePhraseExtractor.command(in: $0) }
        TestSupport.expectEqual(results[0], nil)
        TestSupport.expectEqual(results[1], "open")
        TestSupport.expectEqual(results[2], "open Chr")
        TestSupport.expectEqual(results[3], "open Chrome")
    }

    private static func testNameVariants() {
        check("Ryo open Chrome", "open Chrome")
        check("Reo open Chrome", "open Chrome")
        check("Rhio open Chrome", "open Chrome")
        check("Riyo lock my screen", "lock my screen")
    }

    private static func testGreetings() {
        check("Hey Rio open Chrome", "open Chrome")
        check("hey, Rio, open Chrome", "open Chrome")
        check("Hey Ryo what's the weather", "what's the weather")
        check("Yo Rio mute", "mute")
        check("Yorio mute", "mute")
        check("hey Rio", nil)
    }

    private static func testNameMidSentence() {
        // Fillers and a greeting may lead; the name must still start the utterance.
        check("uh so Rio put Chrome on the left", "put Chrome on the left")
        check("okay Rio open Spotify", "open Spotify")
        // Security: the name anywhere else is someone talking about Rio, or a video.
        check("I was saying that Rio open Spotify", nil)
        check("please tell Rio to open Chrome", nil)
        check("the bear is called Rio lock my screen", nil)
        // A new sentence counts as a fresh start.
        check("that was great. Rio open Spotify", "open Spotify")
        check("that was great Rio open Spotify", nil)
    }

    private static func testNoNameYieldsNothing() {
        check("open Chrome please", nil)
        check("", nil)
        check("   \n ", nil)
        check("hey there", nil)
    }

    private static func testNameAloneYieldsNothing() {
        check("Rio", nil)
        check("Rio.", nil)
        check("Rio,", nil)
        check("  rio  ", nil)
        // Name at the very end: nothing after it.
        check("open Chrome Rio", nil)
    }

    private static func testPunctuationAndCase() {
        check("RIO OPEN CHROME", "OPEN CHROME")
        check("Rio - open Chrome", "open Chrome")
        check("Rio...  open Chrome", "open Chrome")
        check("Rio,\nopen Chrome", "open Chrome")
    }

    private static func testRepeatedName() {
        check("Rio Rio open Chrome", "open Chrome")
        check("Hey Rio, Rio open Chrome", "open Chrome")
        check("Rio Rio", nil)
    }

    private static func testNotANameInsideAWord() {
        check("Mario open Chrome", nil)
        check("Riot open Chrome", nil)
        check("Rio's beaches are nice", nil)
        check("Oregano and Brio", nil)
    }
}
