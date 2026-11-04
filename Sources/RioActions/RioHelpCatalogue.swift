import Foundation

/// What the help sheet shows: every ability grouped by category with phrases that really work.
/// Pure data; `RioHelpCatalogueTests` runs every example through the real parser and checks it
/// lands on the action it advertises.
struct RioHelpCategory: Equatable {
    let title: String
    /// SF Symbol name.
    let symbol: String
    let examples: [String]
}

/// A key or key chord and what it does (the owner's setup; Settings can change the dictation keys).
struct RioHelpKey: Equatable {
    let keys: String
    let meaning: String
}

/// A way of talking to Rio that is not one command: a line of explanation plus phrases to say.
struct RioHelpTip: Equatable {
    let title: String
    /// SF Symbol name.
    let symbol: String
    let detail: String
    let examples: [String]
}

enum RioHelpCatalogue {
    /// Arabic commands (Gulf and MSA) that work with no network; the tests run them through the table.
    static let arabicExamples = ["ريو افتح كروم", "ريو ارفع الصوت", "ريو شغل مؤقت لمدة خمس دقائق", "ريو افتح الحاسبة"]

    /// The sheet shows the first few examples of each category; the rest are checked by the tests.
    static let shownExamples = 3

    static let categories: [RioHelpCategory] = [
        RioHelpCategory(title: "Apps and websites", symbol: "square.grid.2x2", examples: [
            "open Chrome", "switch to Messages", "quit Spotify", "hide Slack", "search for best pizza near me",
        ]),
        RioHelpCategory(title: "Mac controls", symbol: "slider.horizontal.3", examples: [
            "volume up", "next song", "turn off wifi", "set the volume to 40", "dark mode on", "how much battery do I have",
        ]),
        RioHelpCategory(title: "Windows", symbol: "rectangle.split.2x1", examples: [
            "put Chrome on the left", "maximize Safari", "move this to the other screen", "minimize Notes",
        ]),
        RioHelpCategory(title: "Timers", symbol: "timer", examples: [
            "set a timer for 10 minutes", "how much time is left", "cancel the timer", "timer 30 seconds called pasta",
        ]),
        RioHelpCategory(title: "Keys and browser", symbol: "keyboard", examples: [
            "new tab", "go back", "press command T", "scroll down", "refresh",
        ]),
        RioHelpCategory(title: "Files and calendar", symbol: "calendar", examples: [
            "open my resume", "what's on my calendar today", "join my meeting", "what's next", "what's on my clipboard",
        ]),
        RioHelpCategory(title: "Screen and clicks", symbol: "eye", examples: [
            "what's on my screen", "click the Submit button", "find me a flight to Doha", "the second one",
            "fill in the name field with Omar", "take a screenshot",
        ]),
        RioHelpCategory(title: "Memory and notes", symbol: "brain.head.profile", examples: [
            "remember my locker code is 4321", "what's my locker code", "note that I need to buy eggs", "forget my locker code",
        ]),
        RioHelpCategory(title: "Email and messages", symbol: "envelope", examples: [
            "text mom I'm late", "reply saying sounds good", "draft an email to Sam about lunch",
            "email Sam saying I'm running late",
        ]),
        RioHelpCategory(title: "Maths, units and time", symbol: "function", examples: [
            "what's 15% of 84", "5 miles in kilometers", "what time is it in Tokyo", "what's 20 percent tip on 45",
        ]),
        RioHelpCategory(title: "Translator", symbol: "globe", examples: [
            "translate what's being said", "say it", "stop translating", "translate this to Arabic",
        ]),
        RioHelpCategory(title: "Arabic", symbol: "character.bubble", examples: arabicExamples),
        RioHelpCategory(title: "Smart help", symbol: "sparkles", examples: [
            "summarize this", "explain this", "remind me to call mom at 5", "read me the last message",
        ]),
        RioHelpCategory(title: "Follow-ups and history", symbol: "arrow.triangle.2.circlepath", examples: [
            "open it again", "do the same for Spotify", "what did I say about the budget", "search my history for the budget",
        ]),
        RioHelpCategory(title: "Writing", symbol: "pencil.line", examples: [
            "make that more formal", "paste that as bullet points", "write a reply saying I'm in",
            "make that shorter", "paste that in Arabic",
        ]),
        RioHelpCategory(title: "Automations", symbol: "clock.arrow.circlepath", examples: [
            "every weekday at 8:50 open Zoom", "when AirPods connect open Spotify", "watch me",
            "run the morning setup macro", "stop watching", "list my automations",
        ]),
        RioHelpCategory(title: "Find and tidy", symbol: "magnifyingglass", examples: [
            "find the PDF Ali sent me last week", "clean up my downloads", "copy the text from this image",
            "copy the text from the screen",
        ]),
        RioHelpCategory(title: "Outside world", symbol: "cloud.sun", examples: [
            "what's the weather in Doha", "play my Discover Weekly", "what's due on Canvas", "what's the news",
            "will it rain tomorrow", "add call Ali to my roadmap in Notion",
        ]),
        RioHelpCategory(title: "Meetings", symbol: "person.2.wave.2", examples: [
            "start the meeting copilot", "what did they just say", "what are the action items", "recap the meeting",
            "stop the meeting copilot",
        ]),
        RioHelpCategory(title: "Claude Code", symbol: "terminal", examples: [
            "tell Claude to fix the failing test", "what's Claude doing", "approve that", "deny that",
        ]),
        RioHelpCategory(title: "Undo and help", symbol: "arrow.uturn.backward", examples: [
            "undo", "put it back", "what can you do", "stop",
        ]),
    ]

    /// The owner's keys, along the bottom of the sheet.
    static let keys: [RioHelpKey] = [
        RioHelpKey(keys: "Hold Fn", meaning: "dictate"),
        RioHelpKey(keys: "Double-tap Fn", meaning: "hands-free dictation"),
        RioHelpKey(keys: "Hold Fn + Control", meaning: "command Rio"),
        RioHelpKey(keys: "Fn + Control + Option", meaning: "conversation"),
        RioHelpKey(keys: "Right Command", meaning: "fix last dictation"),
    ]

    static let tips: [RioHelpTip] = [
        RioHelpTip(
            title: "Conversation mode", symbol: "ear",
            detail: "Press Fn + Control + Option, then start each command with \"Rio\". Ask him anything.",
            examples: ["Rio, how far is the moon", "Rio, open Chrome", "Rio, stop listening"]
        ),
        RioHelpTip(
            title: "From your iPhone", symbol: "iphone",
            detail: "Text yourself a message that starts with \"Rio\".",
            examples: ["Rio, what's the weather", "Rio, open Spotify"]
        ),
    ]

    /// The one line Rio says when the help sheet opens.
    static let spokenSummary = "I can open apps, set timers, read your screen, do maths, remember things, write emails, run routines and answer questions."

    /// How long the sheet stays up on its own (it holds more than it used to).
    static let autoCloseSeconds: TimeInterval = 30
}
