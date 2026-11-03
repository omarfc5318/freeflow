import Foundation

/// Messaging, contacts, reading and confirmation text: all pure, no Contacts, Messages or AX.
enum RioMessagingTests {
    static func run() {
        testScriptSourceNeverContainsUserText()
        testAppleEventParameters()
        testDirectHandles()
        testContactChooser()
        testMessagingApps()
        testLastMessagePicker()
        testReadingText()
        testConfirmationContent()
    }

    // MARK: AppleScript

    private static let hostileBody = "\" & (do shell script \"rm -rf ~\") & \""
    private static let hostileHandle = "+15551234567\" & quit & \""

    private static func testScriptSourceNeverContainsUserText() {
        let a = RioMessagingScripts.sendIMessage(handle: "+15551234567", body: "hello there")
        let b = RioMessagingScripts.sendIMessage(handle: hostileHandle, body: hostileBody)
        ETest.eq(a.source, b.source, "the source must not depend on user text")
        TestSupport.expect(!b.source.contains("rm -rf"), "hostile body must not reach the source")
        TestSupport.expect(!b.source.contains("quit &"), "hostile handle must not reach the source")
        TestSupport.expect(!a.source.contains("hello there"), "body must not reach the source")
        TestSupport.expect(!a.source.contains("5551234567"), "handle must not reach the source")
        TestSupport.expect(!a.source.contains("do shell script"), "the fixed source never shells out")
        ETest.eq(a.handler, "sendimessage")
        ETest.eq(a.arguments, ["+15551234567", "hello there"])
        ETest.eq(b.arguments, [hostileHandle, hostileBody])
        let sms = RioMessagingScripts.sendSMS(handle: "+15551234567", body: "x")
        ETest.eq(sms.handler, "sendsms")
        ETest.eq(sms.source, a.source)
        TestSupport.expect(a.source.contains("on sendimessage(") && a.source.contains("on sendsms("), "both handlers are declared")
    }

    private static func testAppleEventParameters() {
        let call = RioMessagingScripts.sendIMessage(handle: hostileHandle, body: hostileBody)
        let event = RioMessagingScripts.appleEvent(for: call, target: NSAppleEventDescriptor(processIdentifier: getpid()))
        ETest.eq(event.eventClass, 0x6173_6372, "ascr")
        ETest.eq(event.eventID, 0x7073_6272, "psbr")
        ETest.eq(event.paramDescriptor(forKeyword: 0x736E_616D)?.stringValue, "sendimessage")
        let list = event.paramDescriptor(forKeyword: 0x2D2D_2D2D)
        ETest.eq(list?.numberOfItems, 2)
        ETest.eq(list?.atIndex(1)?.stringValue, hostileHandle)
        ETest.eq(list?.atIndex(2)?.stringValue, hostileBody)
    }

    // MARK: Recipients and contacts

    private static func testDirectHandles() {
        ETest.eq(RioRecipient.directHandle(from: "555 123 4567"), "5551234567")
        ETest.eq(RioRecipient.directHandle(from: "+1 (555) 123-4567"), "+15551234567")
        ETest.eq(RioRecipient.directHandle(from: "ali@example.com"), "ali@example.com")
        ETest.eq(RioRecipient.directHandle(from: "Ali"), nil)
        ETest.eq(RioRecipient.directHandle(from: "123"), nil)
        ETest.eq(RioRecipient.directHandle(from: "Ali 555 123 4567"), nil)
        ETest.eq(RioRecipient.directHandle(from: "a@b"), nil)
        ETest.eq(RioRecipient.directHandle(from: "x@y.com; rm"), nil)
    }

    private static func candidate(
        _ full: String, given: String = "", family: String = "", nickname: String = "",
        phones: [(String?, String)] = [], emails: [String] = []
    ) -> RioContactCandidate {
        RioContactCandidate(
            fullName: full, givenName: given, familyName: family, nickname: nickname,
            phones: phones.map { RioContactPhone(label: $0.0, number: $0.1) }, emails: emails
        )
    }

