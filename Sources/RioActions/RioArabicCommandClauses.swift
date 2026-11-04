import Foundation

/// One clause of an Arabic command ("افتح كروم") -> English. See `RioArabicCommandTable`.
enum RioArabicClauses {
    struct Result {
        let english: String
        /// True for "open X" / "quit X", so a following bare app name ("وسبوتيفاي") reuses the verb.
        let isAppCommand: Bool
    }

    private enum Target {
        case volume, music, wifi, bluetooth, screen, brightness, darkMode, doNotDisturb, translation, listening, window
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
    // "علّ" (Gulf "raise") loses its shadda in `normalize` and is "عل".
    private static let upVerbs: Set<String> = ["علي", "عل", "علو", "اعلي", "ارفع", "ارفعي", "زود", "زيد", "زودي", "كبر"]
    private static let downVerbs: Set<String> = ["وطي", "نزل", "نزلي", "خفض", "اخفض", "خفف", "قلل", "صغر"]
    private static let setVerbs: Set<String> = ["خلي", "خل", "اجعل", "حط", "ظبط", "اضبط", "ضبط", "خليه"]
    private static let stopVerbs: Set<String> = ["وقف", "اوقف", "وقفي", "طفي", "اطفي", "سكر", "اسكر", "اقفل", "قفل", "الغي", "الغ", "خلص", "كفايه", "بس", "انهي", "ايقاف"]
    private static let startVerbs: Set<String> = ["ابدا", "ابدي", "بدا", "شغل", "شغلي", "ولع", "فعل", "افتح", "ابدء"]

    /// The verbs that start a clause of their own: open, close, up, down, set, play and pause.
    /// "علي" is left out of the mid-sentence check because "على" (on, to) normalises to it.
    private static let clauseVerbs: Set<String> = openVerbs.union(closeVerbs).union(upVerbs).union(downVerbs)
        .union(setVerbs).union(playVerbs).union(pauseVerbs)

    static func isClauseVerb(_ word: String) -> Bool { clauseVerbs.contains(word) }

    static func isQuitVerb(_ word: String) -> Bool { quitVerbs.contains(word) }

    /// "سكره", "افتحه", "شغلها": a clause verb with "it"/"them" written on it. The verb, or nil.
    /// ("عليه" is "on it", not "raise it".)
    static func pronounVerbStem(_ word: String) -> String? {
        for suffix in ["هم", "ها", "ه"] where word.hasSuffix(suffix) {
            let stem = String(word.dropLast(suffix.count))
            if stem.count >= 2, !["علي", "عل"].contains(stem), clauseVerbs.contains(stem) { return stem }
        }
        return nil
    }

    /// Any verb that starts an Arabic command: the clause verbs, mute, search and type/send.
    static func isCommandVerb(_ word: String) -> Bool {
        clauseVerbs.contains(word) || muteVerbs.contains(word) || searchVerbs.contains(word) || contentVerbs.contains(word)
    }

    static func isSearchVerb(_ word: String) -> Bool { searchVerbs.contains(word) }

    /// The command form of a polite second-person verb, read by its shape rather than one by one:
    /// "تفتح" -> "فتح", "تشغل" -> "شغل", "تعلي" -> "علي", "تبحث" -> "ابحث". Nil when the word is
    /// already a command or the shape doesn't give one ("تراجع", "ترجم", "تايمر").
    static func secondPersonCommand(_ word: String) -> String? {
        guard word.hasPrefix("ت"), word.count >= 3, !isCommandVerb(word) else { return nil }
        let stem = String(word.dropFirst())
        if isCommandVerb(stem) { return stem }
        if isCommandVerb("ا" + stem) { return "ا" + stem }
        return nil
    }

    /// A thing a verb acts on that can follow "و" with the verb left out ("طفي الوايفاي
    /// والبلوتوث"): the sound, wifi, bluetooth, the light, dark mode, the screen.
    static func isTargetWord(_ word: String) -> Bool {
        let bare = RioArabicVocabulary.stripArticle(word).lowercased()
        return ["صوت", "ساوند", "وايفاي", "واي", "اضاءه", "سطوع", "دارك", "داكن", "شاشه", "وضع", "wifi", "volume", "bluetooth", "brightness"]
            .contains(bare) || bare.hasPrefix("بلوت")
    }

    /// Arabic verbs whose object is content: type it, send it.
    private static let contentVerbs: Set<String> = ["اكتب", "اكتبي", "ارسل", "ارسلي", "ابعث", "ابعثي"]

