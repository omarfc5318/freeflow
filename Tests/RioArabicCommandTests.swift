import Foundation

/// Arabic detection and the offline Arabic (Gulf and MSA) command table. The table must turn a
/// spoken command into English that the real parser understands, with no network.
enum RioArabicCommandTests {
    private static let apps = ["Google Chrome", "Safari", "Spotify", "WhatsApp", "Notes", "Terminal"].map {
        InstalledApp(name: $0, bundleIdentifier: nil, url: URL(fileURLWithPath: "/Applications/\($0).app"))
    }

    static func run() {
        testDetection()
        testNormalize()
        testApps()
        testVolumeAndMedia()
        testSystem()
        testTranslatorCommands()
        testCompoundAndFillers()
        testNotUnderstood()
        testThroughRealParser()
        testPlan()
        testAndOnVerb()
        testCompoundNumbers()
        testContentStaysArabic()
        testGulfVerbsAndShortApps()
        testArabicNameBeforeEnglish()
        testSongByArtist()
        testTimerFractionsAndBareUnits()
        testTranslateThisText()
        testQueriesKeepSpelling()
    }

    private static func english(_ text: String) -> String? { RioArabicCommandTable.english(for: text) }

    private static func testDetection() {
        TestSupport.expect(RioArabicText.needsTranslation("ريو افتح كروم"), "arabic needs translation")
        TestSupport.expect(RioArabicText.isArabic("ريو افتح كروم"), "arabic is arabic")
        TestSupport.expect(!RioArabicText.needsTranslation("Rio open Chrome"), "english never translated")
        TestSupport.expect(!RioArabicText.needsTranslation(""), "empty is not translated")
        TestSupport.expect(!RioArabicText.needsTranslation("123 !!!"), "no letters is not translated")
        TestSupport.expect(!RioArabicText.needsTranslation("text Mohammed محمد I'll be late"), "one arabic name stays english")
        TestSupport.expect(RioArabicText.needsTranslation("खोलो क्रोम"), "hindi needs translation")
        TestSupport.expect(RioArabicText.needsTranslation("откройте хром"), "cyrillic needs translation")
        TestSupport.expect(!RioArabicText.isArabic("खोलो क्रोम"), "hindi is not arabic")
        TestSupport.expect(!RioArabicText.needsTranslation("Ouvre Chrome s'il te plaît"), "latin french is not script-detected")
    }

    private static func testNormalize() {
        TestSupport.expectEqual(RioArabicText.normalize("شَغِّلْ"), "شغل")
        TestSupport.expectEqual(RioArabicText.normalize("أَفْتَحْ إِلَى"), "افتح الي")
        TestSupport.expectEqual(RioArabicText.normalize("الشاشة؟"), "الشاشه")
        TestSupport.expectEqual(RioArabicText.normalize("الصوت ٥٠"), "الصوت 50")
        TestSupport.expectEqual(RioArabicText.normalize("  كـــروم،  "), "كروم")
    }

    private static func testApps() {
        let cases: [(String, String)] = [
            ("ريو افتح كروم", "Rio open Chrome"),
            ("افتح كروم", "open Chrome"),
            ("افتح جوجل كروم", "open Chrome"),
            ("ريو شغّل سبوتيفاي", "Rio open Spotify"),
            ("افتح لي سفاري", "open Safari"),
            ("ريو افتح واتساب", "Rio open WhatsApp"),
            ("افتح الواتس اب", "open WhatsApp"),
            ("سكّر كروم", "quit Chrome"),
            ("اقفل سفاري", "quit Safari"),
            ("طفّي كروم", "quit Chrome"),
            ("اغلق سبوتيفاي", "quit Spotify"),
            ("افتح الترمنال", "open Terminal"),
            ("افتح Chrome", "open Chrome"),
        ]
        for (input, expected) in cases {
            TestSupport.expectEqualNamed(english(input), expected, input)
        }
    }

