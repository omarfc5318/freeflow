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

/// "email Sam saying I'm running late", "draft an email to Sam about lunch", "compose an email".
/// Local and offline: it only ever opens a compose window (never sends). Pure.
///
/// Only wordings that give the email's words are claimed. A purpose ("asking for an extension",
/// "thanking him for the call", "with our monthly update") means the email still has to be
/// written, so it is left to the resolver, which composes the whole draft.
enum RioEmailPhrases {
    private static let maxBody = 1_500
    private static let maxRecipientWords = 4

    /// Words that start the email's text ("saying ...", "and say ...", "body ...").
    private static let bodyMarker = #"(?:saying|that\s+says|says|telling\s+(?:him|her|them)(?:\s+that)?|and\s+(?:tell|say)(?:\s+(?:him|her|them))?(?:\s+that)?|that|(?:and\s+)?(?:the\s+)?body(?:\s+is)?\s*:?)"#
    /// Words that give a purpose instead of the text: the email still has to be composed.
    private static let purposeMarker = #"(?:asking|requesting|to\s+(?:ask|request|thank|tell|invite|remind|let)|thanking|inviting|reminding|letting\s+\S+\s+know|apologi[sz]ing|following\s+up|checking\s+in|with)"#
    /// "and ask if ...", "and tell him to ...", "and let her know ...", "and say that ...".
    private static let instructionInBody = #"\b(?:and|then|also)\s+(?:also\s+)?(?:ask(?:\s+(?:him|her|them|if|whether|for|when|about|to))|tell\s+(?:him|her|them)|let\s+(?:him|her|them)\s+know|say\s+that|request|thank\s+(?:him|her|them)|apologi[sz]e|invite\s+(?:him|her|them))\b"#
    private static let subjectMarker = #"(?:subject(?:\s+line)?(?:\s+is)?\s*:?|titled|about|regarding)"#
    /// A spoken recipient that still carries a verb is a misparse ("my TA asking for ...").
    private static let verbInRecipient = #"\b(?:asking|telling|saying|thanking|requesting|letting|inviting|reminding|checking|following|sending|wondering|explaining|confirming|apologi[sz]ing|ask|tell|say|thank|request|let|send|invite|remind)\b"#
    /// "draft a follow up email": kinds that make a good subject line.
    private static let kinds: [(pattern: String, subject: String?)] = [
        (#"^follow\s?-?\s?up$"#, "Follow up"), (#"^thank\s?-?\s?you$"#, "Thank you"), (#"^reminder$"#, "Reminder"),
        (#"^(?:quick|short|brief|formal|polite|nice|friendly)$"#, nil),
    ]

    static func parse(_ text: String) -> RioAction? {
        let kindWords = #"(?:(follow\s?-?\s?up|thank\s?-?\s?you|reminder|quick|short|brief|formal|polite|nice|friendly)\s+)?"#
        let pattern = #"^(?:(?:please\s+)?(?:draft|write|compose|create|start|send)\s+(?:an?\s+|the\s+)?(?:new\s+)?"# + kindWords
            + #"(?:e\s?-?\s?mail)|new\s+e\s?-?\s?mail|e\s?-?\s?mail)(?:\s+(.*))?$"#
        guard let groups = RioText.firstMatch(pattern, in: text) else { return nil }
        let isVerbForm = RioText.matches(#"^e\s?-?\s?mail\b"#, text)
        let kindSubject = groups[1].flatMap { kind in kinds.first { RioText.matches($0.pattern, kind) }?.subject }
        let rest = RioText.collapseWhitespace(groups[2] ?? "")
        if rest.isEmpty { return isVerbForm ? nil : .draftEmail(to: nil, subject: kindSubject, body: "") }

        guard let parts = split(rest) else { return nil }
        guard parts.body.count <= maxBody else { return nil }
        // "saying I'll miss class ... and ask if I can get the slides": the end is an instruction
        // to the writer, not the email's words. The resolver composes a proper draft.
        guard !RioText.matches(instructionInBody, parts.body) else { return nil }
        // "draft an email to the investors about the November update": a topic, not the words.
        // The resolver writes the email; a blank draft with only a subject is not what was asked.
        if parts.body.isEmpty, parts.subject != nil, parts.subjectIsTopic { return nil }
        let recipient = RioText.replacing(#"^(?:to|for)\s+"#, with: "", in: parts.head)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        let to: String?
        if recipient.isEmpty || RioText.matches(#"^(?:me|myself)$"#, recipient) {
            to = nil
        } else {
            let address = spokenAddress(recipient)
            if !address.contains("@") {
                // "my TA asking for an extension": the purpose is still in the name. Let the resolver compose it.
                guard address.split(separator: " ").count <= maxRecipientWords, !RioText.matches(verbInRecipient, address) else { return nil }
            }
            to = address
        }
        let subject = parts.subject
            .map { RioText.collapseWhitespace($0).trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:")) }
            .flatMap { $0.isEmpty ? nil : capitalised($0) } ?? kindSubject
        return .draftEmail(to: to, subject: subject, body: capitalised(parts.body))
    }

    /// Recipient words, subject and body. Nil when the words give a purpose, not the text.
    private static func split(_ rest: String) -> (head: String, subject: String?, body: String, subjectIsTopic: Bool)? {
        let padded = " " + rest
        let any = #"[\s,]+(?:("# + bodyMarker + #")|("# + purposeMarker + #")|("# + subjectMarker + #"))(?=[\s,:]|$)"#
        guard let regex = try? NSRegularExpression(pattern: any, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: padded, range: NSRange(location: 0, length: padded.utf16.count)),
              let whole = Range(match.range, in: padded) else {
            return (rest, nil, "", false)
        }
        let head = String(padded[..<whole.lowerBound]).trimmingCharacters(in: .whitespaces)
        let after = String(padded[whole.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " ,:"))
        if match.range(at: 2).location != NSNotFound { return nil }
        if match.range(at: 1).location != NSNotFound { return (head, nil, after, false) }
        let marker = Range(match.range(at: 3), in: padded).map { padded[$0].lowercased() } ?? ""
        let isTopic = marker.hasPrefix("about") || marker.hasPrefix("regarding")
        // A subject first: its text runs up to a body marker, if there is one.
        let bodyAfterSubject = #"[\s,]+"# + bodyMarker + #"(?=[\s,:]|$)"#
        guard let bodyRegex = try? NSRegularExpression(pattern: bodyAfterSubject, options: [.caseInsensitive]) else { return nil }
        let subjectPadded = " " + after
        guard let bodyMatch = bodyRegex.firstMatch(in: subjectPadded, range: NSRange(location: 0, length: subjectPadded.utf16.count)),
              let bodyRange = Range(bodyMatch.range, in: subjectPadded) else {
            return (head, after, "", isTopic)
        }
        let subject = String(subjectPadded[..<bodyRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let body = String(subjectPadded[bodyRange.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " ,:"))
        return (head, subject, body, isTopic)
    }

    /// "john at example dot com" -> "john@example.com"; a name stays a name.
    static func spokenAddress(_ spoken: String) -> String {
        guard let groups = RioText.firstMatch(#"^([a-z0-9._-]+)\s+at\s+([a-z0-9 -]+?)\s+dot\s+([a-z]{2,24}(?:\s+dot\s+[a-z]{2,24})*)$"#, in: spoken),
              let user = groups[1], let domain = groups[2], let tld = groups[3] else { return spoken }
        let host = (domain + " dot " + tld).replacingOccurrences(of: " dot ", with: ".").replacingOccurrences(of: " ", with: "")
        return "\(user)@\(host)".lowercased()
    }

    private static func capitalised(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}
