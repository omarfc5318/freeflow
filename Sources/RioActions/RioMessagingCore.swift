import Foundation

// Pure building blocks for messaging, reading and confirmation text (builder E). Foundation
// only: nothing here touches Contacts, Messages, Accessibility or the screen.

// MARK: AppleScript parameters

/// A call into the fixed Messages script: the source is a constant, the user's recipient and
/// text only ever travel as arguments.
struct RioScriptCall: Equatable {
    let source: String
    let handler: String
    let arguments: [String]
}

enum RioMessagingScripts {
    /// Fixed source. It never contains, and is never built from, user text.
    static let source = """
    on sendimessage(theHandle, theBody)
        tell application "Messages"
            set theService to 1st service whose service type = iMessage
            set theBuddy to buddy theHandle of theService
            send theBody to theBuddy
        end tell
    end sendimessage

    on sendsms(theHandle, theBody)
        tell application "Messages"
            set theService to 1st service whose service type = SMS
            set theBuddy to buddy theHandle of theService
            send theBody to theBuddy
        end tell
    end sendsms
    """

    static func sendIMessage(handle: String, body: String) -> RioScriptCall {
        RioScriptCall(source: source, handler: "sendimessage", arguments: [handle, body])
    }

    static func sendSMS(handle: String, body: String) -> RioScriptCall {
        RioScriptCall(source: source, handler: "sendsms", arguments: [handle, body])
    }

    private static let scriptSuite: AEEventClass = 0x6173_6372      // 'ascr'
    private static let subroutineEvent: AEEventID = 0x7073_6272     // 'psbr'
    private static let subroutineName: AEKeyword = 0x736E_616D      // 'snam'
    private static let directObject: AEKeyword = 0x2D2D_2D2D        // '----'

    /// The AppleScript "call a handler with arguments" event. Arguments are string descriptors.
    static func appleEvent(for call: RioScriptCall, target: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: scriptSuite, eventID: subroutineEvent, targetDescriptor: target,
            returnID: -1, transactionID: 0
        )
        event.setParam(NSAppleEventDescriptor(string: call.handler), forKeyword: subroutineName)
        let list = NSAppleEventDescriptor.list()
        for (index, argument) in call.arguments.enumerated() {
            list.insert(NSAppleEventDescriptor(string: argument), at: index + 1)
        }
        event.setParam(list, forKeyword: directObject)
        return event
    }
}

// MARK: Recipients and contacts