    static func convert(_ tokens: [String]) -> Result? {
        guard let first = tokens.first else { return nil }
        // A second command verb means two commands the splitter couldn't separate ("شغل
        // سبوتيفاي ارفع الصوت"): reading one keyword out of it would be a confident wrong answer.
        if tokens.dropFirst().contains(where: { $0 != "علي" && clauseVerbs.contains($0) }) { return nil }
        if let latin = latinVerbOnArabicApp(tokens) { return latin }
        let words = tokens.map(RioArabicVocabulary.stripArticle)
        let text = words.joined(separator: " ")
        if let translator = translatorCommand(tokens, words, text) { return Result(english: translator, isAppCommand: false) }
        if let simple = simple(tokens, words, text) { return Result(english: simple, isAppCommand: false) }

        let verb = first
        let rest = Array(tokens.dropFirst())
        let target = classify(rest)
        // "افتح اعدادات الوايفاي" (open the wifi settings) is a settings pane, not "turn on wifi":
        // a state change nobody asked for. Only "the settings" themselves open (System Settings).
        if words.dropFirst().contains(where: isSettingsWord) {
            guard case .app = target else { return nil }
        }
        if openVerbs.contains(verb) { return open(verb, rest, target) }
        if let result = volumeAndBrightness(verb, rest, target) { return Result(english: result, isAppCommand: false) }
        if case .window = target {
            if upVerbs.contains(verb) { return Result(english: "maximize the window", isAppCommand: false) }
            if downVerbs.contains(verb) { return Result(english: "minimize the window", isAppCommand: false) }
            return nil
        }
        if closeVerbs.contains(verb) { return close(verb, rest, target) }
        // "الصوت خمسين", "الصوت للنص": no verb, just the thing and a level.
        let levelWords = Array(words.dropFirst()).map(withoutToPrefix)
        if words.first == "صوت", let number = number(in: levelWords) { return Result(english: "set volume to \(number)", isAppCommand: false) }
        if ["اضاءه", "سطوع"].contains(words[0]), let number = number(in: levelWords) {
            return Result(english: "set brightness to \(number)", isAppCommand: false)
        }
        return nil
    }

    // MARK: Fixed phrases

    private static func translatorCommand(_ tokens: [String], _ words: [String], _ text: String) -> String? {
        let first = tokens[0]
        let hasTranslationWord = words.contains { $0 == "ترجمه" || $0 == "مترجم" }
        if first == "ترجم" || first == "ترجمي" {
            let rest = Array(words.dropFirst())
            // "هذا"/"هذي" or the Gulf "هال" written on the noun ("هالكلام", "هالنص") points at the
            // selection, so it is checked before the room words ("الكلام" alone is the room).
            // ("هالمحاضرة", "هالفيديو" are a lecture or a video playing: the room.)
            let pointsAtSelection = rest.contains {
                ["هذا", "هاذا", "هذه", "هاذي", "هذي", "ذا", "نص"].contains($0)
                    || ($0.hasPrefix("هال") && $0.count > 3 && !isLiveSource(String($0.dropFirst(3))))
            }
            if pointsAtSelection {
                for word in rest {
                    if let language = language(word) { return "translate this to \(language)" }
                }
                return "translate this to English"
            }
            let roomWords = ["ينقال", "يتقال", "يقولون", "يقوله", "يصير", "يقال", "كلام", "يسمع", "يتكلم", "حوالي", "حولي", "محادثه", "غرفه", "يدور", "يحصل"]
            let glue: Set<String> = [
                "لي", "الي", "ما", "عم", "قاعد", "قاعده", "قاعدين", "هنا", "اللي", "وش", "ايش", "شو", "شنو", "ماذا", "هو", "هي", "هم", "انا",
            ]
            func isRoomWord(_ word: String) -> Bool {
                roomWords.contains { word.hasPrefix($0) } || isSpeechVerb(word) || isLiveSource(word)
                    || (word.hasPrefix("هال") && isLiveSource(String(word.dropFirst(3))))
            }
            // Only the room itself starts the live microphone: every word is a room word (or a
            // word with an ending, "يقولونه"), a verb of speech ("يقول", "اسمعه"), a live source
            // ("المحاضرة", "الفيديو") or glue. With a verb of speech, one or two more words may
            // name the speaker ("وش يقول الدكتور"), unless one is about text or a screen.
            // "ترجم الكلام اللي على الشاشة" (the screen), "ترجم كلام احمد" (a message) and a bare
            // "ترجم لي" go to the LLM instead.
            let others = rest.filter { !glue.contains($0) && !isRoomWord($0) }
            let hasSpeechVerb = rest.contains(where: isSpeechVerb)
            let speakerOnly = hasSpeechVerb && others.count <= 2
                && !others.contains(where: isNotASpeaker)
            let isRoom = rest.contains(where: isRoomWord) && (others.isEmpty || speakerOnly)
            return isRoom ? "translate what is being said" : nil
        }
        if hasTranslationWord {
            if startVerbs.contains(first) { return "start translating" }
            if stopVerbs.contains(first) { return "stop translating" }
        }
        let sayVerbs: Set<String> = ["قول", "قل", "انطق", "قولي"]
        let targets: Set<String> = ["ترجمه", "ذا", "هذا", "هاذا", "ها", "هيا"]
        // Alone only: "قولهم اني جاي" (tell them I'm coming) is a message, not the last translation.
        if ["قولها", "قولهم", "انطقها", "اسمعنيها"].contains(first), tokens.count == 1 { return "say it" }
        if sayVerbs.contains(first), words.count == 2, targets.contains(words[1]) { return "say it" }
        return nil
    }

