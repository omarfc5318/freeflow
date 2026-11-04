import Foundation

/// The Whisper prompt for an action-key session: the verbs Rio understands and the apps on
/// this Mac, so "open Chrome" is not heard as "We are hoping for a win". A plain comma list,
/// the only prompt shape measured as safe (see TranscriptionRequestCore), trimmed to the same
/// token budget as the dictation vocabulary.
enum RioCommandPrompt {
    /// Short command words and phrases, most common first. Kept small so most of the budget
    /// goes to app names.
    static let commandTerms: [String] = [
        "Rio", "open", "quit", "close", "switch to", "hide", "volume up", "volume down", "mute",
        "lock the screen", "screenshot", "set a timer", "remind me", "search for", "play", "pause",
        "next song", "scroll down", "minimize", "full screen", "empty the trash", "do not disturb",
        "what's on my calendar", "join my meeting", "read my last message", "press enter"
    ]

    /// Terms in priority order: the command words, the apps running now, then every other
    /// installed app. The caller passes them to `TranscriptionRequestCore.vocabularyPrompt`.
    static func terms(runningAppNames: [String], installedAppNames: [String]) -> [String] {
        commandTerms + runningAppNames + installedAppNames
    }
}