enum RioRecipient {
    /// A phone number or email spoken instead of a name; nil for names and anything odd.
    static func directHandle(from spoken: String) -> String? {
        let text = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        if RioText.matches(#"^[^\s@;|&$`<>"']+@[^\s@;|&$`<>"']+\.[A-Za-z]{2,}$"#, text) { return text }
        guard RioText.matches(#"^[+\d][\d\s\-\(\)\.]*$"#, text) else { return nil }
        return normalizedPhone(text)
    }

    /// Digits with an optional leading "+", at least 7 and at most 15 digits.
    static func normalizedPhone(_ number: String) -> String? {
        let digits = number.filter(\.isNumber)
        guard (7...15).contains(digits.count) else { return nil }
        return (number.trimmingCharacters(in: .whitespaces).hasPrefix("+") ? "+" : "") + digits
    }
}

struct RioContactPhone: Equatable {
    let label: String?
    let number: String
}

struct RioContactCandidate: Equatable {
    let fullName: String
    let givenName: String
    let familyName: String
    let nickname: String
    let phones: [RioContactPhone]
    let emails: [String]
}

enum RioContactChoice: Equatable {
    case match(name: String, handle: String)
    case ambiguous([String])
    case noHandle(name: String)
    case notFound
}

enum RioContactChooser {
    /// Case, accents and the Arabic spellings speech-to-text varies on (أ/ا, ة/ه, ى/ي) folded.
    private static func fold(_ text: String) -> String {
        RioArabicText.normalize(text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil))
    }

    /// Family words a contact is commonly saved under, in both scripts: a Gulf speaker says
    /// "أمي" for a card saved as "Mom", or "Mom" for one saved as "الوالدة".
    private static let familyWords: [Set<String>] = [
        ["mom", "mum", "mother", "mama", "mommy", "mummy", "ma", "امي", "ماما", "الوالده", "والدتي", "يما", "يمه", "امي الحبيبه", "ام"],
        ["dad", "father", "baba", "papa", "daddy", "abba", "ابوي", "ابي", "بابا", "الوالد", "والدي", "يبه", "يبا", "ابويه"],
    ].map { Set($0.map { fold($0) }) }

    /// The contact for a spoken name. When nobody matches a family word ("أمي"), its other
    /// spellings are tried ("Mom", "الوالدة"); if they find more than one person, the user picks.
    static func choose(spoken: String, from candidates: [RioContactCandidate]) -> RioContactChoice {
        let direct = chooseExactly(spoken: spoken, from: candidates)
        guard direct == .notFound else { return direct }
        let wanted = fold(spoken)
        guard let family = familyWords.first(where: { $0.contains(wanted) }) else { return .notFound }
        let exactTiers: [(RioContactCandidate, String) -> Bool] = [
            { fold($0.fullName) == $1 || fold("\($0.givenName) \($0.familyName)") == $1 },
            { fold($0.givenName) == $1 || fold($0.nickname) == $1 },
        ]
        let matches = candidates.filter { candidate in
            family.contains { word in word != wanted && exactTiers.contains { $0(candidate, word) } }
        }
        return matches.isEmpty ? .notFound : decide(matches)
    }

    private static func chooseExactly(spoken: String, from candidates: [RioContactCandidate]) -> RioContactChoice {
        let wanted = fold(spoken)
        guard !wanted.isEmpty else { return .notFound }
        let tokens = wanted.split(separator: " ").map(String.init)

        let tiers: [(RioContactCandidate) -> Bool] = [
            { fold($0.fullName) == wanted || fold("\($0.givenName) \($0.familyName)") == wanted },
            { fold($0.givenName) == wanted || fold($0.nickname) == wanted },
            { fold($0.familyName) == wanted },
            { candidate in
                let names = [candidate.givenName, candidate.familyName, candidate.nickname].map(fold).filter { !$0.isEmpty }
                return tokens.allSatisfy { token in names.contains { $0.hasPrefix(token) } }
            },
        ]
        for tier in tiers {
            let matches = candidates.filter(tier)
            if matches.isEmpty { continue }
            return decide(matches)
        }
        return .notFound
    }

    private static func decide(_ matches: [RioContactCandidate]) -> RioContactChoice {
        var seen = Set<String>()
        var unique: [RioContactCandidate] = []
        for match in matches where seen.insert(fold(match.fullName)).inserted { unique.append(match) }
        if unique.count > 1 { return .ambiguous(unique.map(\.fullName).sorted()) }
        // Same person listed more than once: take the first card that has a handle.
        for card in matches {
            if let handle = handle(for: card) { return .match(name: card.fullName, handle: handle) }
        }
        return .noHandle(name: unique[0].fullName)
    }

    /// Mobile or iPhone number first, any other number next, then an email.
    private static func handle(for card: RioContactCandidate) -> String? {
        let phones = card.phones.compactMap { phone -> (isMobile: Bool, number: String)? in
            guard let number = RioRecipient.normalizedPhone(phone.number) else { return nil }
            let label = phone.label?.lowercased() ?? ""
            return (label.contains("mobile") || label.contains("iphone"), number)
        }
        if let mobile = phones.first(where: \.isMobile) { return mobile.number }
        if let any = phones.first { return any.number }
        return card.emails.first { RioRecipient.directHandle(from: $0) != nil }
    }
}

// MARK: Messaging apps and reading

enum RioSendKey: Equatable {
    case returnKey
    /// Mail: Return adds a new line, so send is Command-Shift-D.
    case commandShiftD
}

struct RioMessagingApp: Equatable {
    let name: String
    let bundleIdentifier: String
    let sendKey: RioSendKey
    /// Whether "read my last message" is attempted in this app (best effort).
    let canReadMessages: Bool
}

enum RioMessagingApps {
    static let all: [RioMessagingApp] = [
        RioMessagingApp(name: "Messages", bundleIdentifier: "com.apple.MobileSMS", sendKey: .returnKey, canReadMessages: true),
        RioMessagingApp(name: "WhatsApp", bundleIdentifier: "net.whatsapp.WhatsApp", sendKey: .returnKey, canReadMessages: true),
        RioMessagingApp(name: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap", sendKey: .returnKey, canReadMessages: true),
        RioMessagingApp(name: "Discord", bundleIdentifier: "com.hnc.Discord", sendKey: .returnKey, canReadMessages: true),
        RioMessagingApp(name: "Telegram", bundleIdentifier: "ru.keepcoder.Telegram", sendKey: .returnKey, canReadMessages: true),
        RioMessagingApp(name: "Telegram", bundleIdentifier: "org.telegram.desktop", sendKey: .returnKey, canReadMessages: true),
        RioMessagingApp(name: "Signal", bundleIdentifier: "org.whispersystems.signal-desktop", sendKey: .returnKey, canReadMessages: true),
        RioMessagingApp(name: "Microsoft Teams", bundleIdentifier: "com.microsoft.teams2", sendKey: .returnKey, canReadMessages: true),
        RioMessagingApp(name: "Mail", bundleIdentifier: "com.apple.mail", sendKey: .commandShiftD, canReadMessages: false),
    ]

    static func info(for bundleIdentifier: String?) -> RioMessagingApp? {
        guard let id = bundleIdentifier?.lowercased() else { return nil }
        return all.first { $0.bundleIdentifier.lowercased() == id }
    }
}

struct RioMessageCandidate: Equatable {
    let text: String
    /// The element's accessibility description, which Messages uses to say who sent a bubble.
    let description: String?
}

enum RioMessagePicker {
    private static let chromeWords: Set<String> = [
        "delivered", "read", "sent", "today", "yesterday", "imessage", "text message", "edited", "not delivered",
    ]

