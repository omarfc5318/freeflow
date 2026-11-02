import Foundation

/// Which traditional look Rio wears on the dictation pill for the spoken language.
enum SpokenLookTests {
    static func run() {
        testLanguageCodes()
        testArabicTranscript()
        testUrduTranscript()
        testHindiTranscript()
        testEnglishAndMixedTranscripts()
        testEmptyTranscript()
        testRecordingStart()
    }

    private static func check(
        _ actual: SpokenLook?, _ expected: SpokenLook?, _ message: String, line: UInt = #line
    ) {
        TestSupport.expect(
            actual == expected,
            "\(message): expected \(String(describing: expected)), got \(String(describing: actual))",
            line: line
        )
    }

    private static func testLanguageCodes() {
        check(SpokenLook.forLanguage("ar"), .shemagh, "Arabic code gets the shemagh")
        check(SpokenLook.forLanguage(" Arabic "), .shemagh, "Whisper's language name works too")
        check(SpokenLook.forLanguage("hi"), .turban, "Hindi gets the turban")
        check(SpokenLook.forLanguage("urdu"), .turban, "Urdu gets the turban")
        check(SpokenLook.forLanguage("en"), nil, "English has no special look")
        check(SpokenLook.forLanguage(""), nil, "Auto-detect has no special look")
    }

    private static func testArabicTranscript() {
        check(SpokenLook.detect(in: "السلام عليكم، كيف حالك اليوم؟"), .shemagh, "Arabic script reads as Arabic")
        check(SpokenLook.detect(in: "ابغى اروح Starbucks بعد الدوام"), .shemagh, "Arabic with an English brand is still Arabic")
    }

    private static func testUrduTranscript() {
        check(SpokenLook.detect(in: "آپ کیسے ہیں؟ میں ٹھیک ہوں"), .turban, "Urdu-only letters tell Urdu from Arabic")
    }

    private static func testHindiTranscript() {
        check(SpokenLook.detect(in: "नमस्ते, आप कैसे हैं?"), .turban, "Devanagari reads as Hindi")
    }

    private static func testEnglishAndMixedTranscripts() {
        check(SpokenLook.detect(in: "Send the deck to the team tonight"), SpokenLook.none, "English gets the normal outfit")
        check(
            SpokenLook.detect(in: "Tell Omar that the meeting with محمد moved to Thursday afternoon"),
            SpokenLook.none,
            "One Arabic name in English stays English"
        )
    }

    private static func testEmptyTranscript() {
        check(SpokenLook.detect(in: ""), nil, "No text gives no signal")
        check(SpokenLook.detect(in: "123 !?"), nil, "Digits and punctuation give no signal")
    }

    private static func testRecordingStart() {
        check(
            SpokenLook.atRecordingStart(selectedLanguage: "ar", lastDetected: SpokenLook.none),
            .shemagh,
            "Arabic picked in Settings shows the shemagh from the first word"
        )
        check(
            SpokenLook.atRecordingStart(selectedLanguage: "", lastDetected: .turban),
            .turban,
            "Auto-detect starts with the last dictation's language"
        )
        check(
            SpokenLook.atRecordingStart(selectedLanguage: "en", lastDetected: .shemagh),
            .shemagh,
            "A language without a look falls back to the last dictation"
        )
    }
}
