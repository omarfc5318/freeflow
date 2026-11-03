import Foundation

/// The kind of app a dictation is going into, so each can get its own tone.
enum DictationStyleCategory: String, CaseIterable, Codable, Identifiable {
    case personal
    case work
    case email
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .personal: return "Personal messages"
        case .work: return "Work messages"
        case .email: return "Email"
        case .other: return "Everything else"
        }
    }

    var examples: String {
        switch self {
        case .personal: return "Messages, WhatsApp, Telegram, Signal, Messenger"
        case .work: return "Slack, Microsoft Teams, Discord, Google Chat"
        case .email: return "Mail, Outlook, Gmail, Superhuman, Spark"
        case .other: return "Notes, documents, code editors, any other app"
        }
    }

    var icon: String {
        switch self {
        case .personal: return "message.fill"
        case .work: return "bubble.left.and.bubble.right.fill"
        case .email: return "envelope.fill"
        case .other: return "doc.text.fill"
        }
    }
}

/// How cleanup should sound for a category. `standard` changes nothing.
enum DictationStyle: String, CaseIterable, Codable, Identifiable {
    case standard
    case formal
    case casual
    case veryCasual
    case excited

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .veryCasual: return "Very casual"
        case .excited: return "Excited"
        }
    }

    /// What the style produces from "hey are you free for lunch tomorrow i want to talk about the launch".
    var sample: String {
        switch self {
        case .standard: return "Hey, are you free for lunch tomorrow? I want to talk about the launch."
        case .formal: return "Hello, are you available for lunch tomorrow? I would like to discuss the launch."
        case .casual: return "Hey, are you free for lunch tomorrow? Want to talk about the launch."
        case .veryCasual: return "hey are you free for lunch tomorrow? want to talk about the launch"
        case .excited: return "Hey, are you free for lunch tomorrow? I want to talk about the launch!"
        }
    }
}

enum DictationStyleCore {
    static let personalApps: Set<String> = [
        "com.apple.MobileSMS", "com.apple.iChat", "net.whatsapp.WhatsApp", "desktop.WhatsApp",
        "ru.keepcoder.Telegram", "org.telegram.desktop", "org.whispersystems.signal-desktop",
        "com.facebook.archon", "com.facebook.archon.developerID"
    ]
    static let workApps: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.microsoft.teams", "com.microsoft.teams2",
        "com.hnc.Discord", "com.google.Chat"
    ]
    static let emailApps: Set<String> = [
        "com.apple.mail", "com.microsoft.Outlook", "com.superhuman.electron",
        "com.readdle.smartemail-Mac", "com.readdle.SparkDesktop", "com.mimestream.Mimestream",
        "it.bloop.airmail2"
    ]
    static let browsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
        "app.zen-browser.zen", "com.kagi.kagimacOS"
    ]

    /// Web apps recognized by the browser tab title, checked in order.
    static let webAppTitles: [(keyword: String, category: DictationStyleCategory)] = [
        ("gmail", .email), ("outlook", .email), ("proton mail", .email), ("yahoo mail", .email),
        ("superhuman", .email), ("fastmail", .email),
        ("slack", .work), ("microsoft teams", .work), ("discord", .work), ("google chat", .work),
        ("whatsapp", .personal), ("messenger", .personal), ("telegram", .personal), ("instagram", .personal)
    ]

    static func category(bundleIdentifier: String?, windowTitle: String?) -> DictationStyleCategory {
        guard let bundleIdentifier else { return .other }
        if personalApps.contains(bundleIdentifier) { return .personal }
        if workApps.contains(bundleIdentifier) { return .work }
        if emailApps.contains(bundleIdentifier) { return .email }
        guard browsers.contains(bundleIdentifier), let title = windowTitle?.lowercased() else { return .other }
        return webAppTitles.first { titleContainsWord(title, $0.keyword) }?.category ?? .other
    }

    private static func titleContainsWord(_ title: String, _ keyword: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: keyword)
        return title.range(of: #"(?<![\p{L}\p{N}])"# + escaped + #"(?![\p{L}\p{N}])"#, options: .regularExpression) != nil
    }

    /// Text appended to the cleanup system prompt, or nil when the style changes nothing.
    static func instruction(for style: DictationStyle) -> String? {
        let tone: String
        switch style {
        case .standard:
            return nil
        case .formal:
            tone = "Use a formal, professional tone: complete sentences, full capitalization and punctuation, and no slang or contractions."
        case .casual:
            tone = "Use a casual, conversational tone: normal capitalization, light punctuation, and contractions where they sound natural."
        case .veryCasual:
            tone = "Write like a quick text message: all lowercase (proper nouns and vocabulary terms included), minimal punctuation, and no period at the end."
        case .excited:
            tone = "Use an upbeat, enthusiastic tone. Use exclamation points where the speaker sounds excited, but do not add emoji."
        }
        return """
WRITING STYLE for this app: \(tone)
The style changes only tone, capitalization and punctuation. Never add greetings, sign-offs, or content that was not dictated, and never change the meaning.
"""
    }

    /// The cleanup system prompt with the style appended. The base is resolved first, so a
    /// style never replaces the default prompt.
    static func systemPrompt(base resolvedPrompt: String, style: DictationStyle) -> String {
        guard let instruction = instruction(for: style) else { return resolvedPrompt }
        return resolvedPrompt + "\n\n" + instruction
    }
}
