import Foundation

/// Email drafts and Apple Notes (builder L): URL and AppleScript parameter builders, routing, and
/// recipient resolution. Nothing here touches Mail, Notes or Contacts.
enum RioEmailNotesTests {
    static func run() {
        routing()
        gmailLinks()
        mailtoLinks()
        mailScript()
        recipients()
        notesScript()
        emailPhrases()
    }

    /// Recipient, subject and body come apart on common wordings; a purpose instead of words
    /// goes to the resolver, which writes the whole draft.
    private static func emailPhrases() {
        func parse(_ text: String) -> RioAction? { RioEmailPhrases.parse(text) }
        let drafts: [(String, RioAction)] = [
            ("email Naif and say thanks for the call, I'll send the deck tomorrow",
             .draftEmail(to: "Naif", subject: nil, body: "Thanks for the call, I'll send the deck tomorrow")),
            ("send an email to ali@haladiscover.com subject launch, body we're live",
             .draftEmail(to: "ali@haladiscover.com", subject: "Launch", body: "We're live")),
            ("email Sam subject lunch body see you at noon", .draftEmail(to: "Sam", subject: "Lunch", body: "See you at noon")),
            ("draft a follow up email to the Falak team", .draftEmail(to: "the Falak team", subject: "Follow up", body: "")),
            ("draft a quick email to professor Kim", .draftEmail(to: "professor Kim", subject: nil, body: "")),
            ("email Sam saying I'm running late", .draftEmail(to: "Sam", subject: nil, body: "I'm running late")),
            ("email Sam saying lunch and dinner are on", .draftEmail(to: "Sam", subject: nil, body: "Lunch and dinner are on")),
            ("write an email to john at example dot com subject hello saying see you soon",
             .draftEmail(to: "john@example.com", subject: "Hello", body: "See you soon")),
            ("email that I'm out today", .draftEmail(to: nil, subject: nil, body: "I'm out today")),
        ]
        for (input, expected) in drafts { ETest.eq(parse(input), expected, input) }
        for purpose in [
            "draft an email to my TA asking for an extension on homework 6", "email my TA asking for an extension",
            "draft an email to professor Kim requesting an extension",
            "draft an email to Naif thanking him for the call and saying I'll send the deck",
            "write an email to the investors with our monthly update", "email the team letting them know I'm out",
            // A topic with no words: the resolver writes the email (round 2, finding 24).
            "draft an email to Sam about lunch", "draft an email to investors about the november update",
        ] {
            ETest.eq(parse(purpose), nil, "a purpose is composed by the resolver: \(purpose)")
        }
        let parser = RioActionParser(installedApps: [])
        if case .actions(let list) = parser.parse("Rio, email my TA asking for an extension") {
            TestSupport.expect(false, "must not be a sure parse: \(list)")
        }
        // "... email to X" is a mail draft, not text typed into the focused field.
        ETest.eq(parser.parse("draft a follow up email to the Falak team"),
                 .actions([.draftEmail(to: "the Falak team", subject: "Follow up", body: "")]))
    }

    private static func routing() {
        ETest.eq(RioMailRouter.route(defaultHandlerBundleID: "com.apple.mail"), .appleMail)
        ETest.eq(RioMailRouter.route(defaultHandlerBundleID: nil), .appleMail)
        for browser in ["com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "com.brave.Browser",
                        "company.thebrowser.Browser", "com.microsoft.edgemac", "com.google.Chrome.beta"] {
            ETest.eq(RioMailRouter.route(defaultHandlerBundleID: browser), .gmailWeb, browser)
        }
        for other in ["com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.freron.MailMate"] {
            ETest.eq(RioMailRouter.route(defaultHandlerBundleID: other), .mailtoDefault, other)
        }
    }

    private static func gmailLinks() {
        let url = RioEmailLinks.gmailCompose(to: "kim@ucdavis.edu", subject: "Running late", body: "Hi Professor Kim,\nI'll be late & sorry.")
        ETest.eq(
            url?.absoluteString,
            "https://mail.google.com/mail/?view=cm&fs=1&to=kim%40ucdavis.edu&su=Running%20late&body=Hi%20Professor%20Kim%2C%0AI%27ll%20be%20late%20%26%20sorry."
        )
        ETest.eq(
            RioEmailLinks.gmailCompose(to: nil, subject: nil, body: "Hello")?.absoluteString,
            "https://mail.google.com/mail/?view=cm&fs=1&body=Hello"
        )
        // Hostile text can't add a recipient or change the host.
        let hostile = RioEmailLinks.gmailCompose(to: "a@b.com", subject: "x&to=evil@x.com", body: "#fragment?&cc=evil@x.com")
        let items = hostile.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
        ETest.eq(items.filter { $0.name == "to" }.count, 1)
        ETest.eq(items.filter { $0.name == "cc" }.count, 0)
        ETest.eq(hostile?.host, "mail.google.com")
        ETest.eq(RioEmailLinks.gmailCompose(to: nil, subject: nil, body: String(repeating: "word ", count: 3_000)), nil, "too long for a URL")
    }