    private static func testVolumeAndMedia() {
        let cases: [(String, String)] = [
            ("علّي الصوت", "volume up"),
            ("ريو ارفع الصوت", "Rio volume up"),
            ("زود الصوت شوي", "volume up"),
            ("وطّي الصوت", "volume down"),
            ("نزّل الصوت", "volume down"),
            ("خفّض الصوت", "volume down"),
            ("طفّي الصوت", "mute"),
            ("اكتم الصوت", "mute"),
            ("كتم الصوت", "mute"),
            ("شغّل الصوت", "unmute"),
            ("خلي الصوت خمسين", "set volume to 50"),
            ("الصوت ٣٠", "set volume to 30"),
            ("اجعل الصوت 80", "set volume to 80"),
            ("خلي الصوت على الأخير", "set volume to 100"),
            ("شغّل الموسيقى", "play music"),
            ("شغل الاغنية", "play music"),
            ("وقّف الموسيقى", "pause"),
            ("كمّل", "play"),
            ("الأغنية الجاية", "next song"),
            ("الأغنية اللي قبل", "previous song"),
            ("زود الاضاءة", "brightness up"),
            ("نزّل السطوع", "brightness down"),
        ]
        for (input, expected) in cases {
            TestSupport.expectEqualNamed(english(input), expected, input)
        }
    }

    private static func testSystem() {
        let cases: [(String, String)] = [
            ("ولّع الواي فاي", "turn on wifi"),
            ("شغل الوايفاي", "turn on wifi"),
            ("طفّي الواي فاي", "turn off wifi"),
            ("قفل الواي فاي", "turn off wifi"),
            ("ولّع البلوتوث", "turn on bluetooth"),
            ("طفّي البلوتوث", "turn off bluetooth"),
            ("قفّل الشاشة", "lock my screen"),
            ("اقفل الجهاز", "lock my screen"),
            ("خذ لقطة شاشة", "take a screenshot"),
            ("صوّر الشاشة", "take a screenshot"),
            ("شغّل الوضع الداكن", "turn on dark mode"),
            ("لا تزعجني", "turn on do not disturb"),
            ("كم باقي من البطارية", "how much battery"),
            ("وقف الاستماع", "stop listening"),
            ("تراجع", "undo"),
        ]
        for (input, expected) in cases {
            TestSupport.expectEqualNamed(english(input), expected, input)
        }
    }

    private static func testTranslatorCommands() {
        let cases: [(String, String)] = [
            ("ترجم اللي ينقال", "translate what is being said"),
            ("ريو ترجم اللي يقولونه", "Rio translate what is being said"),
            ("ترجم لي الكلام", "translate what is being said"),
            ("ابدأ الترجمة", "start translating"),
            ("شغّل وضع المترجم", "start translating"),
            ("وقّف الترجمة", "stop translating"),
            ("ريو وقف الترجمة", "Rio stop translating"),
            ("اطفي الترجمة", "stop translating"),
            ("قولها", "say it"),
            ("قول الترجمة", "say it"),
            ("ترجم هذا الى الفرنسية", "translate this to French"),
            ("ترجم هذا للانجليزي", "translate this to English"),
        ]
        for (input, expected) in cases {
            TestSupport.expectEqualNamed(english(input), expected, input)
        }
    }

    private static func testCompoundAndFillers() {
        let cases: [(String, String)] = [
            ("افتح كروم وسبوتيفاي", "open Chrome and Spotify"),
            ("افتح كروم و سبوتيفاي", "open Chrome and Spotify"),
            ("يا ريو لو سمحت افتح كروم الحين", "Rio open Chrome"),
            ("ريو ابي افتح كروم", "Rio open Chrome"),
            ("هلا ريو علي الصوت", "Rio volume up"),
            ("ريو", "Rio"),
        ]
        for (input, expected) in cases {
            TestSupport.expectEqualNamed(english(input), expected, input)
        }
    }

    private static func testNotUnderstood() {
        // Unknown things return nil so the LLM (online) gets them; the table never guesses.
        let nils = [
            "", "   ", "Rio open Chrome", "what is the weather",
            "كم الساعة في الدوحة", "افتح البرنامج الفلاني", "ريو ابعث رسالة لعلي", "اكتب لي قصيدة",
            "افتح كروم واكتب هلا",
        ]
        for input in nils {
            TestSupport.expectEqualNamed(english(input), nil, "nil for \(input)")
        }
    }

