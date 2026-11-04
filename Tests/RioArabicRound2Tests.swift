import Foundation

/// Round 2 fixes to the offline Arabic table: two things joined by "و", time-left questions,
/// translating text vs the room, search that must not go public, play vs open, polite forms and
/// fillers, code-switching, "never mind", "say it" with content, levels after up/down, "الغي".
enum RioArabicRound2Tests {
    private static let apps = ["Google Chrome", "Safari", "Spotify", "WhatsApp", "Notes", "Terminal", "Canvas"].map {
        InstalledApp(name: $0, bundleIdentifier: nil, url: URL(fileURLWithPath: "/Applications/\($0).app"))
    }

    static func run() {
        testTwoTargets()
        testTimeLeftNeedsATimer()
        testTranslateRoomOnly()
        testSearch()
        testPlayAndCanvas()
        testPoliteFormsAndFillers()
        testCodeSwitched()
        testNeverMind()
        testSayItAlone()
        testLevelAfterUpDown()
        testUnmuteVerb()
    }

    private static func english(_ text: String) -> String? { RioArabicCommandTable.english(for: text) }

    private static func expectTable(_ cases: [(String, String?)], line: UInt = #line) {
        for (input, expected) in cases {
            TestSupport.expectEqualNamed(english(input), expected, input, line: line)
        }
    }

    private static func parsed(_ input: String) -> RioActionParse? {
        guard let text = english(input) else { return nil }
        return RioActionParser(installedApps: apps).parse(RioActionTranscript.stripName(from: text))
    }

    // Finding 46
    private static func testTwoTargets() {
        expectTable([
            ("ريو طفي الوايفاي والبلوتوث", "Rio turn off wifi and turn off bluetooth"),
            ("ريو شغل البلوتوث والوايفاي", "Rio turn on bluetooth and turn on wifi"),
            ("ريو افتح كروم والوايفاي", "Rio open Chrome and turn on wifi"),
            ("ريو علي الصوت والاضاءة", "Rio volume up and brightness up"),
            ("ريو افتح الوايفاي والدارك مود", "Rio turn on wifi and turn on dark mode"),
            ("ريو اقفل الشاشة والصوت", "Rio lock my screen and mute"),
            ("ريو طفي الوايفاي و البلوتوث", "Rio turn off wifi and turn off bluetooth"),
            // Mute has no meaning for wifi: not understood, never half done.
            ("ريو اكتم الصوت والوايفاي", nil),
            // Two things with no "و" to separate them: the LLM.
            ("طفي الوايفاي البلوتوث", nil),
        ])
        TestSupport.expectEqualNamed(
            parsed("ريو طفي الوايفاي والبلوتوث"),
            .actions([.systemToggle(.wifi, isOn: false), .systemToggle(.bluetooth, isOn: false)]), "parse wifi+bluetooth"
        )
        // Unchanged: "و" on an app or a verb, and numbers.
        expectTable([
            ("افتح كروم وسبوتيفاي", "open Chrome and Spotify"),
            ("ريو شغل سبوتيفاي وعلي الصوت", "Rio open Spotify and volume up"),
            ("ريو خلي الصوت على خمسة وعشرين", "Rio set volume to 25"),
        ])
    }

    // Finding 47
    private static func testTimeLeftNeedsATimer() {
        expectTable([
            ("ريو كم باقي على المغرب", nil),
            ("ريو كم باقي على الاجتماع", nil),
            ("ريو كم باقي على رمضان", nil),
            ("ريو كم باقي على الدوام", nil),
            ("ريو كم باقي", "Rio how much time is left"),
            ("كم الوقت المتبقي", "how much time is left"),
            ("ريو كم باقي على التايمر", "Rio how much time is left"),
        ])
    }

