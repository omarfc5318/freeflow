import Foundation

/// One clause of an Arabic command ("افتح كروم") -> English. See `RioArabicCommandTable`.
enum RioArabicClauses {
    struct Result {
        let english: String
        /// True for "open X" / "quit X", so a following bare app name ("وسبوتيفاي") reuses the verb.
        let isAppCommand: Bool
    }

    private enum Target {
        case volume, music, wifi, bluetooth, screen, brightness, darkMode, doNotDisturb, translation, listening
        case app(String)
    }

    private static let openVerbs: Set<String> = ["افتح", "افتحي", "فتح", "شغل", "شغلي", "ولع", "ولعي", "فعل", "فعلي"]
    private static let playVerbs: Set<String> = ["شغل", "شغلي", "ولع", "ولعي"]
    private static let closeVerbs: Set<String> = [
        "سكر", "اسكر", "سكري", "اقفل", "قفل", "اقفلي", "اغلق", "اغلقي", "طفي", "اطفي", "اطفيه", "وقف", "اوقف", "وقفي",
    ]
    private static let lockVerbs: Set<String> = ["اقفل", "قفل", "اقفلي", "سكر", "اسكر"]
    private static let pauseVerbs: Set<String> = ["وقف", "اوقف", "وقفي", "طفي", "اطفي", "سكر", "اسكر"]
    private static let quitVerbs: Set<String> = ["سكر", "اسكر", "سكري", "اقفل", "قفل", "اقفلي", "اغلق", "اغلقي", "طفي", "اطفي", "اطفيه"]
    private static let muteVerbs: Set<String> = ["اكتم", "كتم", "اكتمي", "طفي", "اطفي", "سكر", "اسكر", "اقفل", "قفل"]
    private static let upVerbs: Set<String> = ["علي", "اعلي", "ارفع", "ارفعي", "زود", "زيد", "زودي", "كبر"]
    private static let downVerbs: Set<String> = ["وطي", "نزل", "نزلي", "خفض", "اخفض", "قلل", "صغر"]
    private static let setVerbs: Set<String> = ["خلي", "خل", "اجعل", "حط", "ظبط", "اضبط", "ضبط", "خليه"]
    private static let stopVerbs: Set<String> = ["وقف", "اوقف", "وقفي", "طفي", "اطفي", "سكر", "اسكر", "اقفل", "قفل", "الغي", "الغ", "خلص", "كفايه", "بس", "انهي", "ايقاف"]
    private static let startVerbs: Set<String> = ["ابدا", "ابدي", "بدا", "شغل", "شغلي", "ولع", "فعل", "افتح", "ابدء"]

    static func convert(_ tokens: [String]) -> Result? {
        guard let first = tokens.first else { return nil }
        let words = tokens.map(RioArabicVocabulary.stripArticle)
        let text = words.joined(separator: " ")
        if let translator = translatorCommand(tokens, words, text) { return Result(english: translator, isAppCommand: false) }
        if let simple = simple(tokens, words, text) { return Result(english: simple, isAppCommand: false) }

        let verb = first
        let rest = Array(tokens.dropFirst())
        let target = classify(rest)
        if openVerbs.contains(verb) { return open(verb, rest, target) }
        if let result = volumeAndBrightness(verb, rest, target) { return Result(english: result, isAppCommand: false) }
        if closeVerbs.contains(verb) { return close(verb, rest, target) }
        // "الصوت خمسين": no verb, just the thing and a number.
        if words.first == "صوت", let number = number(in: Array(words.dropFirst())) { return Result(english: "set volume to \(number)", isAppCommand: false) }
        return nil
    }

    // MARK: Fixed phrases

    private static func translatorCommand(_ tokens: [String], _ words: [String], _ text: String) -> String? {
        let first = tokens[0]
        let hasTranslationWord = words.contains { $0 == "ترجمه" || $0 == "مترجم" }
        if first == "ترجم" || first == "ترجمي" {
            let rest = Array(words.dropFirst())
            let pointsAtSelection = rest.contains { ["هذا", "هاذا", "هذه", "هاذي", "هذي", "ذا", "نص"].contains($0) }
            if pointsAtSelection {
                for word in rest {
                    if let language = language(word) { return "translate this to \(language)" }
                }
                return nil
            }
            let roomWords = ["ينقال", "يتقال", "يقولون", "يقوله", "يصير", "يقال", "كلام", "يسمع", "يتكلم", "حوالي", "حولي", "محادثه", "غرفه", "يدور", "يحصل"]
            if rest.isEmpty || roomWords.contains(where: { text.contains($0) }) { return "translate what is being said" }
            return nil
        }
        if hasTranslationWord {
            if startVerbs.contains(first) { return "start translating" }
            if stopVerbs.contains(first) { return "stop translating" }
        }
        let sayVerbs: Set<String> = ["قول", "قل", "انطق", "قولي"]
        let targets: Set<String> = ["ترجمه", "ذا", "هذا", "هاذا", "ها", "هيا"]
        if ["قولها", "قولهم", "انطقها", "اسمعنيها"].contains(first) { return "say it" }
        if sayVerbs.contains(first), words.count == 2, targets.contains(words[1]) { return "say it" }
        return nil
    }

