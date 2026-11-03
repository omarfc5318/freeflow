import Foundation

// Pure building blocks for email drafts (builder L). Foundation only. Rio only ever opens a
// compose window: nothing in here can send.

enum RioMailRoute: Equatable {
    /// Apple Mail, through a fixed AppleScript that takes the text as parameters.
    case appleMail
    /// The default mail handler is a web browser: Gmail's compose page.
    case gmailWeb
    /// Another mail app (Outlook, Spark...): a `mailto:` link opens its compose window.
    case mailtoDefault
}

enum RioMailRouter {
    private static let browserPrefixes = [
        "com.google.chrome", "com.apple.safari", "org.mozilla.firefox", "com.brave.browser", "company.thebrowser.browser",
        "com.microsoft.edgemac", "com.operasoftware.opera", "com.vivaldi.vivaldi", "org.chromium.chromium",
    ]

    static func route(defaultHandlerBundleID: String?) -> RioMailRoute {
        guard let id = defaultHandlerBundleID?.lowercased(), !id.isEmpty, id != "com.apple.mail" else { return .appleMail }
        return browserPrefixes.contains { id.hasPrefix($0) } ? .gmailWeb : .mailtoDefault
    }
}

enum RioEmailLinks {
    /// Longest URL we hand to a browser or mail app.
    static let maxURLLength = 7_500

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Everything but unreserved characters is percent-encoded, so user text can never add a
    /// parameter, end the query or change the host.
    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    static func gmailCompose(to: String?, subject: String?, body: String) -> URL? {
        var parts = ["view=cm", "fs=1"]
        if let to, !to.isEmpty { parts.append("to=" + encode(to)) }
        if let subject, !subject.isEmpty { parts.append("su=" + encode(subject)) }
        if !body.isEmpty { parts.append("body=" + encode(body)) }
        return limited("https://mail.google.com/mail/?" + parts.joined(separator: "&"))
    }

    static func mailto(to: String?, subject: String?, body: String) -> URL? {
        var parts: [String] = []
        if let subject, !subject.isEmpty { parts.append("subject=" + encode(subject)) }
        if !body.isEmpty { parts.append("body=" + encode(body)) }
        let address = to.map(encode) ?? ""
        return limited("mailto:" + address + "?" + parts.joined(separator: "&"))
    }

    private static func limited(_ string: String) -> URL? {
        guard string.count <= maxURLLength else { return nil }
        return URL(string: string)
    }
}

enum RioMailScripts {
    /// Fixed source. It never contains, and is never built from, user text, and it has no way to
    /// send: it makes an outgoing message, fills it in and shows the window.
    static let source = """
    on draftmail(theTo, theSubject, theBody)
        tell application "Mail"
            set theMessage to make new outgoing message with properties {subject:theSubject, content:theBody, visible:true}
            if theTo is not "" then
                tell theMessage to make new to recipient at end of to recipients with properties {address:theTo}
            end if
            activate
        end tell
    end draftmail
    """

    static func draft(to: String?, subject: String?, body: String) -> RioScriptCall {
        RioScriptCall(source: source, handler: "draftmail", arguments: [to ?? "", subject ?? "", body])
    }
}

/// Picks an email address for a spoken name from Contacts candidates (no phone numbers).
enum RioMailRecipient {
    static func withoutTitle(_ spoken: String) -> String {
        let text = RioText.replacing(
            #"^(?:professor|prof|doctor|dr|mister|mr|mrs|miss|ms|coach|sir|madam)\.?\s+"#, with: "",
            in: spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }

    static func resolve(spoken: String, candidates: [RioContactCandidate]) -> RioContactChoice {
        let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@") {
            if let direct = RioRecipient.directHandle(from: trimmed) { return .match(name: trimmed, handle: direct) }
            return .notFound
        }
        let emailOnly = candidates.map { card in
            RioContactCandidate(
                fullName: card.fullName, givenName: card.givenName, familyName: card.familyName,
                nickname: card.nickname, phones: [], emails: card.emails
            )
        }
        return RioContactChooser.choose(spoken: withoutTitle(trimmed), from: emailOnly)
    }
}
