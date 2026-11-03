import Foundation

/// The risky-step classifier and the sensitive-field rules: the agent must ask before anything
/// final and must never type credentials, card numbers or one-time codes.
enum RioTaskSafetyTests {
    private static func risk(
        _ action: RioAction, label: String? = nil, say: String = "", flagged: Bool = false, goal: String = "find flights"
    ) -> Bool {
        if case .confirm = RioTaskSafety.risk(of: action, targetLabel: label, narration: say, modelFlagged: flagged, goal: goal) {
            return true
        }
        return false
    }

    private static let returnKey = RioAction.pressKeys(KeyCombo(key: "return", command: false, shift: false, option: false, control: false))

    static func run() {
        riskyClicks()
        returnAsksUnlessSearch()
        safeClicks()
        otherActions()
        piiTyping()
        sensitiveLabels()
        sensitiveValues()
        handBack()
    }

    private static func riskyClicks() {
        let labels = [
            "Buy now", "Purchase", "Pay $42.00", "Pay now", "Checkout", "Check out", "Place order", "Place your order",
            "Submit", "Submit application", "Send", "Send message", "Delete", "Delete account", "Remove", "Book now", "Book flight",
            "Reserve", "Reserve a table", "Confirm booking", "Confirm", "Sign in", "Sign In", "Log in", "Login", "Sign up",
            "Subscribe", "Donate", "Transfer", "Apply", "Apply now", "Post", "Publish", "Tweet", "Accept and continue", "Agree",
            "Complete purchase", "Finish", "Unsubscribe", "Cancel subscription", "Upgrade", "Renew", "Approve", "Authorize",
            "SEND", "submit.", "Pay", "Proceed to payment", "Register",
        ]
        for label in labels {
            TestSupport.expect(risk(.click(label: label, ordinal: nil), label: label), "\(label) must ask")
        }
        // The narration alone can make a click risky.
        TestSupport.expect(risk(.click(label: "Go", ordinal: nil), label: "Go", say: "Submitting the form"), "narration risky")
        // The model can always raise the alarm, never lower it.
        TestSupport.expect(risk(.click(label: "Go", ordinal: nil), label: "Go", flagged: true), "model flag")
        TestSupport.expect(risk(.click(label: "Buy now", ordinal: nil), label: "Buy now", flagged: false), "no flag still asks")
    }

    private static func safeClicks() {
        let labels = ["Search", "Search flights", "Next page", "Filters", "Sort by price", "Menu", "Doha", "Show more", "Learn more", "Close", "Date", "Nonstop only"]
        for label in labels {
            TestSupport.expect(!risk(.click(label: label, ordinal: nil), label: label), "\(label) is fine")
        }
        // Word boundaries: "Sender" is not "Send", "Posture" is not "Post".
        TestSupport.expect(!risk(.click(label: "Sender settings", ordinal: nil), label: "Sender settings"), "word boundary")
        TestSupport.expect(!risk(.click(label: "Posture tips", ordinal: nil), label: "Posture tips"), "word boundary 2")
    }

    private static func otherActions() {
        TestSupport.expect(risk(returnKey, label: "Submit", say: ""), "return in a Submit-labelled focus asks")
        TestSupport.expect(risk(returnKey, label: nil, say: "Sending the email"), "return with risky narration asks")
        TestSupport.expect(risk(returnKey, label: "Password", say: ""), "return in a password field is a sign-in")
        TestSupport.expect(!risk(returnKey, label: "Search", say: "Searching"), "return in a search box is fine")
        // Security fix (lead): Return with an unknown focus may press a button, so it asks.
        TestSupport.expect(risk(returnKey, label: nil, say: ""), "plain return with unknown focus asks")

        func url(_ text: String) -> RioAction { .openURL(URL(string: text)!) }
        TestSupport.expect(risk(url("https://shop.example.com/checkout?cart=1")), "checkout url")
        TestSupport.expect(risk(url("https://example.com/payment/confirm")), "payment url")
        TestSupport.expect(risk(url("https://example.com/account/delete")), "delete url")
        TestSupport.expect(risk(url("https://example.com/logout")), "logout url")
        TestSupport.expect(risk(url("https://accounts.example.com/signin")), "signin url")
        TestSupport.expect(risk(url("https://example.com/login")), "login url")
        TestSupport.expect(risk(url("https://example.com/unsubscribe?id=1")), "unsubscribe url")
        TestSupport.expect(!risk(url("https://www.google.com/travel/flights?q=doha")), "flight search url")
        TestSupport.expect(!risk(url("https://www.kayak.com/flights/NYC-DOH/2026-11-13")), "kayak url")
        TestSupport.expect(!risk(.browser(.scrollDown)), "scroll is fine")
        TestSupport.expect(!risk(.browser(.back)), "back is fine")
        TestSupport.expect(risk(.browser(.back), flagged: true), "flag works for any action")
    }

