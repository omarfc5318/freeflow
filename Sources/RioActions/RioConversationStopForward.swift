import Foundation

/// What a conversation-mode bare stop does when nothing of Rio's was going (no ringing timer,
/// task, translator or voice). Only a plain "stop" goes on to the parser's stop, which pauses
/// playing media; the silence words ("be quiet", "shut up", "enough", "اسكت", "كفاية") only ever
/// ask Rio to stop talking, so they never touch the owner's music and say nothing.
///
/// "Rio stopped talking a moment ago" counts as having stopped something: the listener only
/// delivers a phrase after a pause, by which time Rio has often just finished.
enum RioConversationStopForward {
    /// Words that make a stop a silence request (the plain stop words are "stop", "وقف" and
    /// their forms; everything else in `RioConversationCommands.bareStop` is silence).
    private static let silenceWords: Set<String> = [
        "quiet", "shut", "talking", "enough", "hush", "shush", "silence",
        "اسكت", "كفاية", "كفايه", "كفى", "بس", "خلاص"
    ]

    /// The command to hand to the parser, or nil to just acknowledge.
    static func forwardedCommand(
        for transcript: String,
        stoppedSomething: Bool,
        isRioSpeaking: Bool,
        secondsSinceRioSpoke: TimeInterval?
    ) -> String? {
        guard !stoppedSomething, !isRioSpeaking else { return nil }
        if let since = secondsSinceRioSpoke, since < RioConversationBargeIn.echoTailSeconds { return nil }
        guard RioConversationCommands.bareStop(transcript) == .stop else { return nil }
        let words = RioConversationCommands.commandWords(transcript)
        guard !words.contains(where: silenceWords.contains) else { return nil }
        return "stop"
    }
}
