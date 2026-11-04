import Foundation

/// Phrases for Rio's writing actions (builder O): rewrite the last dictation in place, write for
/// me into the focused field, and smart paste. Pure, no AppKit. It runs before E's selection
/// tasks, so every pattern needs an explicit mark that it is its own: "that/it" plus a
/// closed-list edit ("make that more formal"), the words "last dictation" / "what I just said",
/// "write for me", or "paste it translated". Bare "fix the grammar", "improve this", "rewrite
/// that better", "translate this to X" and plain "paste" are left to the others.
enum RioWritingPhrases {
    static func parse(raw: String, simplified: String) -> RioAction? {
        let text = simplified.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!?,"))
        guard !text.isEmpty else { return nil }
        if let action = parseSmartPaste(text) { return action }
        if let action = parseEditLast(text) { return action }
        return parseWriteForMe(raw.trimmingCharacters(in: CharacterSet(charactersIn: " .!?,")))
    }

    private static let maxInstruction = 400
    private static let please = #"(?:(?:please|can you|could you|would you|rio)\s+)*"#

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = RioText.collapseWhitespace(value.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?\"")))
        guard !collapsed.isEmpty, collapsed.count <= maxInstruction else { return nil }
        return collapsed
    }

    // MARK: Edit last dictation

    /// What "that" points at when it is the last dictation.
    private static let lastRef =
        #"(?:my\s+last\s+(?:dictation|message|sentence|paragraph|text)|the\s+last\s+(?:dictation|thing\s+i\s+(?:said|dictated|typed|wrote))|what\s+i\s+(?:just\s+)?(?:said|dictated|typed|wrote)|the\s+last\s+thing\s+i\s+(?:said|dictated))"#
    private static let thatRef = #"(?:that|it|this)"#

    /// Adjectives that make "make that ..." unambiguously an edit (never "make it bigger/louder").
    private static let styleWords =
        #"(?:(?:more|less|a\s+bit|a\s+little|much)\s+)*(?:formal|informal|casual|professional|polite|friendly|friendlier|warm|warmer|direct|concise|brief|short|shorter|longer|clear|clearer|simple|simpler|nicer|funnier|funny|natural|persuasive|confident|positive|apologetic|enthusiastic|detailed|wordy|polished|respectful|diplomatic|firm|firmer|softer|gentler|punchier)"#

    /// "this paragraph", "the selection": a named selection is never the last dictation.
    static let selectionNoun =
        #"(?:(?:this|that|the|my)\s+(?:paragraph|sentence|text|email|message|section|passage|line|part|selection|selected\s+text|highlighted\s+text|draft|reply|post)|selection|the\s+selected\s+text|what\s+i\s+(?:selected|highlighted))\b"#

    private static func parseEditLast(_ s: String) -> RioAction? {
        let editVerbs = #"(?:rewrite|reword|rephrase|redo)"#
        let ref = "(?:\(thatRef)|\(lastRef))"
        // "rewrite this paragraph to sound more confident" is about the selection: not ours.
        if RioText.matches("^\(please)(?:\(editVerbs)|make|improve|polish|proofread|fix|clean\\s+up|shorten|simplify)\\s+(?:.+\\s+)?\(selectionNoun)", s) {
            return nil
        }
        // "fix the grammar", "fix the spelling in that": the plan's #44 edits, no selection needed.
        if let g = RioText.firstMatch("^\(please)fix\\s+(?:the\\s+|my\\s+)?(grammar|spelling|grammar\\s+and\\s+spelling|spelling\\s+and\\s+grammar|punctuation)(?:\\s+(?:in|of|on)\\s+\(thatRef))?$", in: s),
           let what = clean(g[1]) {
            return .editLastDictation(instruction: "fix the \(what)")
        }
        // "improve that", "rewrite it", "polish this", "clean that up", "rewrite that better".
        if let g = RioText.firstMatch("^\(please)(improve|polish|proofread|rewrite|reword|rephrase|clean\\s+up|tidy\\s+up)\\s+\(thatRef)(?:\\s+up)?(?:\\s+(better|please|properly|again))?$", in: s),
           let verb = clean(g[1]) {
            let better = g[2].map { $0.lowercased() == "better" ? " better" : "" } ?? ""
            return .editLastDictation(instruction: "\(verb.lowercased()) it\(better)")
        }
        if let g = RioText.firstMatch("^\(please)(clean|tidy)\\s+\(thatRef)\\s+up$", in: s), let verb = clean(g[1]) {
            return .editLastDictation(instruction: "\(verb.lowercased()) it up")
        }
        // "make that more formal", "make it shorter", "make that sound friendlier".
        if let g = RioText.firstMatch("^\(please)make\\s+\(ref)\\s+(?:sound\\s+|be\\s+)?(\(styleWords)(?:\\s+(?:and|but|yet)\\s+(?:\(styleWords)))*)$", in: s),
           let style = clean(g[1]) {
            return .editLastDictation(instruction: "make it \(style)")
        }
        // "make my last dictation ..." / "make what I just said ...": the reference is explicit, so anything goes.
        if let g = RioText.firstMatch("^\(please)make\\s+\(lastRef)\\s+(.+)$", in: s), let rest = clean(g[1]) {
            return .editLastDictation(instruction: "make it \(rest)")
        }
        // "shorten that", "formalize it": one-word edits.
        if let g = RioText.firstMatch("^\(please)(shorten|lengthen|formali[sz]e|simplify|soften|expand|condense)\\s+(?:\(thatRef)|\(lastRef))$", in: s),
           let verb = clean(g[1]) {
            return .editLastDictation(instruction: "\(verb) it")
        }
        // "rewrite that more formally", "rephrase it in Arabic": needs an instruction ("rewrite that
        // better" is E's improve).
        if let g = RioText.firstMatch("^\(please)\(editVerbs)\\s+\(ref)\\s+(?:to\\s+be\\s+|so\\s+(?:it|that)\\s+(?:is|sounds|reads)\\s+|as\\s+)?(.+)$", in: s),
           let rest = clean(g[1]), !isFiller(rest) {
            return .editLastDictation(instruction: rest)
        }
        // "edit my last dictation to be shorter", "change what I just said to ...". Only with an
        // explicit last-dictation reference ("change it to dark mode" is not ours).
        if let g = RioText.firstMatch("^\(please)(?:edit|change|fix|correct|update)\\s+\(lastRef)\\s*(.*)$", in: s),
           let rest = clean(g[1]) {
            return .editLastDictation(instruction: unwrapLeadIn(rest))
        }
        if RioText.matches("^\(please)(?:edit|fix|correct)\\s+\(lastRef)$", s) { return nil }
        // "add a thank you at the end", "add a greeting at the start of that".
        let addable = #"(?:an?\s+|some\s+)?(?:thank\s+you|thanks|greeting|sign\s?off|closing|signature|call\s+to\s+action|apology|sorry|emoji|smiley|question|question\s+mark|exclamation\s+mark|period|full\s+stop|best\s+regards|kind\s+regards|regards|cheers|cc|p\s?s|hello|hi|please)\b(?:\s+\S+){0,5}?"#
        let place = #"(?:at|to)\s+the\s+(end|start|beginning|top|bottom)(?:\s+of\s+(?:\#(thatRef)|\#(lastRef)))?"#
        if let g = RioText.firstMatch("^\(please)add\\s+(\(addable))\\s+\(place)$", in: s),
           let what = clean(g[1]), let spot = g[2] {
            return .editLastDictation(instruction: "add \(what) at the \(spot)")
        }
        // "fix the grammar of my last dictation", "fix the spelling in what I just said".
        if let g = RioText.firstMatch("^\(please)fix\\s+(?:the\\s+|my\\s+)?(grammar|spelling|grammar\\s+and\\s+spelling|spelling\\s+and\\s+grammar|punctuation)\\s+(?:in|of|on)\\s+\(lastRef)$", in: s),
           let what = clean(g[1]) {
            return .editLastDictation(instruction: "fix the \(what)")
        }
        // "say that in Arabic", "put that in French", "write that in a more formal tone".
        if let g = RioText.firstMatch("^\(please)(?:say|put|write|type)\\s+(?:\(thatRef)|\(lastRef))\\s+in\\s+(\(languageNames))$", in: s),
           let lang = clean(g[1]) {
            return .editLastDictation(instruction: "translate it into \(lang.capitalized)")
        }
        if let g = RioText.firstMatch("^\(please)(?:say|put|write|type)\\s+(?:\(thatRef)|\(lastRef))\\s+in\\s+(?:a|an)\\s+(\(styleWords))\\s+(?:way|tone|style|voice)$", in: s),
           let style = clean(g[1]) {
            return .editLastDictation(instruction: "make it \(style)")
        }
        return nil
    }

    private static let languageNames =
        #"(?:arabic|english|french|spanish|german|italian|portuguese|hindi|urdu|persian|farsi|turkish|russian|chinese|japanese|korean|dutch|swedish|greek|hebrew|bengali|indonesian)"#

    /// "rewrite that better" / "redo that please" carry no instruction.
    private static func isFiller(_ rest: String) -> Bool {
        RioText.matches(#"^(?:better|again|please|better please|properly|right|correctly|differently)$"#, rest.lowercased())
    }

    private static func unwrapLeadIn(_ rest: String) -> String {
        RioText.replacing(#"^(?:so\s+(?:it|that)\s+(?:is|sounds|reads|says)\s+|to\s+be\s+|to\s+say\s+|to\s+|and\s+)"#, with: "", in: rest)
    }

    // MARK: Write for me

    private static let docTypes =
        #"(?:cover\s+letter|reply|response|apology|thank\s?-?\s?you(?:\s+(?:note|message|email|text))?|follow\s?-?\s?up|review|caption|bio|post|tweet|linkedin\s+post|paragraph|summary|description|intro|introduction|announcement|status\s+update|update|resignation(?:\s+letter)?|complaint|invitation|recommendation|speech|toast|message)"#

    private static func parseWriteForMe(_ original: String) -> RioAction? {
        let s = original
        // "draft a follow up email to the Falak team" is a mail draft (the email drafter's), never
        // text typed into whatever field is focused.
        if RioText.matches("^\(please)(?:write|compose|draft)\\s+(?:me\\s+|us\\s+)?(?:an?|the|some)\\s+(?:\\S+\\s+){0,2}e\\s?-?\\s?mails?\\b", s) {
            return nil
        }
        // "write for me an apology to my landlord", "write me a reply saying yes", "compose ...".
        if let g = RioText.firstMatch("^\(please)(?:write|compose|draft|type\\s+up)\\s+for\\s+me\\s+(.+)$", in: s),
           let body = clean(stripTail(g[1])) {
            return .writeForMe(instruction: body)
        }
        // "write me a reply ..." needs a document type: "write me an email" is the email drafter's.
        if let g = RioText.firstMatch("^\(please)(?:write|compose|draft)\\s+(?:me|us)\\s+((?:an?|the|some)\\s+\(docTypes)\\b.*)$", in: s),
           let body = clean(stripTail(g[1])) {
            return .writeForMe(instruction: body)
        }
        if let g = RioText.firstMatch("^\(please)(?:compose|draft)\\s+((?:an?|the|some)\\s+\(docTypes)\\b.*)$", in: s),
           let body = clean(stripTail(g[1])) {
            return .writeForMe(instruction: body)
        }
        // "write a reply saying I'll be late", "write a thank you note to Sam": a document type
        // is required, so "write a poem about the sea" stays with the smart resolver, and
        // emails stay with the email drafter.
        if let g = RioText.firstMatch("^\(please)write\\s+((?:an?|the|some)\\s+\(docTypes)\\b.*)$", in: s),
           let body = clean(stripTail(g[1])) {
            return .writeForMe(instruction: body)
        }
        return nil
    }

    private static func stripTail(_ value: String?) -> String? {
        guard let value else { return nil }
        return RioText.replacing(#"\s+(?:and\s+)?(?:type|put|paste)\s+(?:it|that)(?:\s+(?:in|here|for\s+me))?$"#, with: "", in: value)
    }

    // MARK: Smart paste

    private static let clip = #"(?:the\s+clipboard|my\s+clipboard|what\s+i\s+(?:just\s+)?copied|the\s+copied\s+text|the\s+text\s+i\s+copied)"#
    private static let pasteObject = #"(?:it|that|this|\#(clip))"#
    private static let transforms =
        #"(?:translated|summari[sz]ed|shortened|shorter|rewritten|cleaned\s+up|polished|simplified|proofread|formatted|reworded|rephrased|expanded|condensed|capitali[sz]ed|lowercased|uppercased|sorted|fixed)"#

    private static func parseSmartPaste(_ s: String) -> RioAction? {
        // "smart paste", "smart paste as bullet points".
        if let g = RioText.firstMatch("^\(please)smart\\s+paste(?:\\s+(.+))?$", in: s) {
            return .smartPaste(instruction: clean(g[1]) ?? "clean it up")
        }
        // "paste it translated to Arabic", "paste that summarized", "paste the clipboard shorter".
        if let g = RioText.firstMatch("^\(please)paste\\s+(?:\(pasteObject)\\s+)?(\(transforms)\\b.*)$", in: s),
           let instruction = clean(g[1]) {
            return .smartPaste(instruction: instruction)
        }
        // "paste it as bullet points", "paste that in Arabic", "paste it but shorter". Plain
        // "paste as plain text" is the keyboard shortcut (I's), not ours.
        if let g = RioText.firstMatch("^\(please)paste\\s+\(pasteObject)\\s+(as\\s+.+|in\\s+(?:\(languageNames))|but\\s+.+|with\\s+.+|without\\s+.+|more\\s+.+|less\\s+.+)$", in: s),
           let instruction = clean(g[1]) {
            return .smartPaste(instruction: instruction)
        }
        // "paste a summary of it", "paste a translation of that into French".
        if let g = RioText.firstMatch("^\(please)paste\\s+(?:an?\\s+|the\\s+)?((?:summary|translation|short\\s+version|shorter\\s+version|formal\\s+version|bullet\\s+points?|tl\\s?dr)\\s+of\\s+\(pasteObject)(?:\\s+.+)?)$", in: s),
           let instruction = clean(g[1]) {
            return .smartPaste(instruction: instruction)
        }
        return nil
    }
}