    private static func mailtoLinks() {
        ETest.eq(
            RioEmailLinks.mailto(to: "kim@ucdavis.edu", subject: "Hi", body: "Late & sorry")?.absoluteString,
            "mailto:kim%40ucdavis.edu?subject=Hi&body=Late%20%26%20sorry"
        )
        ETest.eq(RioEmailLinks.mailto(to: nil, subject: nil, body: "Hello")?.absoluteString, "mailto:?body=Hello")
    }

    private static func mailScript() {
        let call = RioMailScripts.draft(to: "a@b.com", subject: "S", body: "B")
        ETest.eq(call.handler, "draftmail")
        ETest.eq(call.arguments, ["a@b.com", "S", "B"])
        ETest.eq(call.source, RioMailScripts.source)
        // User text only ever travels as an argument; the source is constant and can't send.
        let nasty = "\"; do shell script \"rm -rf /\" -- send"
        let hostile = RioMailScripts.draft(to: nil, subject: nasty, body: nasty)
        ETest.eq(hostile.source, RioMailScripts.source)
        ETest.eq(hostile.arguments, ["", nasty, nasty])
        TestSupport.expect(!RioText.matches(#"\bsend\b"#, RioMailScripts.source), "the mail script must never send")
        TestSupport.expect(!RioMailScripts.source.contains("shell"), "no shell in the mail script")
        TestSupport.expect(RioMailScripts.source.contains("make new outgoing message"), "creates a draft window")
    }

    private static func candidate(_ given: String, _ family: String, phones: [String] = [], emails: [String] = []) -> RioContactCandidate {
        RioContactCandidate(
            fullName: "\(given) \(family)", givenName: given, familyName: family, nickname: "",
            phones: phones.map { RioContactPhone(label: "mobile", number: $0) }, emails: emails
        )
    }

    private static func recipients() {
        let sam = candidate("Sam", "Kim", phones: ["+1 530 555 0100"], emails: ["sam.kim@ucdavis.edu"])
        ETest.eq(RioMailRecipient.resolve(spoken: "Professor Kim", candidates: [sam]), .match(name: "Sam Kim", handle: "sam.kim@ucdavis.edu"))
        ETest.eq(RioMailRecipient.resolve(spoken: "Dr. Sam Kim", candidates: [sam]), .match(name: "Sam Kim", handle: "sam.kim@ucdavis.edu"))
        ETest.eq(RioMailRecipient.resolve(spoken: "sam", candidates: [sam]), .match(name: "Sam Kim", handle: "sam.kim@ucdavis.edu"))
        let phoneOnly = candidate("Ali", "Rahman", phones: ["+97455500000"])
        ETest.eq(RioMailRecipient.resolve(spoken: "Ali", candidates: [phoneOnly]), .noHandle(name: "Ali Rahman"))
        let two = [sam, candidate("Lee", "Kim", emails: ["lee@x.com"])]
        ETest.eq(RioMailRecipient.resolve(spoken: "Kim", candidates: two), .ambiguous(["Lee Kim", "Sam Kim"]))
        ETest.eq(RioMailRecipient.resolve(spoken: "Nobody", candidates: [sam]), .notFound)
        ETest.eq(RioMailRecipient.resolve(spoken: "kim@ucdavis.edu", candidates: []), .match(name: "kim@ucdavis.edu", handle: "kim@ucdavis.edu"))
        ETest.eq(RioMailRecipient.resolve(spoken: "+1 530 555 0100", candidates: [sam]), .notFound, "a phone number is not an email")
    }

    private static func notesScript() {
        let call = RioNotesScripts.append(text: "Ask Ali about the deck", noteID: nil)
        ETest.eq(call.handler, "appendnote")
        ETest.eq(call.arguments, ["", "Rio Notes", "<div>Ask Ali about the deck</div>"])
        ETest.eq(call.source, RioNotesScripts.source)
        // Security fix (lead): Rio appends only to the note it created, by its saved id, and never
        // searches notes by name (a shared note called "Rio Notes" must never receive the text).
        ETest.eq(RioNotesScripts.append(text: "x", noteID: "x-coredata://ABC/ICNote/p9").arguments[0], "x-coredata://ABC/ICNote/p9")
        TestSupport.expect(!RioNotesScripts.source.contains("whose name"), "never looks notes up by name")
        TestSupport.expect(RioNotesScripts.source.contains("note id theID"), "appends by id")
        TestSupport.expect(RioNotesScripts.source.contains("default account"), "creates in the default account")
        ETest.eq(RioNotesScripts.append(text: "Ask <b>Ali</b> & co", noteID: nil).arguments[2], "<div>Ask &lt;b&gt;Ali&lt;/b&gt; &amp; co</div>")
        ETest.eq(RioNotesScripts.append(text: "a\nb", noteID: nil).arguments[2], "<div>a</div><div>b</div>")
        ETest.eq(RioNotesScripts.append(text: "a\n\nb", noteID: nil).arguments[2], "<div>a</div><div><br></div><div>b</div>")
        let nasty = "\" & (do shell script \"x\") & \""
        ETest.eq(RioNotesScripts.append(text: nasty, noteID: nil).source, RioNotesScripts.source)
        TestSupport.expect(!RioNotesScripts.source.contains("shell"), "no shell in the notes script")
        TestSupport.expect(!RioNotesScripts.source.contains("delete"), "the notes script never deletes")
        ETest.eq(RioNotesScripts.noteTitle, "Rio Notes")
    }
}