    private static func piiTyping() {
        TestSupport.expect(!risk(.fillField(label: "Where to?", text: "Doha")), "city is fine")
        TestSupport.expect(!risk(.typeText("flights to Doha under 800")), "query is fine")
        TestSupport.expect(risk(.fillField(label: "Notes", text: "contact me at evil@example.com")), "email not in goal asks")
        TestSupport.expect(risk(.typeText("call +1 555 123 4567")), "phone not in goal asks")
        TestSupport.expect(risk(.typeText("my number is 123456")), "6 digit run not in goal asks")
        TestSupport.expect(!risk(.fillField(label: "Email", text: "me@example.com"), goal: "sign me up with me@example.com"), "text the user said is fine")
        TestSupport.expect(risk(.fillField(label: "Email", text: "other@example.com"), goal: "sign me up with me@example.com"), "different email asks")
    }

    private static func sensitiveLabels() {
        let sensitive = [
            "Password", "password", "Confirm password", "Current Password", "Passcode", "PIN", "Card number", "Credit card number",
            "Card Number", "CVV", "CVC", "Security code", "Verification code", "One-time code", "One time password", "OTP",
            "2FA code", "Authentication code", "Expiration date", "Expiry", "Social Security Number", "SSN", "Routing number",
            "Account number", "رمز المرور",
        ]
        for label in sensitive {
            TestSupport.expect(RioTaskSafety.isSensitiveLabel(label), "\(label) is sensitive")
        }
        for label in ["Where to?", "Name", "Email", "Search", "Departure date", "Pinterest", "Spinning", "Notes", "Passenger name", nil] {
            TestSupport.expect(!RioTaskSafety.isSensitiveLabel(label), "\(label ?? "nil") is not sensitive")
        }
    }

    private static func sensitiveValues() {
        for text in ["4111 1111 1111 1111", "4111-1111-1111-1111", "4111111111111111", "378282246310005", "123-45-6789", "my password is hunter2", "password: abc"] {
            TestSupport.expect(RioTaskSafety.containsSensitiveValue(text), "\(text) is sensitive")
        }
        for text in ["Doha", "flights under 800", "2026-11-13", "June 4 2026", "Room 4021", "call 555 1234", "12345", ""] {
            TestSupport.expect(!RioTaskSafety.containsSensitiveValue(text), "\(text) is not sensitive")
        }
    }

    private static func handBack() {
        let secure = RioTaskFieldInfo(label: "Password", isSecure: true)
        let plain = RioTaskFieldInfo(label: "Search", isSecure: false)
        TestSupport.expect(RioTaskSafety.handBackReason(for: .fillField(label: "Password", text: "x"), focused: nil) != nil, "label")
        TestSupport.expect(RioTaskSafety.handBackReason(for: .fillField(label: "Card number", text: "4111111111111111"), focused: nil) != nil, "card")
        TestSupport.expect(RioTaskSafety.handBackReason(for: .fillField(label: "Notes", text: "4111 1111 1111 1111"), focused: nil) != nil, "value")
        TestSupport.expect(RioTaskSafety.handBackReason(for: .typeText("hunter2"), focused: secure) != nil, "secure focus")
        TestSupport.expect(RioTaskSafety.handBackReason(for: .typeText("x"), focused: RioTaskFieldInfo(label: "Verification code", isSecure: false)) != nil, "otp focus")
        TestSupport.expect(RioTaskSafety.handBackReason(for: .typeText("4111111111111111"), focused: plain) != nil, "card in plain field")
        TestSupport.expect(RioTaskSafety.handBackReason(for: .typeText("hello"), focused: plain) == nil, "plain text")
        TestSupport.expect(RioTaskSafety.handBackReason(for: .fillField(label: "Where to?", text: "Doha"), focused: nil) == nil, "plain fill")
        TestSupport.expect(RioTaskSafety.handBackReason(for: .click(label: "Search", ordinal: nil), focused: secure) == nil, "click is not typing")
        TestSupport.expect(RioTaskSafety.handBackReason(for: .browser(.scrollDown), focused: secure) == nil, "scroll is not typing")
    }

    /// Return/Space on a focused button ("Place order") or an unknown element must ask; only a
    /// search box is exempt.
    private static func returnAsksUnlessSearch() {
        let enter = RioAction.pressKeys(KeyCombo(key: "return", command: false, shift: false, option: false, control: false))
        let space = RioAction.pressKeys(KeyCombo(key: "space", command: false, shift: false, option: false, control: false))
        TestSupport.expect(risk(enter, label: nil), "Return on an unknown/non-text element asks")
        TestSupport.expect(risk(enter, label: "Name"), "Return in a form field asks (it may submit)")
        TestSupport.expect(risk(space, label: nil), "Space on a focused button asks")
        TestSupport.expect(!risk(enter, label: "Search flights"), "Return in a search box is fine")
        TestSupport.expect(!risk(enter, label: "Search"), "Return in a search box is fine")
    }
}
