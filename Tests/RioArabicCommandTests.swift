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
}