    /// A verb of speech or hearing in any person: "يقول", "تقول", "يحكي", "اسمعه", "نسمع".
    private static func isSpeechVerb(_ word: String) -> Bool {
        let stems = ["قول", "حكي", "تكلم", "تحدث", "سمع", "شرح"]
        return ["ي", "ت", "ا", "ن"].contains { prefix in stems.contains { word.hasPrefix(prefix + $0) } }
    }

    /// Something that plays speech out loud: a lecture, a class, a meeting, a call, a video.
    private static func isLiveSource(_ word: String) -> Bool {
        let bare = RioArabicVocabulary.stripArticle(word)
        return ["محاضره", "محاضرات", "درس", "حصه", "كلاس", "اجتماع", "ميتنق", "ميتينق", "مكالمه", "اتصال", "فيديو", "خطبه", "مقابله", "بودكاست"]
            .contains(bare)
    }

    /// Words that make "ترجم وش يقول ..." about text rather than a speaker: the screen, a message,
    /// an email, a page, a file ("وش يقول الايميل"), or "in"/"from" something ("في الرساله").
    private static func isNotASpeaker(_ word: String) -> Bool {
        let exact: Set<String> = ["في", "من", "عن", "نص", "ملف", "بريد", "كلمه", "صوره", "ورقه"]
        let textNouns = ["شاشه", "رساله", "رسائل", "رسايل", "مسج", "ايميل", "صفحه", "مقال", "كتاب", "تعليق", "موقع", "مستند", "بالشاشه", "بالرساله"]
        return exact.contains(word) || textNouns.contains { word.hasPrefix($0) }
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
        // Checked on the words as said: the article strip turns "الغي" into "غي".
        if words.contains("كتم"), tokens.contains(where: { ["الغاء", "الغي", "فك", "الغ"].contains($0) }) { return "unmute" }
        if tokens == ["كتم"] || tokens == ["اكتم"] { return "mute" }
        // "ابغى اسمع اغاني": listen to music.
        if ["اسمع", "نسمع", "اسمعني"].contains(first), tokens.count > 1,
           words.dropFirst().allSatisfy({ musicWords.contains($0.lowercased()) }) {
            return "play music"
        }
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
        case .app(let name):
            // "شغل lofi": an English word that isn't a known app or site is something to play.
            // ("افتح lofi" stays "open".)
            if playVerbs.contains(verb), rest.allSatisfy(RioArabicCommandTable.isLatinWord), !isKnownAppOrSite(name) {
                return Result(english: "play \(name)", isAppCommand: false)
            }
            return Result(english: "open \(name)", isAppCommand: true)
        case .screen, .brightness, .translation, .listening, .window: return nil
        }
    }

    private static func isKnownAppOrSite(_ name: String) -> Bool {
        let compact = RioText.compact(name)
        return RioArabicVocabulary.apps.values.contains { RioText.compact($0) == compact } || RioWebURLs.isKnownSite(spoken: name)
    }

    /// "open سبوتيفاي", "open the كروم", "quit سفاري": an English verb on an app said in Arabic.
    private static func latinVerbOnArabicApp(_ tokens: [String]) -> Result? {
        let verb = tokens[0].lowercased()
        guard ["open", "launch", "start", "quit", "close"].contains(verb) else { return nil }
        let rest = tokens.dropFirst().filter { $0.lowercased() != "the" }
        guard !rest.isEmpty, !rest.allSatisfy(RioArabicCommandTable.isLatinWord),
              let app = RioArabicVocabulary.apps[RioArabicVocabulary.key(for: rest.joined(separator: " "))] else { return nil }
        return Result(english: "\(verb) \(app)", isAppCommand: true)
    }

