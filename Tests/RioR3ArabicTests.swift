import Foundation

/// Round 3 (arabic-translator-outside): the live translator from any phrasing, contacts saved in
/// Arabic, settings panes, Google as a search site, Arabic padding around English commands,
/// study content that isn't music, player names on pause/resume, Canvas questions without "due",
/// homework time words and the offline table's spelling and lead-in fixes.
enum RioR3ArabicTests {
    private static let apps = ["Google Chrome", "Safari", "Spotify", "Slack", "Zoom", "Calculator", "YouTube"].map {
        InstalledApp(name: $0, bundleIdentifier: nil, url: URL(fileURLWithPath: "/Applications/\($0).app"))
    }

    static func run() {
        testLiveTranslatorEnglish()
        testLiveTranslatorArabic()
        testArabicContactNames()
        testSettingsPanes()
        testGoogleSearch()
        testArabicPaddingAroundEnglish()
        testStudyContentIsNotMusic()
        testPlayerNames()
        testCanvasWithoutDue()
        testHomeworkTimeWords()
        testTableSpellingAndLeadIn()
    }

    private static func table(_ text: String) -> String? { RioArabicCommandTable.english(for: text) }

    private static func expectTable(_ cases: [(String, String?)], line: UInt = #line) {
        for (input, expected) in cases {
            TestSupport.expectEqualNamed(table(input), expected, input, line: line)
        }
    }

    private static func parse(_ text: String) -> RioActionParse {
        RioActionParser(installedApps: apps).parse(text)
    }

    private static func parsedArabic(_ input: String) -> RioActionParse? {
        guard let text = table(input) else { return nil }
        return parse(RioActionTranscript.stripName(from: text))
    }

    private static func translatorPhrase(_ raw: String) -> RioAction? {
        RioTranslatorPhrases.parse(raw: raw, simplified: RioText.simplify(raw))
    }

    // MARK: Finding 48

    private static func testLiveTranslatorEnglish() {
        for phrase in [
            "translate what the doctor is saying", "translate what he says", "translate everything they say",
            "translate the lecture", "translate the video", "translate the meeting", "translate this call",
            "translate what my professor said", "translate what this guy is saying", "translate everything the teacher says",
            "translate what the doctor is saying to Arabic", "translate for me what she says", "translate the class",
        ] {
            TestSupport.expectEqualNamed(translatorPhrase(phrase), .startTranslation, phrase)
        }
        // Text on screen, a selection, or what Rio or the owner said: not the live microphone.
        for phrase in [
            "translate what this says", "translate what the email says", "translate what it says to French",
            "translate what I said", "translate what you said", "translate what the message says",
            "translate what this paragraph says", "translate this page to Arabic", "translate that email",
            "translate this to French",
        ] {
            TestSupport.expectEqualNamed(translatorPhrase(phrase), nil, phrase)
        }
        TestSupport.expectEqual(parse("Rio, translate what the doctor is saying"), .actions([.startTranslation]))
        TestSupport.expectEqual(parse("Rio translate the lecture"), .actions([.startTranslation]))
    }

    private static func testLiveTranslatorArabic() {
        expectTable([
            ("ريو ترجم لي وش يقول الدكتور", "Rio translate what is being said"),
            ("ريو ترجم لي المحاضرة", "Rio translate what is being said"),
            ("ريو ترجم الفيديو", "Rio translate what is being said"),
            ("ترجم اللي اسمعه", "translate what is being said"),
            ("ترجم وش قاعد يقول", "translate what is being said"),
            ("ترجم هالمحاضرة", "translate what is being said"),
            // Unchanged: a message, text on screen, "this" text.
            ("ترجم وش يقول احمد في الرسالة", nil),
            ("ترجم وش يقول الايميل", nil),
            ("ترجم كلام احمد", nil),
            ("ترجم هالكلام", "translate this to English"),
        ])
        TestSupport.expectEqualNamed(parsedArabic("ريو ترجم لي وش يقول الدكتور"), .actions([.startTranslation]), "doctor")
    }

    // MARK: Finding 49

    private static func card(_ given: String, _ family: String = "", nickname: String = "", phone: String = "+97455500001") -> RioContactCandidate {
        RioContactCandidate(
            fullName: [given, family].filter { !$0.isEmpty }.joined(separator: " "), givenName: given, familyName: family,
            nickname: nickname, phones: [RioContactPhone(label: "mobile", number: phone)], emails: []
        )
    }