    private static func testThroughRealParser() {
        let parser = RioActionParser(installedApps: apps)
        let cases: [(String, RioAction)] = [
            ("ريو افتح كروم", .openApp(name: "Google Chrome")),
            ("سكّر سفاري", .quitApp(name: "Safari")),
            ("علّي الصوت", .volume(.up)),
            ("وطّي الصوت", .volume(.down)),
            ("طفّي الصوت", .volume(.mute)),
            ("شغّل الصوت", .volume(.unmute)),
            ("خلي الصوت خمسين", .volume(.set(50))),
            ("شغّل الموسيقى", .media(.playPause)),
            ("الأغنية الجاية", .media(.next)),
            ("قفّل الشاشة", .lockScreen),
            ("خذ لقطة شاشة", .screenshot(.fullScreen)),
            ("ولّع الواي فاي", .systemToggle(.wifi, isOn: true)),
            ("طفّي البلوتوث", .systemToggle(.bluetooth, isOn: false)),
            ("ريو ترجم اللي ينقال", .startTranslation),
            ("وقّف الترجمة", .stopTranslation),
            ("قولها", .speakLastTranslation),
            ("ترجم هذا الى الفرنسية", .selectionTask(.translate(language: "French"))),
            ("كم باقي من البطارية", .batteryStatus),
        ]
        for (input, expected) in cases {
            guard let text = english(input) else {
                TestSupport.expect(false, "table understood \(input)")
                continue
            }
            TestSupport.expectEqualNamed(parser.parse(text), .actions([expected]), "\(input) -> \(text)")
        }
        TestSupport.expectEqual(
            parser.parse(english("افتح كروم وسبوتيفاي") ?? ""),
            .actions([.openApp(name: "Google Chrome"), .openApp(name: "Spotify")])
        )
    }

    private static func testPlan() {
        // English is never translated or sent anywhere.
        for text in ["Rio open Chrome", "open Chrome and Spotify", "text Mohammed محمد I'll be late", "", "volume up",
                     "Ouvre Chrome s'il te plaît", "what's the weather in Doha"] {
            TestSupport.expectEqualNamed(RioCommandTranslationPlan.plan(for: text), .unchanged, "unchanged: \(text)")
        }
        TestSupport.expectEqual(RioCommandTranslationPlan.plan(for: "ريو افتح كروم"), .offline("Rio open Chrome"))
        TestSupport.expectEqual(RioCommandTranslationPlan.plan(for: "كم الساعة في الدوحة"), .llm)
        TestSupport.expectEqual(RioCommandTranslationPlan.plan(for: "ابعث رسالة لعلي"), .llm)
        TestSupport.expectEqual(RioCommandTranslationPlan.plan(for: "खोलो क्रोम"), .llm)
        TestSupport.expectEqual(RioCommandTranslationPlan.acceptedReply("\"Rio, open Chrome\"\n"), "Rio, open Chrome")
        TestSupport.expect(RioCommandTranslationPlan.acceptedReply("   ") == nil, "blank reply")
        TestSupport.expect(
            RioCommandTranslationPlan.acceptedReply(String(repeating: "a", count: 400)) == nil, "overlong reply"
        )
    }

    // MARK: Round 1 fixes

    private static func parsed(_ input: String, line: UInt = #line) -> RioActionParse? {
        guard let text = english(input) else {
            TestSupport.expect(false, "table understood \(input)", line: line)
            return nil
        }
        return RioActionParser(installedApps: apps).parse(RioActionTranscript.stripName(from: text))
    }

    private static func testAndOnVerb() {
        // "و" written on the next verb is "and": two commands, not one keyword read out of both.
        TestSupport.expectEqualNamed(english("ريو شغل سبوتيفاي وعلي الصوت"), "Rio open Spotify and volume up", "و+علي")
        TestSupport.expectEqualNamed(english("ريو علي الصوت وشغل الاغنية الجاية"), "Rio volume up and next song", "و+شغل")
        TestSupport.expectEqualNamed(english("ريو افتح الكروم وافتح الواتساب"), "Rio open Chrome and open WhatsApp", "و+افتح")
        TestSupport.expectEqualNamed(parsed("ريو شغل سبوتيفاي وعلي الصوت"), .actions([.openApp(name: "Spotify"), .volume(.up)]), "parse و+علي")
        TestSupport.expectEqualNamed(parsed("ريو علي الصوت وشغل الاغنية الجاية"), .actions([.volume(.up), .media(.next)]), "parse و+شغل")
        TestSupport.expectEqualNamed(
            parsed("ريو افتح الكروم وافتح الواتساب"),
            .actions([.openApp(name: "Google Chrome"), .openApp(name: "WhatsApp")]), "parse و+افتح"
        )
        // Two verbs the splitter can't separate: nil, so the LLM handles it.
        TestSupport.expectEqualNamed(english("شغل سبوتيفاي ارفع الصوت"), nil, "two verbs")
        // "على" (normalised "علي") is not a verb mid-sentence.
        TestSupport.expectEqualNamed(english("خلي الصوت على خمسين"), "set volume to 50", "على is a preposition")
    }