    private static func volumeAndBrightness(_ verb: String, _ rest: [String], _ target: Target?) -> String? {
        guard let target else { return nil }
        let words = rest.map(RioArabicVocabulary.stripArticle).map(withoutToPrefix)
        let isUpOrDown = upVerbs.contains(verb) || downVerbs.contains(verb)
        // "علي الصوت عشرين", "لخمسين", "للآخر", "للنص": a level after up or down is where to set it.
        // ("اعلي" there is "higher", not "to the max".)
        let level = number(in: isUpOrDown ? words.filter { $0 != "اعلي" } : words)
        switch target {
        case .volume:
            if isUpOrDown || setVerbs.contains(verb), let level { return "set volume to \(level)" }
            if upVerbs.contains(verb) { return "volume up" }
            if downVerbs.contains(verb) { return "volume down" }
            if muteVerbs.contains(verb) { return "mute" }
            return nil
        case .brightness:
            if isUpOrDown || setVerbs.contains(verb), let level { return "set brightness to \(level)" }
            if upVerbs.contains(verb) { return "brightness up" }
            if downVerbs.contains(verb) { return "brightness down" }
            return nil
        default:
            return nil
        }
    }

    /// "لخمسين" -> "خمسين", "للآخر" -> "اخر", "للنص" -> "نص": "to" written on a level. Other
    /// words are left as they are.
    private static func withoutToPrefix(_ word: String) -> String {
        for prefix in ["لل", "ل"] where word.hasPrefix(prefix) {
            let bare = String(word.dropFirst(prefix.count))
            let digits = bare.trimmingCharacters(in: CharacterSet(charactersIn: "%"))
            if Int(digits) != nil || RioArabicVocabulary.maximumWords.contains(bare)
                || RioArabicVocabulary.number(in: [bare], at: 0) != nil {
                return bare
            }
        }
        return word
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
        case .volume, .brightness, .translation, .listening, .window: return nil
        }
    }

    // MARK: Objects

    private static func classify(_ rest: [String]) -> Target? {
        guard !rest.isEmpty else { return nil }
        let words = rest.map(RioArabicVocabulary.stripArticle)
        let compact = words.joined().lowercased().replacingOccurrences(of: "-", with: "")
        let lower = words.map { $0.lowercased() }
        let systemTargets: [(Target, Bool)] = [
            (.volume, lower.contains { ["صوت", "ساوند", "volume", "sound"].contains($0) }),
            (.wifi, compact.contains("وايفاي") || compact.contains("wifi")),
            (.bluetooth, lower.contains { $0.hasPrefix("بلوت") || $0 == "bluetooth" }),
            (.brightness, lower.contains { ["اضاءه", "سطوع", "brightness"].contains($0) }),
            (.darkMode, words.contains("داكن") || words.contains("دارك") || (words.contains("ليلي") && words.contains("وضع"))),
            (.doNotDisturb, words.contains("ازعاج") || words.contains("تشويش")),
        ]
        let found = systemTargets.filter(\.1).map(\.0)
        // Two things in one clause ("طفي الوايفاي البلوتوث"): doing one and dropping the other would
        // be a confident wrong answer, so the LLM gets it.
        if found.count > 1 { return nil }
        if let only = found.first { return only }
        if words.contains(where: { musicWords.contains($0.lowercased()) }) {
            // Only "the music" itself: "شغل اغنية لعبادي الجوهر" names a song or an artist, which
            // the LLM turns into "play <artist>", so the table must not answer "play music".
            return words.allSatisfy({ musicWords.contains($0.lowercased()) }) ? .music : nil
        }
        if words.contains(where: { ["نافذه", "شباك", "ويندو", "نافذتي"].contains($0) }) { return .window }
        if words.contains(where: { ["شاشه", "جهاز", "ماك", "لابتوب", "كمبيوتر"].contains($0) }) { return .screen }
        if let app = RioArabicCommandTable.appName(rest) { return .app(app) }
        return nil
    }

    /// "اعدادات", "إعدادات", "الضبط", "settings", "سيتنقز": the settings, not the thing they set.
    private static func isSettingsWord(_ word: String) -> Bool {
        let bare = RioArabicVocabulary.stripArticle(word).lowercased()
        return ["اعدادات", "اعداد", "ضبط", "ضبطات", "settings", "setting", "preferences"].contains(bare)
            || bare.hasPrefix("سيتن") || bare.hasPrefix("اعدادات")
    }

    private static let musicWords: Set<String> = ["موسيقي", "اغنيه", "اغاني", "ميوزك", "مزيكا", "music"]

    private static func language(_ word: String) -> String? {
        for form in [word, String(word.dropFirst(2)), String(word.dropFirst(1))] {
            if let name = RioArabicVocabulary.languages[RioArabicVocabulary.stripArticle(form)] { return name }
            if let name = RioArabicVocabulary.languages[form] { return name }
        }
        return nil
    }

    /// A volume or brightness level: digits ("50", "50%"), number words read in Arabic order
    /// ("خمسه وعشرين" is 25), or "to the max". Nil when there is none or more than one, so a
    /// sentence the table can't read cleanly goes to the LLM instead of setting a wrong level.
    static func number(in words: [String]) -> Int? {
        var found: [Int] = []
        var index = 0
        while index < words.count {
            let word = words[index].trimmingCharacters(in: CharacterSet(charactersIn: "%"))
            if let value = Int(word) {
                found.append(value)
                index += 1
            } else if RioArabicVocabulary.maximumWords.contains(word) {
                found.append(100)
                index += 1
            } else if let spoken = RioArabicVocabulary.number(in: words, at: index) {
                found.append(spoken.value)
                index = spoken.next
            } else {
                index += 1
            }
        }
        guard found.count == 1, let level = found.first else { return nil }
        return min(100, max(0, level))
    }
}

