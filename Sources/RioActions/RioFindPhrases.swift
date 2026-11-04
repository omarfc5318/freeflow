import Foundation

/// Builder Q's phrasings. Pure, no AppKit. This parser runs before H's file phrases, so it only
/// claims what is unambiguously its own:
/// - "find the PDF Ali sent me last week", "the link from Sarah yesterday" (a person is named);
/// - "find the file I downloaded yesterday" (a time is named with downloaded/received/got);
/// - "organize my Downloads", "tidy up my downloads folder";
/// - "copy the text from my screen".
/// "find my resume", "open my tax return" and "find the pdf" stay with H.
enum RioFindPhrases {
    static func parse(raw: String, simplified: String) -> RioAction? {
        let text = RioText.collapseWhitespace(simplified)
        if matchesOrganize(text) { return .organizeDownloads }
        if matchesCopyText(text) { return .copyTextFromScreen }
        return findThing(text)
    }

    // MARK: Organize Downloads

    private static func matchesOrganize(_ text: String) -> Bool {
        RioText.matches(
            #"^(?:please\s+|can\s+you\s+|could\s+you\s+)?(?:organi[sz]e|clean\s+up|tidy(?:\s+up)?|sort(?:\s+out)?|declutter)\s+(?:up\s+)?(?:my\s+|the\s+)?downloads?(?:\s+folder)?(?:\s+please)?$"#,
            text
        )
    }

    // MARK: Copy text from the screen

    private static func matchesCopyText(_ text: String) -> Bool {
        // On-device OCR of whatever is showing: the screen, or the image, video or PDF on it.
        let place = #"(?:the\s+|my\s+|this\s+|that\s+)?(?:screen|window|display|image|picture|photo|pic|video|pdf|document|slide|screenshot)"#
        let tail = #"(?:\s+(?:to\s+)?(?:the\s+|my\s+)?clipboard)?(?:\s+please)?$"#
        let patterns = [
            #"^(?:please\s+)?(?:copy|grab|extract|pull|get|scrape|lift|take)\s+(?:all\s+)?(?:of\s+)?(?:the\s+|my\s+)?text\s+(?:from|on|off|in|of)\s+"# + place + tail,
            #"^(?:please\s+)?copy\s+(?:everything|all\s+the\s+text|all\s+text|whats|what\s+is)\s+(?:on|from|in)\s+"# + place + tail,
            #"^(?:please\s+)?(?:ocr|read\s+and\s+copy)\s+"# + place + tail,
        ]
        return patterns.contains { RioText.matches($0, text) }
    }

    // MARK: Find that thing

    private static let findVerbs = #"(?:find(?:\s+me)?|search\s+for|look\s+for|locate|where(?:s|\s+is)|show\s+me|pull\s+up|get\s+me|dig\s+up|bring\s+up)"#
    private static let sentVerbs = "sent|shared|texted|messaged|emailed|mailed|airdropped|forwarded|gave|dropped"
    private static let timeWords = #"(?:yesterday|today|tonight|last\s+(?:night|week|month|\w+day)|this\s+(?:morning|week|month)|(?:in\s+the\s+)?(?:last|past)\s+\w+\s+(?:hours?|days?|weeks?|months?)|\w+\s+(?:days?|weeks?|months?)\s+ago|recently|lately|on\s+\w+day)"#
    private static let thingWords = #"(?:pdfs?|docs?|documents?|files?|links?|urls?|photos?|pictures?|pics?|images?|screenshots?|videos?|clips?|attachments?|slides|deck|presentation|spreadsheet|thing|stuff|invoices?|receipts?|resume|contract|recording|song|zip)"#
    private static let nonPersonAfterFrom: Set<String> = [
        "downloads", "download", "desktop", "documents", "pictures", "movies", "music", "icloud", "finder", "home",
        "the", "a", "an", "this", "that", "our", "your", "last", "yesterday", "today", "earlier", "recently", "lately",
        "on", "in", "at", "my",
    ]
    private static let relations: Set<String> = [
        "mom", "dad", "mother", "father", "brother", "sister", "boss", "wife", "husband", "friend", "professor",
        "prof", "teacher", "manager", "uncle", "aunt", "mum",
    ]

    private static func findThing(_ text: String) -> RioAction? {
        guard let groups = RioText.firstMatch("^(?:please\\s+)?\(findVerbs)\\s+(.+)$", in: text), let object = groups[1] else {
            return nil
        }
        let cleaned = RioText.collapseWhitespace(object).trimmingCharacters(in: CharacterSet(charactersIn: " .,"))
        guard !cleaned.isEmpty, hasPerson(cleaned) || hasTimeAndArrival(cleaned) else { return nil }
        return .findThing(query: cleaned)
    }

    /// "ali sent me", or "from sarah" where sarah isn't a folder, a determiner or a time.
    private static func hasPerson(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if RioText.matches("\\b[a-z][a-z.' ]*\\b(?:\(sentVerbs))\\s+(?:it\\s+|that\\s+|this\\s+)?(?:over\\s+)?(?:to\\s+)?(?:me|us)\\b", lowered) {
            return true
        }
        // "from <person>" only counts next to a file-like word: "a flight from Doha" is not a search here.
        guard RioText.matches("\\b\(thingWords)\\b", lowered),
              let groups = RioText.firstMatch(#"\bfrom\s+(\S+)(?:\s+(\S+))?"#, in: lowered), let first = groups[1] else { return false }
        if first == "my" { return groups[2].map { relations.contains($0) } ?? false }
        return !nonPersonAfterFrom.contains(first)
    }

    /// "the pdf i downloaded last week": H would ignore the time, Q honours it.
    private static func hasTimeAndArrival(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return RioText.matches(#"\b(?:downloaded|received|got)\b"#, lowered) && RioText.matches("\\b\(timeWords)\\b", lowered)
    }
}