    private static func testArabicContactNames() {
        let mom = card("Mom", phone: "+97455500002")
        let walida = card("الوالدة", phone: "+97455500003")
        let ahmed = card("أحمد", "علي")
        TestSupport.expectEqual(RioContactChooser.choose(spoken: "أمي", from: [mom, ahmed]), .match(name: "Mom", handle: "+97455500002"))
        TestSupport.expectEqual(RioContactChooser.choose(spoken: "Mom", from: [walida, ahmed]), .match(name: "الوالدة", handle: "+97455500003"))
        // Both scripts saved: the user picks, never a silent guess.
        TestSupport.expectEqual(RioContactChooser.choose(spoken: "أمي", from: [mom, walida]), .ambiguous(["Mom", "الوالدة"].sorted()))
        // The card saved under the spoken word wins outright.
        let ummi = card("أمي", phone: "+97455500004")
        TestSupport.expectEqual(RioContactChooser.choose(spoken: "أمي", from: [mom, ummi]), .match(name: "أمي", handle: "+97455500004"))
        // Hamza spelled or not.
        TestSupport.expectEqual(RioContactChooser.choose(spoken: "احمد", from: [ahmed, mom]), .match(name: "أحمد علي", handle: "+97455500001"))
        TestSupport.expectEqual(RioContactChooser.choose(spoken: "Ahmed", from: [ahmed]), .notFound)
        // The name kept in Arabic reaches the message as said.
        TestSupport.expectEqual(
            parse("Rio text أحمد saying اني بتأخر شوي"), .actions([.sendMessage(to: "أحمد", body: "اني بتأخر شوي")])
        )
    }

    // MARK: Finding 51

    private static func testSettingsPanes() {
        expectTable([
            ("ريو افتح اعدادات الوايفاي", nil),
            ("ريو افتح إعدادات البلوتوث", nil),
            ("ريو افتح اعدادات الصوت", nil),
            ("سكر اعدادات الوايفاي", nil),
            ("ريو افتح الاعدادات", "Rio open System Settings"),
            ("افتح الوايفاي", "turn on wifi"),
        ])
    }

    // MARK: Finding 52

    private static func testGoogleSearch() {
        expectTable([
            ("ريو ابحث في جوجل عن مطاعم هندية", "Rio search for مطاعم هندية"),
            ("ابحث في قوقل عن مطاعم", "search for مطاعم"),
            ("ريو قوقل لي مطاعم هندية", "Rio search for مطاعم هندية"),
            ("ابحث في google عن pizza", "search for pizza"),
            ("ابحث في يوتيوب عن قطط", "search youtube for قطط"),
            ("ريو قوقل كروم", nil),
            ("افتح قوقل كروم", "open Chrome"),
        ])
    }

    // MARK: Finding 53

    private static func testArabicPaddingAroundEnglish() {
        let cases: [(String, RioCommandTranslationPlan)] = [
            ("Rio open Chrome لو سمحت", .offline("Rio open Chrome")),
            ("Rio open Chrome يا ريو", .offline("Rio open Chrome")),
            ("Rio open Chrome الله يخليك", .offline("Rio open Chrome")),
            ("Rio take a screenshot لو سمحت", .offline("Rio take a screenshot")),
            ("Rio يلا open Slack", .offline("Rio open Slack")),
            ("Rio open Chrome و Safari", .offline("Rio open Chrome and Safari")),
            ("Rio quit Slack و Zoom", .offline("Rio quit Slack and Zoom")),
            ("Rio ال volume up", .offline("Rio volume up")),
            ("Rio ok افتح الكروم يعني", .offline("Rio open Chrome")),
            ("Rio open YouTube و دور على 3blue1brown", .offline("Rio open YouTube and search for 3blue1brown")),
            ("open Chrome، لو سمحت", .offline("open Chrome")),
            // Unchanged: the name alone in Arabic, a message, Arabic content, a name.
            ("ريو stop", .unchanged),
            ("open Chrome", .unchanged),
            ("Rio text Ahmed saying I'm late يلا", .unchanged),
            ("Rio type مرحبا", .unchanged),
            ("Rio text Ahmed وين انت", .unchanged),
            ("Rio call أحمد", .llm),
            ("ريو افتح كروم", .offline("Rio open Chrome")),
        ]
        for (input, expected) in cases {
            TestSupport.expectEqualNamed(RioCommandTranslationPlan.plan(for: input), expected, input)
        }
        TestSupport.expectEqual(
            parse("Rio quit Slack and Zoom"), .actions([.quitApp(name: "Slack"), .quitApp(name: "Zoom")])
        )
    }

    // MARK: Findings 6a and 7

    private static func outside(_ text: String) -> RioAction? {
        RioOutsidePhrases.parse(raw: text, simplified: RioText.simplify(text))
    }

    private static func testStudyContentIsNotMusic() {
        for phrase in [
            "play the lecture at 1.5x speed", "play khan academy integration by parts", "play my MAT108 class recording",
            "play the tutorial on recursion", "play the lesson", "play that crash course video", "play it at double speed",
            "play the ECS 120 lectures",
        ] {
            TestSupport.expectEqualNamed(outside(phrase), nil, phrase)
        }
        TestSupport.expectEqualNamed(outside("play Of Course by Ahmed"), .playMusic(query: "Of Course by Ahmed"), "of course")
        TestSupport.expectEqualNamed(outside("play Blinding Lights"), .playMusic(query: "Blinding Lights"), "song")
    }

