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
        check("uh so Rio put Chrome on the left", "put Chrome on the left")
        check("I was saying that Rio open Spotify", "open Spotify")
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
        check("Rio's open Chrome", nil)
        check("Oregano and Brio", nil)
    }
}