    /// The newest incoming message among text elements in document order: skips timestamps and
    /// delivery receipts and the user's own bubbles.
    static func lastIncoming(from candidates: [RioMessageCandidate]) -> String? {
        for candidate in candidates.reversed() {
            let text = RioText.collapseWhitespace(candidate.text)
            guard !text.isEmpty, !isChrome(text), !isOutgoing(text: text, description: candidate.description) else { continue }
            return text
        }
        return nil
    }

    private static func isChrome(_ text: String) -> Bool {
        chromeWords.contains(text.lowercased())
            || RioText.matches(#"^(?:[A-Za-z]{3,9}\s+)?\d{1,2}:\d{2}\s?(?:am|pm)?$"#, text)
    }

    private static func isOutgoing(text: String, description: String?) -> Bool {
        let described = description?.lowercased() ?? ""
        return described.hasPrefix("your ") || described.hasPrefix("you ")
            || RioText.matches(#"^(?:you|me)\s*:"#, text)
    }
}

enum RioReadingText {
    /// Joins text fragments into one readable string of at most `limit` characters, cut at a
    /// word boundary.
    static func condense(_ fragments: [String], limit: Int) -> String {
        guard limit > 0 else { return "" }
        let joined = RioText.collapseWhitespace(fragments.joined(separator: " "))
        guard joined.count > limit else { return joined }
        var cut = String(joined.prefix(limit))
        let next = joined[joined.index(joined.startIndex, offsetBy: limit)]
        if next != " ", let space = cut.lastIndex(of: " ") { cut = String(cut[..<space]) }
        return cut.trimmingCharacters(in: .whitespaces)
    }
}