// MARK: - Whole-sentence commands: timers, search, help, time left

extension RioArabicClauses {
    /// "قوقل لي مطاعم": the search engine's name said as the verb (Google it) counts too.
    private static let searchVerbs: Set<String> = ["ابحث", "ابحثي", "دور", "دوري", "فتش", "فتشي", "سيرش", "قوقل", "قوقلي", "جوجل", "جوجلي", "غوغل"]
    private static let searchGlue: Set<String> = ["عن", "على", "علي", "في"]
    private static let questionWords: Set<String> = ["ماذا", "شو", "ايش", "وش", "شنو", "ما", "مذا", "شنهو"]
    private static let abilityWords: Set<String> = ["تفعل", "تسوي", "تعمل", "تستطيع", "يمكنك", "تسويه", "تقدر", "تعرف"]
    private static let remainingWords: Set<String> = ["بقي", "باقي", "متبقي", "المتبقي", "باقيه", "يبقي", "تبقي"]
    private static let timerWords: Set<String> = ["موقت", "تايمر", "عداد", "تايمير"]
    private static let cancelVerbs: Set<String> = ["الغي", "الغ", "الغاء", "وقف", "اوقف", "وقفي", "طفي", "اطفي", "امسح", "سكر", "اسكر"]

    /// The English command for a whole Arabic sentence, or nil to let the clause table try.
    /// `originals` are the same words as said (not folded), used for search queries and labels.
    static func whole(_ tokens: [String], originals: [String]? = nil) -> String? {
        guard let first = tokens.first else { return nil }
        let originals = originals?.count == tokens.count ? originals ?? tokens : tokens
        let words = tokens.map(RioArabicVocabulary.stripArticle)
        if let dismissal = dismissal(words) { return dismissal }
        if let content = latinContent(tokens, originals) { return content }
        if let search = search(tokens, originals) { return search }
        if words.contains(where: { timerWords.contains($0) }) {
            if let status = timeLeft(first, words) { return status }
            return timer(first, words, originals)
        }
        if let status = timeLeft(first, words) { return status }
        if words == ["مساعده"] || words == ["ساعدني"] || words == ["اوامر"] || words == ["اشرح"] { return "help" }
        if words.contains(where: { questionWords.contains($0) }), words.contains(where: { abilityWords.contains($0) }) {
            return "what can you do"
        }
        if words.first == "ايش", words.contains("اوامر") || words.contains("الاوامر") { return "what can you do" }
        if words == ["كم", "ساعه"] { return "what time is it" }
        // "وش عندي واجبات": what homework is due (Canvas).
        if words.contains(where: { ["واجب", "واجبات", "واجباتي"].contains($0) }),
           words.contains(where: { questionWords.contains($0) || $0 == "عندي" }) {
            return homework(tokens)
        }
        return nil
    }

    // MARK: Homework

