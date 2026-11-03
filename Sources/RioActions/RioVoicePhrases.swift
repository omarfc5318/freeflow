import Foundation

/// Phrases for Rio's own abilities: timers, undo, help and "be quiet". Pure (no AppKit). Each
/// pattern is anchored and specific, so "open Chrome", "close Spotify", "undo typing" and
/// "press command Z" still reach their own parsers.
enum RioVoicePhrases {
    static func parse(raw: String, simplified: String) -> RioAction? {
        let text = simplified.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!?,"))
        guard !text.isEmpty else { return nil }
        if RioTimerPhrases.isCancel(text) { return .cancelTimer }
        if RioTimerPhrases.isStatus(text) { return .timerStatus }
        if isUndo(text) { return .undoLast }
        if isHelp(text) { return .showHelp }
        return RioTimerPhrases.parseStart(text)
    }

    private static let undoPatterns = [
        #"^(?:(?:oops|ok|okay|sorry)\s+)?(?:undo|revert|reverse)(?:\s+(?:that|it|this|the last (?:thing|action|one|command)))?$"#,
        #"^(?:put\s+(?:it|that|this)\s+back|take\s+(?:it|that)\s+back|never\s?mind)$"#,
    ]

    private static let helpPatterns = [
        #"^(?:help|help me|show help|show me the help|show commands|show me the commands|show me what you can do)$"#,
        #"^what (?:can|could) (?:you|i)(?: do| say| ask(?: you)?| ask rio)$"#,
        #"^what (?:are your commands|commands do you know|commands can i use|can you do for me)$"#,
        #"^what do you know how to do$"#,
    ]

    static func isUndo(_ text: String) -> Bool {
        undoPatterns.contains { RioText.matches($0, text) }
    }

    static func isHelp(_ text: String) -> Bool {
        helpPatterns.contains { RioText.matches($0, text) }
    }
}