    // Finding 48
    private static func testTranslateRoomOnly() {
        expectTable([
            ("ريو ترجم الكلام اللي على الشاشة", nil),
            ("ريو ترجم كلام احمد", nil),
            ("ريو ترجم لي", nil),
            ("ريو ترجم", nil),
            ("ريو ترجم المحادثة", "Rio translate what is being said"),
            ("ريو ترجم اللي يقولونه", "Rio translate what is being said"),
            ("ترجم لي الكلام", "translate what is being said"),
            ("ريو ترجم الكلام اللي حولي", "Rio translate what is being said"),
            ("ريو ترجم هذا الكلام", "Rio translate this to English"),
        ])
    }

    // Findings 49, 50 and the search part of 9
    private static func testSearch() {
        expectTable([
            ("ريو ابحث عن مطاعم وافتح كروم", nil),
            ("ريو ابحث عن مطعم واتصل فيه", nil),
            ("ريو ابحث عن رقم احمد وارسله لامي", nil),
            ("ريو دور على ملف الواجب", nil),
            ("ريو دور لي الايميل من احمد", nil),
            ("ريو ابحث عن رسالة احمد", nil),
            ("ريو دور على صورة البحر", nil),
            ("ريو ابحث عن pigeonhole principle", "Rio search for pigeonhole principle"),
            ("ريو ابحث عن مطاعم قريبة", "Rio search for مطاعم قريبة"),
            ("ابحث في يوتيوب عن أغاني وطنية", "search youtube for أغاني وطنية"),
        ])
        TestSupport.expectEqualNamed(
            RioCommandTranslationPlan.plan(for: "ريو ابحث عن pigeonhole principle"),
            .offline("Rio search for pigeonhole principle"), "arabic search verb, english query"
        )
        TestSupport.expectEqualNamed(RioCommandTranslationPlan.plan(for: "ريو دور على ملف الواجب"), .llm, "file search: LLM")
    }

    // Finding 8 and the vocabulary part of 9
    private static func testPlayAndCanvas() {
        expectTable([
            ("ريو، شغل lofi", "Rio play lofi"),
            ("ريو شغل Spotify", "Rio open Spotify"),
            ("ريو شغل YouTube", "Rio open YouTube"),
            ("ريو افتح lofi", "Rio open lofi"),
            ("ريو افتح كانفاس", "Rio open Canvas"),
            ("ريو افتح كانفس", "Rio open Canvas"),
            ("ريو وش عندي واجبات", "Rio what homework is due"),
        ])
        TestSupport.expectEqualNamed(parsed("ريو، شغل lofi"), .actions([.playMusic(query: "lofi")]), "parse play lofi")
        guard case .actions(let actions)? = parsed("ريو وش عندي واجبات"), case .canvasDue? = actions.first else {
            TestSupport.expect(false, "homework is canvasDue")
            return
        }
    }

    // Findings 51 and 52
    private static func testPoliteFormsAndFillers() {
        expectTable([
            ("ريو ممكن تفتح كروم", "Rio open Chrome"),
            ("ريو تقدر تشغل سبوتيفاي", "Rio open Spotify"),
            ("ريو تفتح لي سفاري؟", "Rio open Safari"),
            ("ريو ممكن تعلي الصوت", "Rio volume up"),
            ("ريو تسكر سفاري", "Rio quit Safari"),
            ("ريو ابيك تفتح كروم", "Rio open Chrome"),
            ("ريو ابغى اسمع اغاني", "Rio play music"),
            ("ريو توطي الصوت", "Rio volume down"),
            ("ريو تطفي الوايفاي", "Rio turn off wifi"),
            ("ريو تكتم الصوت", "Rio mute"),
            ("ريو يعني افتح كروم", "Rio open Chrome"),
            ("ريو اه افتح كروم", "Rio open Chrome"),
            ("ريو امم افتح كروم", "Rio open Chrome"),
            ("ريو اوه افتح كروم", "Rio open Chrome"),
            ("ريو، ريو افتح كروم", "Rio open Chrome"),
            ("ريو وافتح كروم", "Rio open Chrome"),
            // Words that start with "ت" but are not second-person commands stay as they were.
            ("تراجع", "undo"),
            ("ترجم اللي ينقال", "translate what is being said"),
        ])
    }