    private static func simple(_ tokens: [String], _ words: [String], _ text: String) -> String? {
        let first = tokens[0]
        if words.contains("بطاريه") { return "how much battery" }
        if first == "تراجع", tokens.count <= 4 { return "undo" }
        if words.contains("استماع"), stopVerbs.contains(first) { return "stop listening" }
        if ["نام", "نامي"].contains(first) || tokens == ["روح", "نام"] { return "stop listening" }
        if words.contains(where: { $0.hasPrefix("تزعج") }), first == "لا" { return "turn on do not disturb" }
        if words.contains("لقطه") || words.contains(where: { $0.hasPrefix("سكرين") }) || (first == "صور" && words.contains("شاشه")) {
            return "take a screenshot"
        }
        if words.contains("كتم"), words.contains(where: { ["الغاء", "الغي", "فك", "الغ"].contains($0) }) { return "unmute" }
        if words.contains("اغنيه") || words.contains("اغاني") || words.contains("اغنيتي") {
            if words.contains("قبل") || words.contains("سابقه") || words.contains("السابقه") { return "previous song" }
            if words.contains(where: { ["جايه", "جاي", "تاليه", "التاليه", "بعدها", "بعد"].contains($0) }) || first == "غير" || first == "تخطي" {
                return "next song"
            }
        }
        if tokens == ["التالي"] || tokens == ["تخطي"] || tokens == ["سكيب"] { return "next song" }
        if tokens == ["كمل"] || tokens == ["كملي"] || tokens == ["استمر"] || tokens == ["شغل"] || tokens == ["شغلي"] { return "play" }
        if tokens == ["وقف"] || tokens == ["اوقف"] { return "pause" }
        return nil
    }

    // MARK: Verbs

    private static func open(_ verb: String, _ rest: [String], _ target: Target?) -> Result? {
        guard let target else { return nil }
        switch target {
        case .volume: return Result(english: "unmute", isAppCommand: false)
        case .music: return Result(english: playVerbs.contains(verb) ? "play music" : "open Music", isAppCommand: false)
        case .wifi: return Result(english: "turn on wifi", isAppCommand: false)
        case .bluetooth: return Result(english: "turn on bluetooth", isAppCommand: false)
        case .darkMode: return Result(english: "turn on dark mode", isAppCommand: false)
        case .doNotDisturb: return Result(english: "turn on do not disturb", isAppCommand: false)
        case .app(let name): return Result(english: "open \(name)", isAppCommand: true)
        case .screen, .brightness, .translation, .listening: return nil
        }
    }

    private static func volumeAndBrightness(_ verb: String, _ rest: [String], _ target: Target?) -> String? {
        guard let target else { return nil }
        let words = rest.map(RioArabicVocabulary.stripArticle)
        switch target {
        case .volume:
            if upVerbs.contains(verb) { return "volume up" }
            if downVerbs.contains(verb) { return "volume down" }
            if setVerbs.contains(verb), let level = number(in: words) { return "set volume to \(level)" }
            if muteVerbs.contains(verb) { return "mute" }
            return nil
        case .brightness:
            if upVerbs.contains(verb) { return "brightness up" }
            if downVerbs.contains(verb) { return "brightness down" }
            if setVerbs.contains(verb), let level = number(in: words) { return "set brightness to \(level)" }
            return nil
        default:
            return nil
        }
    }

    private static func close(_ verb: String, _ rest: [String], _ target: Target?) -> Result? {
        guard let target else { return nil }
        switch target {
        case .music: return pauseVerbs.contains(verb) ? Result(english: "pause", isAppCommand: false) : nil
        case .wifi: return Result(english: "turn off wifi", isAppCommand: false)
        case .bluetooth: return Result(english: "turn off bluetooth", isAppCommand: false)
        case .darkMode: return Result(english: "turn off dark mode", isAppCommand: false)
        case .doNotDisturb: return Result(english: "turn off do not disturb", isAppCommand: false)
        case .screen: return lockVerbs.contains(verb) ? Result(english: "lock my screen", isAppCommand: false) : nil
        case .app(let name): return quitVerbs.contains(verb) ? Result(english: "quit \(name)", isAppCommand: true) : nil
        case .volume, .brightness, .translation, .listening: return nil
        }
    }

    // MARK: Objects

    private static func classify(_ rest: [String]) -> Target? {
        guard !rest.isEmpty else { return nil }
        let words = rest.map(RioArabicVocabulary.stripArticle)
        let compact = words.joined().lowercased().replacingOccurrences(of: "-", with: "")
        if words.contains("صوت") || words.contains("ساوند") { return .volume }
        if compact.contains("وايفاي") || compact.contains("wifi") { return .wifi }
        if words.contains(where: { $0.hasPrefix("بلوت") }) { return .bluetooth }
        if words.contains("اضاءه") || words.contains("سطوع") { return .brightness }
        if words.contains("داكن") || words.contains("دارك") || (words.contains("ليلي") && words.contains("وضع")) { return .darkMode }
        if words.contains("ازعاج") || words.contains("تشويش") { return .doNotDisturb }
        if words.contains(where: { ["موسيقي", "اغنيه", "اغاني", "ميوزك", "مزيكا"].contains($0) }) { return .music }
        if words.contains(where: { ["شاشه", "جهاز", "ماك", "لابتوب", "كمبيوتر"].contains($0) }) { return .screen }
        if let app = RioArabicCommandTable.appName(rest) { return .app(app) }
        return nil
    }

    private static func language(_ word: String) -> String? {
        for form in [word, String(word.dropFirst(2)), String(word.dropFirst(1))] {
            if let name = RioArabicVocabulary.languages[RioArabicVocabulary.stripArticle(form)] { return name }
            if let name = RioArabicVocabulary.languages[form] { return name }
        }
        return nil
    }

    /// A volume or brightness level: digits, a number word, or "to the max".
    private static func number(in words: [String]) -> Int? {
        for word in words {
            if let value = Int(word) { return min(100, max(0, value)) }
            if let value = RioArabicVocabulary.numbers[word] { return value }
            if RioArabicVocabulary.maximumWords.contains(word) { return 100 }
        }
        return nil
    }
}