    private static func testCompoundNumbers() {
        let cases: [(String, String)] = [
            ("ريو خلي الصوت على خمسة وعشرين", "Rio set volume to 25"),
            ("ريو خلي الصوت على ثلاثة وثلاثين", "Rio set volume to 33"),
            ("ريو خلي الصوت خمسة وسبعين بالمية", "Rio set volume to 75"),
            ("خلي الصوت خمس و ستين", "set volume to 65"),
            ("خلي الإضاءة واحد وعشرين", "set brightness to 21"),
            ("ريو خلي الصوت ٥٠٪", "Rio set volume to 50"),
            ("خلي الصوت 40%", "set volume to 40"),
        ]
        for (input, expected) in cases {
            TestSupport.expectEqualNamed(english(input), expected, input)
        }
        // Two numbers: unclear, so the LLM decides.
        TestSupport.expectEqualNamed(english("خلي الصوت خمسين ستين"), nil, "two numbers")
        TestSupport.expectEqualNamed(RioArabicText.normalize("٥٠٪"), "50%", "arabic percent")
        TestSupport.expectEqualNamed(parsed("ريو خلي الصوت على خمسة وعشرين"), .actions([.volume(.set(25))]), "parse 25")
    }

    private static func testContentStaysArabic() {
        // The command is English; the Arabic is what to type, send or search, so it is not translated.
        for text in [
            "Rio type مرحبا كيف حالك", "Rio text Ahmed وين انت", "Rio open Chrome and search for مطاعم في الدوحة",
            "Rio write السلام عليكم ورحمة الله", "message Sara انا جاي", "Rio look up مطاعم قريبة",
        ] {
            TestSupport.expectEqualNamed(RioCommandTranslationPlan.plan(for: text), .unchanged, "content: \(text)")
        }
        TestSupport.expect(!RioArabicText.hasEnglishContentFrame("ريو افتح كروم"), "arabic command has no english frame")
        TestSupport.expect(!RioArabicText.hasEnglishContentFrame("Rio open Chrome"), "no arabic content")
        // An Arabic command is still translated.
        TestSupport.expectEqualNamed(RioCommandTranslationPlan.plan(for: "ريو اكتب مرحبا"), .llm, "arabic type verb")
    }

    private static func testGulfVerbsAndShortApps() {
        let cases: [(String, String)] = [
            ("ريو علّ الصوت", "Rio volume up"),
            ("علو الصوت", "volume up"),
            ("خفف الصوت", "volume down"),
            ("كبّر النافذة", "maximize the window"),
            ("افتح انستا", "open Instagram"),
            ("افتح الماب", "open Maps"),
            ("افتح مابس", "open Maps"),
        ]
        for (input, expected) in cases {
            TestSupport.expectEqualNamed(english(input), expected, input)
        }
        TestSupport.expectEqualNamed(parsed("ريو علّ الصوت"), .actions([.volume(.up)]), "علّ is up, never down")
        TestSupport.expectEqualNamed(parsed("خفف الصوت"), .actions([.volume(.down)]), "خفف")
        if case .actions(let actions)? = parsed("كبّر النافذة") {
            TestSupport.expectEqualNamed(actions.count, 1, "maximize parsed")
        } else {
            TestSupport.expect(false, "maximize parsed")
        }
    }

    private static func testArabicNameBeforeEnglish() {
        for text in ["ريو open Chrome", "ريو volume up", "ريو stop listening", "ريو stop", "رايو open Spotify", "ريّو open VS Code"] {
            TestSupport.expectEqualNamed(RioCommandTranslationPlan.plan(for: text), .unchanged, "arabic name: \(text)")
        }
        TestSupport.expectEqualNamed(RioActionTranscript.stripName(from: "ريو open Chrome"), "open Chrome", "strip ريو")
        TestSupport.expectEqualNamed(RioActionTranscript.stripName(from: "رايو، volume up"), "volume up", "strip رايو")
        TestSupport.expectEqualNamed(RioActionTranscript.stripName(from: "ريّو stop"), "stop", "strip ريّو")
        TestSupport.expectEqualNamed(RioArabicText.withoutLeadingName("Hey Rio افتح كروم"), "افتح كروم", "latin greeting")
        TestSupport.expectEqualNamed(english("رايو افتح كروم"), "Rio open Chrome", "رايو wake")
        TestSupport.expectEqualNamed(english("Hey Rio افتح كروم"), "Rio open Chrome", "hey Rio + arabic")
        // An Arabic verb at the start is a command even when most letters are Latin.
        TestSupport.expectEqualNamed(RioCommandTranslationPlan.plan(for: "Rio, شغل music"), .offline("Rio play music"), "mixed")
    }

