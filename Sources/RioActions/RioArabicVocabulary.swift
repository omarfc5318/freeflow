import Foundation

/// Word lists for the offline Arabic command table: app names as people say them, numbers,
/// languages, the wake word and filler. Keys are matched after `RioArabicText.normalize`, with
/// spaces ignored and a leading "ال" dropped, so each is written once in plain form.
enum RioArabicVocabulary {
    /// Arabic transliteration of an app or site name -> the English name Rio's parser resolves.
    static let apps: [String: String] = {
        let table: [(String, String)] = [
            ("كروم", "Chrome"), ("جوجل كروم", "Chrome"), ("قوقل كروم", "Chrome"), ("غوغل كروم", "Chrome"),
            ("سفاري", "Safari"), ("فايرفوكس", "Firefox"), ("فاير فوكس", "Firefox"),
            ("سبوتيفاي", "Spotify"), ("سبوتفاي", "Spotify"), ("سبوتيفي", "Spotify"),
            ("واتساب", "WhatsApp"), ("واتس اب", "WhatsApp"), ("واتس", "WhatsApp"),
            ("تيليجرام", "Telegram"), ("تلجرام", "Telegram"), ("تلغرام", "Telegram"), ("تيليغرام", "Telegram"),
            ("ترمنال", "Terminal"), ("ترمينال", "Terminal"), ("تيرمنال", "Terminal"), ("تيرمينال", "Terminal"),
            ("فايندر", "Finder"), ("نوتس", "Notes"), ("ملاحظات", "Notes"), ("ميل", "Mail"), ("بريد", "Mail"),
            ("رسائل", "Messages"), ("تقويم", "Calendar"), ("كاليندر", "Calendar"),
            ("اعدادات", "System Settings"), ("اعدادات النظام", "System Settings"),
            ("زوم", "Zoom"), ("سلاك", "Slack"), ("ديسكورد", "Discord"), ("وورد", "Word"), ("ورد", "Word"),
            ("اكسل", "Excel"), ("بوربوينت", "PowerPoint"), ("اكس كود", "Xcode"),
            ("فيجوال ستوديو كود", "Visual Studio Code"), ("في اس كود", "Visual Studio Code"),
            ("صور", "Photos"), ("خرائط", "Maps"), ("ماب", "Maps"), ("مابس", "Maps"), ("ساعه", "Clock"), ("اله حاسبه", "Calculator"), ("حاسبه", "Calculator"), ("كالكيوليتر", "Calculator"), ("كالكوليتر", "Calculator"),
            ("نوشن", "Notion"), ("فيغما", "Figma"), ("فيجما", "Figma"),
            ("يوتيوب", "YouTube"), ("جيميل", "Gmail"), ("نتفلكس", "Netflix"), ("انستقرام", "Instagram"),
            ("انستجرام", "Instagram"), ("انستا", "Instagram"), ("تويتر", "Twitter"), ("فيسبوك", "Facebook"), ("لينكدان", "LinkedIn"),
            ("لينكد ان", "LinkedIn"), ("تيك توك", "TikTok"), ("ريديت", "Reddit"), ("جوجل", "Google"),
            ("قوقل", "Google"), ("غوغل", "Google"), ("شات جي بي تي", "ChatGPT"),
            ("كانفاس", "Canvas"), ("كانفس", "Canvas"), ("كنفاس", "Canvas"),
        ]
        return Dictionary(table.map { (key(for: $0.0), $0.1) }, uniquingKeysWith: { first, _ in first })
    }()