    private static func testContactChooser() {
        let ali = candidate("Ali Khan", given: "Ali", family: "Khan",
                            phones: [("home", "(555) 000-1111"), ("_$!<Mobile>!$_", "+1 555-222-3333")])
        let alina = candidate("Alina Park", given: "Alina", family: "Park", phones: [("mobile", "555 444 5555")])
        let sarah = candidate("Sarah Lee", given: "Sarah", family: "Lee", emails: ["sarah@example.com"])
        let sarah2 = candidate("Sarah Cohen", given: "Sarah", family: "Cohen", phones: [("mobile", "555 777 8888")])
        let mom = candidate("Jane Doe", given: "Jane", family: "Doe", nickname: "Mom", phones: [("iPhone", "555 999 0000")])
        let nobody = candidate("Pat Quiet", given: "Pat", family: "Quiet")
        let all = [ali, alina, sarah, sarah2, mom, nobody]

        ETest.eq(RioContactChooser.choose(spoken: "Ali", from: all), .match(name: "Ali Khan", handle: "+15552223333"))
        ETest.eq(RioContactChooser.choose(spoken: "ali khan", from: all), .match(name: "Ali Khan", handle: "+15552223333"))
        ETest.eq(RioContactChooser.choose(spoken: "Alina", from: all), .match(name: "Alina Park", handle: "5554445555"))
        ETest.eq(RioContactChooser.choose(spoken: "Mom", from: all), .match(name: "Jane Doe", handle: "5559990000"))
        ETest.eq(RioContactChooser.choose(spoken: "Sarah Lee", from: all), .match(name: "Sarah Lee", handle: "sarah@example.com"))
        ETest.eq(RioContactChooser.choose(spoken: "Sarah", from: all), .ambiguous(["Sarah Cohen", "Sarah Lee"]))
        ETest.eq(RioContactChooser.choose(spoken: "Pat", from: all), .noHandle(name: "Pat Quiet"))
        ETest.eq(RioContactChooser.choose(spoken: "Zed", from: all), .notFound)
        ETest.eq(RioContactChooser.choose(spoken: "", from: all), .notFound)
        ETest.eq(RioContactChooser.choose(spoken: "Ali", from: []), .notFound)
        // Accents and case fold.
        let jose = candidate("José Ruiz", given: "José", family: "Ruiz", phones: [(nil, "555 111 2222")])
        ETest.eq(RioContactChooser.choose(spoken: "JOSE", from: [jose]), .match(name: "José Ruiz", handle: "5551112222"))
        // The same person listed twice is not ambiguous.
        ETest.eq(RioContactChooser.choose(spoken: "Ali", from: [ali, ali]), .match(name: "Ali Khan", handle: "+15552223333"))
        // A phone with too few digits is not a handle.
        let short = candidate("Bo Short", given: "Bo", phones: [(nil, "12345")])
        ETest.eq(RioContactChooser.choose(spoken: "Bo", from: [short]), .noHandle(name: "Bo Short"))
    }

    // MARK: Apps and last message

    private static func testMessagingApps() {
        ETest.eq(RioMessagingApps.info(for: "com.apple.MobileSMS")?.name, "Messages")
        ETest.eq(RioMessagingApps.info(for: "com.apple.MobileSMS")?.sendKey, .returnKey)
        ETest.eq(RioMessagingApps.info(for: "com.tinyspeck.slackmacgap")?.name, "Slack")
        ETest.eq(RioMessagingApps.info(for: "com.apple.mail")?.sendKey, .commandShiftD)
        ETest.eq(RioMessagingApps.info(for: "com.apple.mail")?.canReadMessages, false)
        ETest.eq(RioMessagingApps.info(for: "net.whatsapp.WhatsApp")?.canReadMessages, true)
        ETest.eq(RioMessagingApps.info(for: "com.apple.finder")?.name, nil)
        ETest.eq(RioMessagingApps.info(for: nil)?.name, nil)
        ETest.eq(RioMessagingApps.info(for: "com.apple.mobilesms")?.name, "Messages", "case-insensitive")
    }

