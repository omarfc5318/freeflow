import Foundation

/// Editing shortcuts ("copy", "select all", "undo typing") and browser control ("new tab", "scroll
/// down"). Bare "undo" and "stop" belong to G; only "undo typing" maps to a key here. Spoken
/// "plus"/"and" never appear inside a combo because the parser splits clauses on them first.
extension RioSystemPhrases {
    private static func shortcut(_ key: String, command: Bool = true, shift: Bool = false, option: Bool = false, control: Bool = false) -> RioAction {
        .pressKeys(KeyCombo(key: key, command: command, shift: shift, option: option, control: control))
    }

    static func parseShortcut(_ s: String) -> RioAction? {
        let table: [(String, RioAction)] = [
            (#"^select\s+(?:all|everything)$"#, shortcut("a")),
            (#"^copy(?:\s+(?:that|this|it|selection|the\s+selection))?$"#, shortcut("c")),
            (#"^cut(?:\s+(?:that|this|it|selection|the\s+selection))?$"#, shortcut("x")),
            (#"^paste\s+(?:without\s+formatting|as\s+plain\s+text|plain\s+text)$"#, shortcut("v", shift: true, option: true)),
            (#"^paste(?:\s+(?:it|that|here|this|now))?$"#, shortcut("v")),
            (#"^undo\s+(?:(?:that|the|my|last|this)\s+)?(?:typing|keystrokes?)$"#, shortcut("z")),
            (#"^redo(?:\s+(?:that|it|typing|the\s+typing))?$"#, shortcut("z", shift: true)),
            (#"^save(?:\s+(?:this|it|that|file|document|the\s+file|the\s+document))?$"#, shortcut("s")),
            (#"^(?:open\s+)?(?:a\s+)?new\s+window$"#, shortcut("n")),
            (#"^close\s+(?:this\s+|the\s+|current\s+|that\s+)?window$"#, shortcut("w")),
            (#"^zoom\s+in$"#, shortcut("equal")),
            (#"^zoom\s+out$"#, shortcut("minus")),
            (#"^(?:reset|actual)\s+zoom$|^actual\s+size$"#, shortcut("0")),
            (#"^(?:open\s+|show\s+)?mission\s+control$|^show\s+(?:me\s+)?all\s+(?:my\s+|the\s+)?(?:windows|open\s+windows)$"#, shortcut("up", command: false, control: true)),
            (#"^(?:exit|leave|quit|get\s+out\s+of|come\s+out\s+of)\s+(?:the\s+)?full\s?screen(?:\s+mode)?$"#, shortcut("f", control: true)),
            (#"^(?:show|reveal|go\s+to)\s+(?:me\s+)?(?:the\s+|my\s+)?desktop$"#, shortcut("f11", command: false)),
            (#"^(?:open\s+|show\s+)?(?:the\s+)?emoji(?:\s+(?:picker|keyboard|panel))?$"#, shortcut("space", control: true)),
        ]
        return table.first { RioText.matches($0.0, s) }?.1
    }

    private static let tabTarget = #"(?:the\s+|this\s+|that\s+|current\s+|my\s+|the\s+current\s+)?(?:browser\s+)?tab"#
    private static let scrollTail = #"(?:\s+(?:a\s+little\s+bit|a\s+tiny\s+bit|slightly|a\s+bit|a\s+little|a\s+lot|some|more|the\s+page|a\s+page|please))?"#
    private static let pageWord = #"(?:the\s+|this\s+)?(?:page|screen)"#

    static func parseBrowser(_ s: String) -> RioAction? {
        let table: [(String, BrowserCommand)] = [
            (#"^(?:(?:open|make|create|start|add)\s+)?(?:a\s+)?new\s+(?:browser\s+)?tab$"#, .newTab),
            (#"^(?:open|make|create)\s+another\s+(?:browser\s+)?tab$"#, .newTab),
            ("^close\\s+\(tabTarget)$", .closeTab),
            (#"^(?:reopen|restore|bring\s+back|undo\s+closing|undo\s+close)\s+(?:the\s+|my\s+)?(?:last\s+)?(?:closed\s+)?(?:last\s+)?tab$"#, .reopenTab),
            (#"^(?:(?:switch|go|jump|move)\s+to\s+(?:the\s+)?)?next\s+tab$"#, .nextTab),
            (#"^(?:(?:switch|go|jump|move)\s+to\s+(?:the\s+)?)?(?:previous|prior)\s+tab$"#, .previousTab),
            (#"^(?:go\s+back(?:\s+(?:a|one|1)\s+page)?|(?:navigate|browser|page)\s+back|back\s+a\s+page|go\s+to\s+(?:the\s+)?previous\s+page|go\s+back\s+(?:in|on)\s+(?:the\s+)?(?:browser|history))$"#, .back),
            (#"^(?:go\s+forward(?:\s+(?:a|one|1)\s+page)?|(?:navigate|browser|page)\s+forward|forward\s+a\s+page)$"#, .forward),
            (#"^(?:refresh|reload)(?:\s+(?:the|this|my|current))?(?:\s+(?:page|tab|browser|site|website))?$"#, .reload),
            ("^(?:scroll\\s+down|page\\s+down)\(scrollTail)$", .scrollDown),
            ("^(?:scroll\\s+up|page\\s+up)\(scrollTail)$", .scrollUp),
            ("^(?:(?:scroll|go|jump|skip)\\s+(?:all\\s+the\\s+way\\s+)?to\\s+(?:the\\s+)?top(?:\\s+of\\s+\(pageWord))?|(?:the\\s+)?top\\s+of\\s+\(pageWord))$", .scrollToTop),
            ("^(?:(?:scroll|go|jump|skip)\\s+(?:all\\s+the\\s+way\\s+)?to\\s+(?:the\\s+)?bottom(?:\\s+of\\s+\(pageWord))?|(?:the\\s+)?bottom\\s+of\\s+\(pageWord))$", .scrollToBottom),
            (#"^find\s+(?:on|in)\s+(?:the\s+|this\s+)?page$|^(?:open\s+)?page\s+find$"#, .find),
        ]
        return table.first { RioText.matches($0.0, s) }.map { .browser($0.1) }
    }
}
