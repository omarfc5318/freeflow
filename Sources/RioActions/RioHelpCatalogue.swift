import Foundation

/// What the help sheet shows: every ability grouped by category with phrases that really work.
/// Pure data; `RioHelpCatalogueTests` checks the local ones against the real parser.
struct RioHelpCategory: Equatable {
    let title: String
    /// SF Symbol name.
    let symbol: String
    let examples: [String]
}

enum RioHelpCatalogue {
    /// Arabic commands (Gulf and MSA) that work with no network; the tests run them through the table.
    static let arabicExamples = ["ريو افتح كروم", "ريو ارفع الصوت", "ريو شغل مؤقت لمدة خمس دقائق", "ريو افتح الحاسبة"]

    static let categories: [RioHelpCategory] = [
        RioHelpCategory(title: "Apps and websites", symbol: "square.grid.2x2", examples: [
            "open Chrome", "switch to Messages", "quit Spotify", "hide Slack", "search for best pizza near me",
        ]),
        RioHelpCategory(title: "Mac controls", symbol: "slider.horizontal.3", examples: [
            "volume up", "set the volume to 40", "mute", "next song", "take a screenshot",
        ]),
        RioHelpCategory(title: "Windows", symbol: "rectangle.split.2x1", examples: [
            "put Chrome on the left", "maximize Safari", "minimize Notes", "move this to the other screen",
        ]),
        RioHelpCategory(title: "Timers", symbol: "timer", examples: [
            "set a timer for 10 minutes", "timer 30 seconds called pasta", "how much time is left", "cancel the timer",
        ]),
        RioHelpCategory(title: "Keys and browser", symbol: "keyboard", examples: [
            "new tab", "scroll down", "go back", "press command T", "refresh",
        ]),
        RioHelpCategory(title: "Files and calendar", symbol: "calendar", examples: [
            "open my resume", "what's on my calendar today", "what's next", "join my meeting", "what's on my clipboard",
        ]),
        RioHelpCategory(title: "System", symbol: "gearshape", examples: [
            "brightness up", "turn off wifi", "dark mode on", "how much battery do I have",
        ]),
        RioHelpCategory(title: "Screen and clicks", symbol: "eye", examples: [
            "what's on my screen", "click the Submit button", "the second one", "fill in the name field with Omar",
            "find me a flight to Doha",
        ]),
        RioHelpCategory(title: "Memory and notes", symbol: "brain.head.profile", examples: [
            "remember my locker code is 4321", "what's my locker code", "forget my locker code", "note that I need to buy eggs",
        ]),
        RioHelpCategory(title: "Email and messages", symbol: "envelope", examples: [
            "draft an email to Sam about lunch", "email Sam saying I'm running late", "text mom I'm late", "reply saying sounds good",
        ]),
        RioHelpCategory(title: "Maths, units and time", symbol: "function", examples: [
            "what's 15% of 84", "5 miles in kilometers", "what time is it in Tokyo", "what's 20 percent tip on 45",
        ]),
        RioHelpCategory(title: "Translator", symbol: "globe", examples: [
            "translate what's being said", "stop translating", "say it", "translate this to Arabic",
        ]),
        RioHelpCategory(title: "Arabic", symbol: "character.bubble", examples: arabicExamples),
        RioHelpCategory(title: "Smart help", symbol: "sparkles", examples: [
            "summarize this", "translate this to Arabic", "read me the last message", "remind me to call mom at 5",
        ]),
        RioHelpCategory(title: "Undo and help", symbol: "arrow.uturn.backward", examples: [
            "undo", "put it back", "stop", "what can you do",
        ]),
    ]

    /// The one line Rio says when the help sheet opens.
    static let spokenSummary = "I can open apps, move windows, set timers, read your screen, do maths, remember things, draft emails and more. Tap anywhere to close."

    /// How long the sheet stays up on its own.
    static let autoCloseSeconds: TimeInterval = 20
}
