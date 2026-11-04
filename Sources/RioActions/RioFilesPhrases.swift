import Foundation

/// "open my resume", "show me the Hala deck in Finder", "find my tax return". Pure.
///
/// A phrase is only claimed when the object is clearly a document or folder: a file-type word
/// (pdf, resume, homework, deck…), a file extension, or a well-known folder. "open Chrome",
/// "open YouTube", "open Google Slides" and "open slides" are never claimed, so they still reach
/// the app and website logic.
enum RioFilesPhrases {
    private static let openVerbs = #"(?:open(?:\s+up)?|pull\s+up|bring\s+up|show(?:\s+me)?|display|get(?:\s+me)?|let\s+me\s+(?:see|look\s+at))"#
    private static let revealVerbs = #"(?:find(?:\s+me)?|locate|reveal|where(?:s|\s+is)|where\s+did\s+i\s+(?:put|save|download))"#

    private static let extensions = "pdf|docx?|pptx?|xlsx?|csv|txt|md|pages|key|numbers|png|jpe?g|zip|tex|ipynb"

    private static let documentWords = #"\b(?:pdfs?|docx?|pptx?|xlsx?|csv|resumes?|cv|curriculum\s+vitae|homework|hw|assignments?|syllabus|syllabi|transcripts?|lecture\s+(?:notes|slides)|slides|deck|presentation|spreadsheet|document|documents|file|files|folder|directory|paper|essay|thesis|report|invoice|receipt|contract|proposal|lease|worksheet|study\s+guide|cheat\s+sheet|midterm|exam|quiz|problem\s+set|pset|textbook|screenshots?|tax\s+returns?|taxes|w\s?2|1099)\b"#

    private static let brandPrefix = #"^(?:google|microsoft|apple|adobe|office|ms)\b"#
    private static let determiner = #"^(?:my|the|that|this|a|an|our)\s+"#

    /// "a new Google Doc" is a new web document, never a file search for "new google".
    private static let newGoogleFile = #"^(?:(?:a|an|the)\s+)?(?:new|blank|fresh)\s+(google\s+)?(docs?|documents?|sheets?|spreadsheets?|slides?|presentations?|decks?|forms?)$"#
    /// Questions memory may answer ("where's my midterm" after "remember my midterm is in Wellman 2").
    private static let memoryQuestion = #"^(?:where(?:s|\s+is|\s+are)|where\s+did\s+i\s+(?:put|leave))\s+(.+)$"#

    static func parse(simplified: String) -> RioAction? {
        // "show desktop" means clear the windows away (the system parser's F11), not the folder.
        if RioText.matches(#"^(?:show|reveal|go\s+to)\s+(?:me\s+)?(?:the\s+|my\s+)?desktop$"#, simplified) { return nil }
        if let groups = RioText.firstMatch(memoryQuestion, in: simplified), let object = groups[1] {
            let thing = RioText.replacing(determiner, with: "", in: RioText.collapseWhitespace(object))
            if RioRememberedFacts.knows(thing) { return .recall(query: thing) }
        }
        if let groups = RioText.firstMatch("^\(openVerbs)\\s+(.+)$", in: simplified), let object = groups[1] {
            if let groups = RioText.firstMatch(newGoogleFile, in: RioText.collapseWhitespace(object)), let kind = groups[2] {
                // Without "Google" ("a new presentation") it may be Keynote or Word: the resolver decides.
                guard groups[1] != nil else { return nil }
                return newGoogleFileURL(kind).map { .openURL($0) }
            }
            return action(for: object, reveal: false)
        }
        if let groups = RioText.firstMatch("^\(revealVerbs)\\s+(.+)$", in: simplified), let object = groups[1] {
            return action(for: object, reveal: true)
        }
        return nil
    }

    /// docs.new, sheets.new, slides.new, forms.new: Google's own "new file" addresses.
    private static func newGoogleFileURL(_ kind: String) -> URL? {
        let word = kind.lowercased()
        let host: String
        if word.hasPrefix("doc") { host = "docs.new" }
        else if word.hasPrefix("sheet") || word.hasPrefix("spreadsheet") { host = "sheets.new" }
        else if word.hasPrefix("form") { host = "forms.new" }
        else { host = "slides.new" }
        return URL(string: "https://\(host)")
    }

    private static func action(for rawObject: String, reveal initialReveal: Bool) -> RioAction? {
        var object = RioText.collapseWhitespace(rawObject)
        var reveal = initialReveal
        // "... in Finder" reveals; "... in Preview" is ignored (the default app opens it).
        let finderTail = #"\s+(?:in|on|with)\s+(?:the\s+|a\s+)?finder(?:\s+window)?$"#
        if RioText.matches(finderTail, object) {
            reveal = true
            object = RioText.replacing(finderTail, with: "", in: object)
        }
        let viewerTail = #"\s+(?:in|with|using)\s+(?:the\s+)?(?:preview|word|pages|acrobat|adobe\s+acrobat|adobe\s+reader|chrome|google\s+chrome|safari|textedit|keynote|powerpoint|excel|numbers|vs\s?code)(?:\s+app)?$"#
        object = RioText.replacing(viewerTail, with: "", in: object)

        // "resume dot pdf" is only a file when a determiner makes it one ("open file dot txt"
        // stays a spoken domain for the website logic).
        let spokenDot = RioText.matches(#"\s+dot\s+(?:\#(extensions))\b"#, object)
        object = RioText.replacing(#"\s+dot\s+(\#(extensions))\b"#, with: ".$1", in: object)
        var hasDeterminer = false
        if RioText.matches(determiner, object) {
            hasDeterminer = true
            object = RioText.replacing(determiner, with: "", in: object)
        }
        object = object.trimmingCharacters(in: CharacterSet(charactersIn: " .,"))
        guard !object.isEmpty, !RioText.matches(brandPrefix, object) else { return nil }

        // "hw 6 dot pdf" is a file: a spoken domain has no space before its dot.
        if spokenDot, !hasDeterminer, !RioText.matches(#"\s\S+\.(?:\#(extensions))\b"#, object) { return nil }
        guard claims(object, hasDeterminer: hasDeterminer) else { return nil }
        return reveal ? .revealFile(query: object) : .openFile(query: object)
    }

    private static func claims(_ object: String, hasDeterminer: Bool) -> Bool {
        if RioWellKnownFolder.match(spoken: object) != nil { return true }
        if RioText.matches(#"\bfile\s+menu\b"#, object) { return false }
        if RioText.matches(#"\b[A-Za-z0-9_-]+\.(?:\#(extensions))\b"#, object) { return true }
        guard RioText.matches(documentWords, object) else { return false }
        let wordCount = object.split(separator: " ").count
        return hasDeterminer || wordCount >= 2
    }
}