    private static func testLastMessagePicker() {
        typealias C = RioMessageCandidate
        let transcript = [
            C(text: "Yesterday", description: nil),
            C(text: "hey are you free tonight", description: "Ali, hey are you free tonight"),
            C(text: "yes, what time?", description: "Your iMessage, yes, what time?"),
            C(text: "8pm?", description: "Ali, 8pm?"),
            C(text: "Delivered", description: nil),
            C(text: "9:41 AM", description: nil),
            C(text: "ok see you then", description: "Your iMessage, ok see you then"),
        ]
        ETest.eq(RioMessagePicker.lastIncoming(from: transcript), "8pm?")
        ETest.eq(RioMessagePicker.lastIncoming(from: []), nil)
        ETest.eq(RioMessagePicker.lastIncoming(from: [C(text: "Read", description: nil), C(text: "Today", description: nil)]), nil)
        ETest.eq(RioMessagePicker.lastIncoming(from: [C(text: "You: sent this", description: nil)]), nil)
        ETest.eq(RioMessagePicker.lastIncoming(from: [C(text: "hi there", description: nil)]), "hi there")
        ETest.eq(RioMessagePicker.lastIncoming(from: [C(text: "  spaced   text ", description: nil)]), "spaced text")
    }

    private static func testReadingText() {
        ETest.eq(RioReadingText.condense(["Hello", "  world ", "", "again"], limit: 100), "Hello world again")
        ETest.eq(RioReadingText.condense([], limit: 100), "")
        let long = (0..<400).map { "word\($0)" }
        let cut = RioReadingText.condense(long, limit: 100)
        TestSupport.expect(cut.count <= 100, "must respect the limit")
        TestSupport.expect(cut.hasPrefix("word0 word1"), "keeps the start")
        TestSupport.expect(!cut.hasSuffix(" ") && cut.split(separator: " ").allSatisfy { $0.hasPrefix("word") && Int($0.dropFirst(4)) != nil }, "cuts on a word boundary")
        TestSupport.expect(RioReadingText.condense(["x"], limit: 0).isEmpty, "zero limit")
    }

    // MARK: Confirmation panel text

    private static func testConfirmationContent() {
        let send = RioConfirmationContent.make(for: .sendMessage(to: "Ali", body: "On my way"), appName: nil, resolvedRecipient: nil)
        ETest.eq(send?.title, "Send a message to Ali?")
        ETest.eq(send?.detail, "On my way")
        ETest.eq(send?.confirmLabel, "Send")
        let resolved = RioConfirmationContent.make(for: .sendMessage(to: "ali", body: "Hi"), appName: nil, resolvedRecipient: "Ali Khan")
        ETest.eq(resolved?.title, "Send a message to Ali Khan?")
        let reply = RioConfirmationContent.make(for: .replyInConversation(body: "Sounds good"), appName: "Slack", resolvedRecipient: nil)
        ETest.eq(reply?.title, "Reply in Slack?")
        ETest.eq(reply?.detail, "Sounds good")
        ETest.eq(RioConfirmationContent.make(for: .replyInConversation(body: "x"), appName: nil, resolvedRecipient: nil)?.title, "Reply in this conversation?")
        let trash = RioConfirmationContent.make(for: .emptyTrash, appName: nil, resolvedRecipient: nil)
        ETest.eq(trash?.title, "Empty the Trash?")
        ETest.eq(trash?.confirmLabel, "Empty Trash")
        TestSupport.expect(RioConfirmationContent.make(for: .lockScreen, appName: nil, resolvedRecipient: nil) == nil, "only confirmable actions have content")
        ETest.eq(RioConfirmationContent.timeoutSeconds, 20)
        // The exact text is shown whole, even when long.
        let long = String(repeating: "a", count: 3000)
        ETest.eq(RioConfirmationContent.make(for: .sendMessage(to: "Ali", body: long), appName: nil, resolvedRecipient: nil)?.detail, long)
    }
}