    /// "وش عندي واجبات هالأسبوع" -> "what homework is due this week". The time said is kept
    /// ("بكرة" tomorrow, "اليوم"/"الليلة" today, "الأسبوع الجاي" next week) and a course code
    /// ("MAT108") is passed on; any other word means the sentence is more than this question,
    /// so the LLM gets it rather than a range silently dropped.
    private static func homework(_ tokens: [String]) -> String? {
        let known: Set<String> = questionWords.union([
            "عندي", "عندنا", "علي", "هل", "في", "فيه", "اي", "واجب", "واجبات", "واجباتي", "مطلوب", "مطلوبه", "باقي",
            "متبقي", "لازم", "اسلم", "اسلمها", "تسليم", "متي",
        ])
        var range: String?
        var course: String?
        var index = 0
        func setRange(_ value: String) -> Bool {
            guard range == nil || range == value else { return false }
            range = value
            return true
        }
        while index < tokens.count {
            let word = RioArabicVocabulary.stripArticle(tokens[index])
            let next = index + 1 < tokens.count ? RioArabicVocabulary.stripArticle(tokens[index + 1]) : nil
            if word == "هالاسبوع" || (word == "هذا" && next == "اسبوع") || (word == "اسبوع" && next == "هذا") {
                guard setRange("this week") else { return nil }
                index += word == "هالاسبوع" ? 1 : 2
                continue
            }
            if word == "اسبوع", let next, ["جاي", "قادم", "الجاي", "القادم", "الياي"].contains(next) {
                guard setRange("next week") else { return nil }
                index += 2
                continue
            }
            if ["بكره", "باكر", "بكرا"].contains(word) {
                guard setRange("tomorrow") else { return nil }
            } else if ["يوم", "اليوم", "ليله", "الليله", "هاليوم"].contains(tokens[index]) || word == "ليله" {
                guard setRange("today") else { return nil }
            } else if course == nil, RioArabicCommandTable.isLatinWord(tokens[index]),
                      RioText.matches(#"^[A-Za-z]{2,5}\d{2,4}[A-Za-z]?$"#, tokens[index]) {
                course = tokens[index].uppercased()
            } else if !known.contains(word) && !known.contains(tokens[index]) {
                return nil
            }
            index += 1
        }
        let parts = [range, course.map { "for \($0)" }].compactMap { $0 }
        return (["what homework is due"] + parts).joined(separator: " ")
    }

    // MARK: Never mind

    /// "انسى", "انسى الموضوع", "ولا شي", "خلاص ولا شي", "ماله داعي": the owner changed their mind.
    /// "never mind" is what the coordinator turns into nothing; "انسى ان …" (forget a fact) is
    /// not matched, so it still reaches the LLM and memory.
    private static func dismissal(_ words: [String]) -> String? {
        let forget: Set<String> = ["انسي", "انساها", "انساه", "انسيها", "انسيه"]
        let nothing: Set<String> = ["شي", "شيء", "شيي"]
        var rest = words
        if rest.first == "خلاص", rest.count > 1 { rest.removeFirst() }
        let isDismissal = (rest.count == 1 && forget.contains(rest[0]))
            || (rest.count == 2 && forget.contains(rest[0]) && rest[1] == "موضوع")
            || (rest.count == 2 && rest[0] == "ولا" && nothing.contains(rest[1]))
            || rest == ["ماله", "داعي"] || rest == ["مو", "مهم"]
        return isDismissal ? "never mind" : nil
    }

    // MARK: Arabic verb, English content

    /// "اكتب hello", "ابحث عن pigeonhole principle", "ارسل ok": an Arabic verb on English content
    /// is the English verb with the content unchanged (Arabic content still goes to the LLM).
    private static func latinContent(_ tokens: [String], _ originals: [String]) -> String? {
        guard let first = tokens.first else { return nil }
        var start = 1
        if searchVerbs.contains(first) {
            while start < tokens.count, searchGlue.contains(tokens[start]) { start += 1 }
            if tokens.count - start >= 2, isGoogle(tokens[start]) {
                start += 1
                while start < tokens.count, searchGlue.contains(tokens[start]) { start += 1 }
            }
        }
        guard start < tokens.count, tokens[start...].allSatisfy(RioArabicCommandTable.isLatinWord) else { return nil }
        let content = originals[start...].joined(separator: " ")
        if searchVerbs.contains(first) { return "search for \(content)" }
        if ["اكتب", "اكتبي"].contains(first) { return "type \(content)" }
        if ["ارسل", "ارسلي", "ابعث", "ابعثي"].contains(first) { return "send \(content)" }
        return nil
    }

    // MARK: Search