    /// Arabic language names (and "to <language>" forms) -> the English name `translate this to …` uses.
    static let languages: [String: String] = {
        let table: [(String, String)] = [
            ("انجليزي", "English"), ("انجليزيه", "English"), ("انكليزي", "English"), ("انكليزيه", "English"),
            ("فرنسي", "French"), ("فرنسيه", "French"), ("عربي", "Arabic"), ("عربيه", "Arabic"),
            ("اسباني", "Spanish"), ("اسبانيه", "Spanish"), ("الماني", "German"), ("المانيه", "German"),
            ("ايطالي", "Italian"), ("ايطاليه", "Italian"), ("برتغالي", "Portuguese"), ("هندي", "Hindi"),
            ("اردو", "Urdu"), ("فارسي", "Persian"), ("تركي", "Turkish"), ("تركيه", "Turkish"),
            ("روسي", "Russian"), ("صيني", "Chinese"), ("ياباني", "Japanese"), ("كوري", "Korean"),
        ]
        return Dictionary(table.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first })
    }()

    /// Spoken numbers (after normalising) a volume or brightness can be set to.
    static let numbers: [String: Int] = [
        "صفر": 0, "واحد": 1, "اثنين": 2, "ثلاثه": 3, "اربعه": 4, "خمسه": 5, "سته": 6, "سبعه": 7,
        "ثمانيه": 8, "تسعه": 9, "عشره": 10, "عشرين": 20, "ثلاثين": 30, "اربعين": 40, "خمسين": 50,
        "ستين": 60, "سبعين": 70, "ثمانين": 80, "تسعين": 90, "ميه": 100, "مئه": 100, "نص": 50, "نصف": 50,
    ]

    /// Number words for spoken durations, including the short feminine forms used with "دقائق".
    static let durationNumbers: [String: Int] = {
        var table = numbers
        for (word, value) in [
            ("واحده", 1), ("اثنتين", 2), ("ثلاث", 3), ("اربع", 4), ("خمس", 5), ("ست", 6), ("سبع", 7), ("ثمان", 8),
            ("ثماني", 8), ("تسع", 9), ("عشر", 10), ("احدعش", 11), ("احداعش", 11), ("حداشر", 11), ("اثنعش", 12),
            ("اثناعش", 12), ("طناعش", 12), ("خمستعش", 15), ("خمسطعش", 15), ("خمستاشر", 15), ("ربع", 15), ("خمسه", 5), ("وعشرين", 20), ("وثلاثين", 30),
        ] { table[word] = value }
        return table
    }()

    /// Units 1-9 in every form people say them ("خمسه", "خمس"), and the tens 20-90.
    private static let units: [String: Int] = durationNumbers.filter { (1...9).contains($0.value) }
        .merging(["ثنين": 2, "اثنان": 2], uniquingKeysWith: { first, _ in first })
    private static let tens: [String: Int] = [
        "عشرين": 20, "ثلاثين": 30, "اربعين": 40, "خمسين": 50, "ستين": 60, "سبعين": 70, "ثمانين": 80, "تسعين": 90,
    ]

    /// The number spoken at `words[index]`, reading Arabic's "units and tens" order: "خمسه
    /// وعشرين" (or "خمسه و عشرين") is 25, not 5. `next` is the index after the number. Nil when
    /// no number starts there.
    static func number(in words: [String], at index: Int) -> (value: Int, next: Int)? {
        guard index < words.count else { return nil }
        let word = words[index]
        if let unit = units[word] {
            if index + 1 < words.count, words[index + 1].hasPrefix("و"), let ten = tens[String(words[index + 1].dropFirst())] {
                return (unit + ten, index + 2)
            }
            if index + 2 < words.count, words[index + 1] == "و", let ten = tens[words[index + 2]] {
                return (unit + ten, index + 3)
            }
            return (unit, index + 1)
        }
        if let value = numbers[word] ?? durationNumbers[word], word != "ربع" { return (value, index + 1) }
        return nil
    }

    /// "To the max": volume or brightness 100.
    static let maximumWords: Set<String> = ["اخير", "اخر", "اخره", "ماكس", "اقصي", "كامل", "اعلي", "كله"]

    /// Greeting words that may come before "ريو" (or "Rio"), in the matching form (lowercased).
    static let greetings: Set<String> = [
        "يا", "هلا", "هاي", "هي", "اهلا", "مرحبا", "اوكي", "اوك", "طيب", "هيه", "هلو",
        "hey", "hi", "hello", "yo", "yoo", "ok", "okay",
    ]
    /// The name in Arabic script and the Latin spellings speech-to-text uses (`TeddyCommand.names`).
    static let wakeWords: Set<String> = TeddyCommand.names.union(["ريو", "ريوو", "ريوه", "رايو", "يارايو", "يريو"])

    static func isGreeting(_ word: String) -> Bool { greetings.contains(word.lowercased()) }
    static func isWakeWord(_ word: String) -> Bool { wakeWords.contains(word.lowercased()) }

    /// Words dropped wherever they appear: politeness, "I want (you to)", "now", "a bit", and the
    /// sounds people make while thinking ("يعني", "امم", "اه"). A lone "ال" (the article split off
    /// by speech-to-text, "ال volume") goes too.
    static let fillers: Set<String> = [
        "الحين", "الان", "بسرعه", "ابي", "ابغي", "ابغا", "ممكن", "تقدر", "بتقدر", "يلا", "طيب", "ياخي",
        "حبيبي", "عاد", "لي", "شوي", "شويه", "شويا", "قليلا", "بليز", "تكفي",
        "ابيك", "ابغاك", "ابغيك", "بغيتك", "يعني", "اه", "اها", "امم", "اممم", "ممم", "اوه", "هاه", "ال",
    ]
    /// English politeness around an Arabic command ("can you افتح لي الكروم please"), dropped only
    /// before the first Arabic word or at the very end.
    static let latinPoliteness: Set<String> = ["can", "could", "would", "you", "please", "pls", "plz", "kindly", "uh", "um", "so"]
    /// Two-word politeness phrases dropped as a unit.
    static let fillerPhrases: [[String]] = [["لو", "سمحت"], ["من", "فضلك"], ["لو", "تكرمت"], ["الله", "يعافيك"]]

    /// The lookup form of a table key: normalised, spaces removed, leading "ال" dropped.
    static func key(for text: String) -> String {
        stripArticle(RioArabicText.normalize(text).replacingOccurrences(of: " ", with: ""))
    }

    static func stripArticle(_ word: String) -> String {
        word.hasPrefix("ال") && word.count >= 4 ? String(word.dropFirst(2)) : word
    }
}