    private static func testSongByArtist() {
        // A named song or artist: the table must not answer "play music" or "open Music".
        for text in ["ريو شغل اغنية لعبادي الجوهر", "ريو شغل أغاني محمد عبده", "ريو افتح لي الاغنية حقت فيروز في سبوتيفاي"] {
            TestSupport.expectEqualNamed(english(text), nil, "artist: \(text)")
        }
        TestSupport.expectEqualNamed(english("شغل الأغاني"), "play music", "just the music")
    }

    private static func testTimerFractionsAndBareUnits() {
        let parser = RioActionParser(installedApps: apps)
        let cases: [(String, Int)] = [
            ("ريو حط تايمر دقيقتين ونص", 150),
            ("ريو حط تايمر خمس دقايق ونص", 330),
            ("ريو حط تايمر ساعة ونص", 5400),
            ("ريو حط تايمر ساعة وربع", 4500),
            ("ريو حط تايمر ساعة الا ربع", 2700),
            ("ريو حط تايمر دقيقة", 60),
            ("ريو تايمر ساعة", 3600),
            ("حط تايمر خمسة وعشرين دقيقة", 1500),
            ("حط تايمر خمس دقائق وثلاثين ثانية", 330),
            ("حط تايمر نص ساعة", 1800),
        ]
        for (input, seconds) in cases {
            guard let text = english(input) else {
                TestSupport.expect(false, "timer understood \(input)")
                continue
            }
            guard case .actions(let actions) = parser.parse(RioActionTranscript.stripName(from: text)),
                  case .startTimer(let parsedSeconds, _)? = actions.first else {
                TestSupport.expect(false, "timer parsed \(input) -> \(text)")
                continue
            }
            TestSupport.expectEqualNamed(parsedSeconds, seconds, "\(input) -> \(text)")
        }
        // The label keeps the speaker's word (the parser reads Latin labels only for now).
        TestSupport.expectEqualNamed(english("حط تايمر عشرين دقيقة للشاي"), "set a timer for 20 minutes called الشاي", "label")
    }

    private static func testTranslateThisText() {
        let parser = RioActionParser(installedApps: apps)
        TestSupport.expectEqualNamed(english("ريو ترجم هالكلام للعربي"), "Rio translate this to Arabic", "هالكلام")
        TestSupport.expectEqualNamed(english("ريو ترجم هذا الكلام"), "Rio translate this to English", "هذا الكلام")
        TestSupport.expectEqualNamed(
            parser.parse(RioActionTranscript.stripName(from: english("ريو ترجم هالكلام للعربي") ?? "")),
            .actions([.selectionTask(.translate(language: "Arabic"))]), "selection, not the room"
        )
        // The room is still the room.
        TestSupport.expectEqualNamed(english("ترجم لي الكلام"), "translate what is being said", "room")
        TestSupport.expectEqualNamed(english("ريو ترجم اللي يقولونه"), "Rio translate what is being said", "room ending")
    }

    private static func testQueriesKeepSpelling() {
        TestSupport.expectEqualNamed(english("ريو ابحث عن مطاعم قريبة"), "Rio search for مطاعم قريبة", "query spelling")
        TestSupport.expectEqualNamed(english("دور لي على شقق للايجار في الدوحة"), "search for شقق للايجار في الدوحة", "glue and filler")
        TestSupport.expectEqualNamed(english("ريو ابحث عن جامعة كاليفورنيا ديفيس"), "Rio search for جامعة كاليفورنيا ديفيس", "university")
        TestSupport.expectEqualNamed(english("ابحث في يوتيوب عن أغاني وطنية"), "search youtube for أغاني وطنية", "youtube")
    }
}