    private static func search(_ tokens: [String], _ originals: [String]) -> String? {
        guard let first = tokens.first, searchVerbs.contains(first) else { return nil }
        // "قوقل كروم" is the app Google Chrome, not a search for "كروم".
        if RioArabicCommandTable.appName(tokens) != nil { return nil }
        var start = 1
        while start < tokens.count, searchGlue.contains(tokens[start]) { start += 1 }
        // "ابحث في جوجل عن مطاعم": Google is where to search, not part of the query.
        if tokens.count - start >= 2, isGoogle(tokens[start]) {
            start += 1
            while start < tokens.count, searchGlue.contains(tokens[start]) { start += 1 }
        }
        // "ابحث في يوتيوب عن قطط"
        if tokens.count - start >= 2, let site = RioArabicVocabulary.apps[RioArabicVocabulary.key(for: tokens[start])], site == "YouTube" {
            var queryStart = start + 1
            while queryStart < tokens.count, searchGlue.contains(tokens[queryStart]) { queryStart += 1 }
            return queryStart < tokens.count ? "search youtube for \(originals[queryStart...].joined(separator: " "))" : nil
        }
        guard start < tokens.count else { return nil }
        let query = tokens[start...]
        // "ابحث عن مطاعم وافتح كروم", "ابحث عن مطعم واتصل فيه": a second command after the query.
        // The English parser would search for the whole rest, so the LLM gets it.
        if query.dropFirst().contains(where: startsSecondCommand) { return nil }
        // Files, mail, messages and photos are the owner's own things: never a public web search.
        if query.contains(where: { personalWords.contains(RioArabicVocabulary.stripArticle($0)) }) { return nil }
        // The query is the user's own words, not the matching spelling ("قريبة", not "قريبه").
        return "search for \(originals[start...].joined(separator: " "))"
    }

    private static func isGoogle(_ word: String) -> Bool {
        word.lowercased() == "google" || RioArabicVocabulary.apps[RioArabicVocabulary.key(for: word)] == "Google"
    }

    /// Words that make a search about the owner's own files, mail, messages or photos.
    private static let personalWords: Set<String> = [
        "ملف", "ملفات", "مستند", "مستندات", "ايميل", "ايميلات", "بريد", "رساله", "رسائل", "رسايل", "مسج", "مسجات",
        "صوره", "صور", "صوري", "فايل", "واتساب", "رقم", "جهات", "محادثه",
    ]

    /// "وافتح", "واتصل", "وارسله", "وابعث", "وكلمه": "و" written on a verb starts a second command.
    private static func startsSecondCommand(_ token: String) -> Bool {
        guard token.hasPrefix("و"), token.count >= 3 else { return false }
        let verb = String(token.dropFirst())
        if isCommandVerb(verb) || secondPersonCommand(verb) != nil { return true }
        let otherVerbs = ["اتصل", "ارسل", "ابعث", "كلم", "اكتب", "قول", "خبر", "شارك", "احفظ", "ذكرني", "حط", "سوي"]
        return otherVerbs.contains { verb.hasPrefix($0) }
    }

    // MARK: Time left

    private static func timeLeft(_ first: String, _ words: [String]) -> String? {
        guard words.contains(where: { remainingWords.contains($0) }),
              !words.contains(where: { ["بطاريه", "شحن", "تحميل", "بيانات", "مساحه"].contains($0) }) else { return nil }
        // Without a timer word, only "how much is left" itself: "كم باقي على المغرب" (prayer),
        // "على الاجتماع" (a meeting) or "على رمضان" (a date) is a question for the LLM.
        let hasTimerWord = words.contains { timerWords.contains($0) || ["منبه", "مؤقت"].contains($0) }
        let timeLeftWords: Set<String> = ["كم", "وقت", "من", "لي", "ثانيه", "ثواني", "دقيقه", "دقايق", "دقائق", "ساعه", "ساعات"]
        if !hasTimerWord, !words.allSatisfy({ remainingWords.contains($0) || timeLeftWords.contains($0) }) { return nil }
        if first == "كم" || words.contains("كم") || words.contains("وقت") { return "how much time is left" }
        return nil
    }

    // MARK: Timers

    private static func timer(_ first: String, _ words: [String], _ originals: [String]) -> String? {
        if cancelVerbs.contains(first) || cancelVerbs.contains(RioArabicVocabulary.stripArticle(first)) {
            return "cancel the timer"
        }
        guard let seconds = duration(words), (1...RioTimerDuration.maxSeconds).contains(seconds) else { return nil }
        let spoken = "set a timer for \(RioTimerDuration.spoken(seconds))"
        guard let label = timerLabel(words, originals) else { return spoken }
        return "\(spoken) called \(label)"
    }

    /// "عشرين دقيقة للشاي" -> "الشاي": the word after "لل" (for the) or after "عشان"/"اسمه"
    /// (for, called), in the speaker's own spelling.
    private static func timerLabel(_ words: [String], _ originals: [String]) -> String? {
        let markers: Set<String> = ["عشان", "علشان", "اسمه", "باسم", "حق", "حقت"]
        for (index, word) in words.enumerated() {
            let afterFor = String(word.dropFirst(2))
            if word.hasPrefix("لل"), word.count >= 4, !timerWords.contains(afterFor), !isDurationWord(afterFor) {
                return "ال" + originals[index].dropFirst(2)
            }
            if markers.contains(word), index + 1 < words.count, !isDurationWord(words[index + 1]) {
                return originals[index + 1]
            }
        }
        return nil
    }