    // Findings 53, 54 and the Arabic part of 26
    private static func testCodeSwitched() {
        for text in [
            "Rio play محمد عبده", "Rio play عبادي الجوهر on Spotify", "Rio open YouTube and play عبادي الجوهر",
            "Rio remember ان رقم الغرفة ٢٠٤",
        ] {
            TestSupport.expectEqualNamed(RioCommandTranslationPlan.plan(for: text), .unchanged, "english frame: \(text)")
        }
        expectTable([
            ("Rio افتح كروم and put it on the left", "Rio open Chrome and put it on the left"),
            ("Rio, can you افتح لي الكروم please", "Rio open Chrome"),
            ("ريو open سبوتيفاي", "Rio open Spotify"),
            ("Rio open the كروم", "Rio open Chrome"),
            ("Rio علي ال volume", "Rio volume up"),
            ("ريو اكتب hello", "Rio type hello"),
        ])
        TestSupport.expectEqualNamed(RioCommandTranslationPlan.plan(for: "ريو اكتب hello"), .offline("Rio type hello"), "اكتب hello")
        TestSupport.expectEqualNamed(RioCommandTranslationPlan.plan(for: "ريو open سبوتيفاي"), .offline("Rio open Spotify"), "open سبوتيفاي")
        // Arabic content after an Arabic type verb is still for the LLM.
        TestSupport.expectEqualNamed(RioCommandTranslationPlan.plan(for: "ريو اكتب مرحبا"), .llm, "arabic type verb")
        TestSupport.expectEqualNamed(
            RioActionParser(installedApps: apps).parse("play محمد عبده"), .actions([.playMusic(query: "محمد عبده")]),
            "parser reads play + arabic artist"
        )
    }

    // Finding 57
    private static func testNeverMind() {
        expectTable([
            ("ريو انسى", "Rio never mind"),
            ("ريو انسى الموضوع", "Rio never mind"),
            ("ريو ولا شي", "Rio never mind"),
            ("ريو خلاص ولا شي", "Rio never mind"),
            ("ريو ماله داعي", "Rio never mind"),
            ("ريو خلاص انسى", "Rio never mind"),
            ("ريو انسى ان رقم الغرفة ٢٠٤", nil),
        ])
        TestSupport.expect(
            RioActionTranscript.isDismissal(RioActionTranscript.stripName(from: english("ريو انسى") ?? "")), "dismissal"
        )
    }

    // Finding 60
    private static func testSayItAlone() {
        expectTable([
            ("ريو قولهم اني جاي", nil),
            ("ريو قولها لأحمد", nil),
            ("ريو قولها", "Rio say it"),
            ("قولهم", "say it"),
        ])
    }

    // Finding 62
    private static func testLevelAfterUpDown() {
        expectTable([
            ("ريو علي الصوت عشرين", "Rio set volume to 20"),
            ("ريو شغل سبوتيفاي وعلي الصوت لخمسين", "Rio open Spotify and set volume to 50"),
            ("ريو علي الصوت للآخر", "Rio set volume to 100"),
            ("ريو وطي الاضاءة للنص", "Rio set brightness to 50"),
            ("ريو علي الصوت", "Rio volume up"),
            ("ريو علي الصوت شوي", "Rio volume up"),
            ("خلي الصوت لخمسين", "set volume to 50"),
        ])
        TestSupport.expectEqualNamed(parsed("ريو علي الصوت عشرين"), .actions([.volume(.set(20))]), "parse set 20")
    }

    // Finding 63
    private static func testUnmuteVerb() {
        expectTable([
            ("ريو الغي الكتم", "Rio unmute"),
            ("ريو فك الكتم", "Rio unmute"),
            ("ريو كتم", "Rio mute"),
        ])
    }
}