    private static func testPlayerNames() {
        let cases: [(String, RioAction)] = [
            ("play spotify", .media(.play)), ("pause spotify", .media(.pause)), ("resume spotify", .media(.play)),
            ("pause youtube", .media(.pause)), ("resume youtube", .media(.play)), ("pause the music app", .media(.pause)),
            ("unpause spotify", .media(.play)), ("play apple music", .media(.play)), ("pause it", .media(.pause)),
        ]
        for (phrase, expected) in cases {
            TestSupport.expectEqualNamed(RioActionParser.parseMedia(RioText.simplify(phrase)), expected, phrase)
            TestSupport.expectEqualNamed(parse("Rio \(phrase)"), .actions([expected]), "parser: \(phrase)")
        }
        TestSupport.expectEqualNamed(outside("play spotify"), nil, "not a song called spotify")
        TestSupport.expectEqualNamed(outside("play apple music"), nil, "not a song called apple music")
        TestSupport.expectEqualNamed(RioActionParser.parseMedia("pause spotify premium"), nil, "anchored")
    }

    // MARK: Finding 10

    private static func testCanvasWithoutDue() {
        let cases: [(String, String?)] = [
            ("Rio what assignments are coming up", nil),
            ("what assignments do I have left this week", "this week"),
            ("do i have homework tonight", "today"),
            ("when's my next quiz", nil),
            ("check canvas for ECS 120", "ECS120"),
            ("what's do this week", "this week"),
            ("anything do tomorrow", "tomorrow"),
            ("what projects do I have this week", "this week"),
        ]
        for (phrase, range) in cases {
            TestSupport.expectEqualNamed(parse(phrase), .actions([.canvasDue(range: range)]), phrase)
        }
        for phrase in [
            "any new announcements on canvas", "did I submit homework five", "help me with my homework tonight",
            "what's my next class", "what's next", "what grade did I get on the quiz", "what do I have tonight",
        ] {
            if case .actions(let actions) = parse(phrase), actions.contains(where: { if case .canvasDue = $0 { true } else { false } }) {
                TestSupport.expect(false, "not a due-date question: \(phrase) -> \(actions)")
            }
        }
        TestSupport.expectEqual(RioCanvasRange.parts("tonight").range, "today")
        TestSupport.expectEqual(RioCanvasRange.parts("tonight MAT108").course, "MAT108")
    }

    // MARK: Finding 16

    private static func testHomeworkTimeWords() {
        expectTable([
            ("ريو وش عندي واجبات هالأسبوع", "Rio what homework is due this week"),
            ("وش عندي واجبات هذا الأسبوع", "what homework is due this week"),
            ("وش عندي واجبات بكرة", "what homework is due tomorrow"),
            ("وش عندي واجبات الأسبوع الجاي", "what homework is due next week"),
            ("وش عندي واجبات اليوم", "what homework is due today"),
            ("وش عندي واجبات MAT108", "what homework is due for MAT108"),
            ("ريو وش عندي واجبات", "Rio what homework is due"),
            // A word the table doesn't know: the LLM, never a dropped range.
            ("وش عندي واجبات مع احمد", nil),
            ("وش عندي واجبات اليوم وبكرة", nil),
        ])
        TestSupport.expectEqualNamed(
            parsedArabic("ريو وش عندي واجبات هالأسبوع"), .actions([.canvasDue(range: "this week")]), "this week"
        )
    }

    // MARK: Finding 57

    private static func testTableSpellingAndLeadIn() {
        expectTable([
            ("ريو افتح الآلة الحاسبة", "Rio open Calculator"),
            ("افتح الحاسبة", "open Calculator"),
            ("ريو الصوت للنص", "Rio set volume to 50"),
            ("الصوت للآخر", "set volume to 100"),
            ("الاضاءة خمسين", "set brightness to 50"),
            ("افتح كروم وسكره", "open Chrome and quit it"),
            ("سكره", nil),
            ("افتحه", nil),
            ("ريو خلاص روح نام", "Rio stop listening"),
            ("ريو خلاص وقف الترجمة", "Rio stop translating"),
            ("ريو خلاص ولا شي", "Rio never mind"),
            ("ريو خلاص", nil),
            ("افتح الكالندر", "open Calendar"),
            ("افتح الإنستغرام", "open Instagram"),
            ("افتح نتفليكس", "open Netflix"),
        ])
        TestSupport.expectEqualNamed(
            parsedArabic("افتح كروم وسكره"), .actions([.openApp(name: "Google Chrome"), .quitApp(name: "Google Chrome")]), "open then quit it"
        )
    }
}