    private static func isDurationWord(_ word: String) -> Bool {
        unitSeconds[word] != nil || RioArabicVocabulary.durationNumbers[word] != nil || Int(word) != nil
    }

    private static let unitSeconds: [String: Int] = [
        "ثانيه": 1, "ثواني": 1, "ثوان": 1, "ثانيتين": 2, "ثانيتان": 2,
        "دقيقه": 60, "دقايق": 60, "دقائق": 60, "دقيقتين": 120, "دقيقتان": 120,
        "ساعه": 3600, "ساعات": 3600, "ساعتين": 7200, "ساعتان": 7200,
    ]
    /// Two of the unit ("دقيقتين" is two minutes) -> the unit's seconds.
    private static let dualUnits: [String: Int] = [
        "ثانيتين": 1, "ثانيتان": 1, "دقيقتين": 60, "دقيقتان": 60, "ساعتين": 3600, "ساعتان": 3600,
    ]
    /// One of the unit, said with no number ("تايمر دقيقة" is one minute).
    private static let singularUnits: Set<String> = ["ثانيه", "دقيقه", "ساعه"]

    /// "خمس دقائق", "ساعتين", "نص ساعة", "ربع ساعة", "5 دقائق وثلاثين ثانية", "خمسه وعشرين
    /// دقيقه", "دقيقتين ونص" (and a half: half of the unit before it), "ساعة وربع", "دقيقة".
    private static func duration(_ words: [String]) -> Int? {
        var total = 0.0
        var found = false
        var lastUnit: Int?
        // "وخمس" is "و" + "خمس"; "وعشرين" stays whole so "خمسه وعشرين" reads as 25.
        let words = words.map { word -> String in
            word.hasPrefix("و") && word.count > 3 && unitSeconds[word] == nil && RioArabicVocabulary.durationNumbers[word] == nil
                && !["ونصف", "وربع"].contains(word) ? String(word.dropFirst()) : word
        }
        var index = 0
        while index < words.count {
            let word = words[index]
            let nextIsUnit = index + 1 < words.count && unitSeconds[words[index + 1]] != nil
            // "ساعه الا ربع": an hour less a quarter.
            if word == "الا", index + 1 < words.count, let fraction = fraction(words[index + 1], attached: false), let unit = lastUnit {
                total -= fraction * Double(unit)
                lastUnit = nil
                index += 2
                continue
            }
            if let fraction = fraction(word, attached: true) ?? (nextIsUnit ? nil : fraction(word, attached: false)),
               let unit = lastUnit {
                total += fraction * Double(unit)
                lastUnit = nil
                index += 1
                continue
            }
            if let unit = dualUnits[word] {
                total += Double(unit * 2)
                lastUnit = unit
                found = true
            } else if let value = quantity(words, at: index), value.next < words.count, let unit = unitSeconds[words[value.next]] {
                total += value.amount * Double(unit)
                lastUnit = unit
                found = true
                index = value.next
            } else if singularUnits.contains(word), let unit = unitSeconds[word] {
                total += Double(unit)
                lastUnit = unit
                found = true
            }
            index += 1
        }
        return found ? Int(total.rounded()) : nil
    }

    /// "ونص"/"ونصف"/"وربع" (attached) or a bare "نص"/"ربع" with no unit after it: a share of the
    /// unit said before it.
    private static func fraction(_ word: String, attached: Bool) -> Double? {
        let bare = attached ? (word.hasPrefix("و") ? String(word.dropFirst()) : nil) : word
        switch bare {
        case "نص", "نصف": return 0.5
        case "ربع": return 0.25
        default: return nil
        }
    }

    /// A count (digits or words, "خمسه وعشرين" is 25), or a fraction word ("نص"/"ربع" are half
    /// and a quarter of the unit that follows), and the index after it.
    private static func quantity(_ words: [String], at index: Int) -> (amount: Double, next: Int)? {
        let word = words[index]
        if let value = Int(word) { return (Double(value), index + 1) }
        switch word {
        case "نص", "نصف": return (0.5, index + 1)
        case "ربع": return (0.25, index + 1)
        default: break
        }
        if let spoken = RioArabicVocabulary.number(in: words, at: index) { return (Double(spoken.value), spoken.next) }
        return nil
    }
}
