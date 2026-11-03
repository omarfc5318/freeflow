import Foundation

/// Label matching, ranking and ordinals over synthetic element lists (builder J). No real UI.
enum RioClickMatcherTests {
    private static func el(
        _ index: Int, _ kind: RioClickKind, _ texts: [String], x: Double = 0, y: Double = 0,
        enabled: Bool = true
    ) -> RioClickElement {
        RioClickElement(
            index: index, kind: kind, texts: texts, frame: CGRect(x: x, y: y, width: 80, height: 24),
            isEnabled: enabled, isChecked: nil
        )
    }

    private static func resolve(_ label: String, _ ordinal: Int?, _ elements: [RioClickElement]) -> RioClickResolution {
        RioClickMatcher.resolve(label: label, ordinal: ordinal, in: elements)
    }

    private static func resolve(_ label: String, _ elements: [RioClickElement]) -> RioClickResolution {
        RioClickMatcher.resolve(label: label, ordinal: nil, in: elements)
    }

    private static func indexes(_ outcome: RioClickOutcome) -> [Int] {
        switch outcome {
        case .unique(let element): return [element.index]
        case .ambiguous(let list): return list.map(\.index)
        default: return []
        }
    }

    static func run() {
        testRanking()
        testAmbiguity()
        testOrdinals()
        testRoleHints()
        testNormalisation()
        testDisabledAndDuplicates()
        testToggleIntent()
        testSafety()
    }

    private static func testRanking() {
        let list = [el(0, .button, ["Send to all"], x: 10), el(1, .button, ["Send"], x: 100), el(2, .link, ["Resend code"], x: 200)]
        ETest.eq(resolve("send", list).outcome, .unique(list[1]), "exact beats prefix and substring")
        ETest.eq(resolve("Send", list).toggle, nil, "no toggle for a plain click")
        let save = [el(0, .menuItem, ["Autosave settings"]), el(1, .menuItem, ["Save as…"], y: 30)]
        ETest.eq(resolve("save", save).outcome, .unique(save[1]), "prefix beats substring")
        ETest.eq(resolve("nothing like this", list).outcome, .none, "no match")
        ETest.eq(resolve("", list).outcome, .none, "empty label, no ordinal")
        let described = [el(0, .button, ["", "Close tab"]), el(1, .button, ["", "Open menu"], y: 30)]
        ETest.eq(resolve("close tab", described).outcome, .unique(described[0]), "description text matches")
        let words = [el(0, .button, ["Sign in with Google"]), el(1, .button, ["Create account"], y: 30)]
        ETest.eq(resolve("sign in google", words).outcome, .unique(words[0]), "all words present")
    }

    private static func testAmbiguity() {
        let list = [el(0, .button, ["Send to Bo"], x: 200, y: 10), el(1, .button, ["Send to Ali"], x: 10, y: 10)]
        let outcome = resolve("send", list).outcome
        ETest.eq(outcome, .ambiguous([list[1], list[0]]), "equal prefixes are ambiguous, in reading order")
        let many = (0..<14).map { el($0, .button, ["Reply"], x: Double($0 * 100), y: Double($0 * 40)) }
        if case .ambiguous(let capped) = resolve("reply", many).outcome {
            ETest.eq(capped.count, RioClickMatcher.maxChoices, "choices are capped")
            ETest.eq(capped.map(\.index), Array(0..<RioClickMatcher.maxChoices), "capped list keeps reading order")
        } else {
            TestSupport.expect(false, "many equal matches must be ambiguous")
        }
    }

    private static func testOrdinals() {
        let replies = [
            el(0, .button, ["Reply"], x: 10, y: 300), el(1, .button, ["Reply"], x: 10, y: 100),
            el(2, .button, ["Reply"], x: 10, y: 200),
        ]
        ETest.eq(indexes(resolve("Reply", 1, replies).outcome), [1], "first is the topmost")
        ETest.eq(indexes(resolve("Reply", 2, replies).outcome), [2], "second by reading order")
        ETest.eq(indexes(resolve("Reply", 3, replies).outcome), [0], "third")
        ETest.eq(indexes(resolve("Reply", -1, replies).outcome), [0], "last")
        ETest.eq(resolve("Reply", 4, replies).outcome, .ordinalOutOfRange(available: 3), "past the end")
        let mixed = [
            el(0, .button, ["Home"], x: 10, y: 10), el(1, .link, ["Docs"], x: 10, y: 50),
            el(2, .link, ["Pricing"], x: 10, y: 90), el(3, .button, ["Login"], x: 10, y: 130),
            el(4, .link, ["Blog"], x: 10, y: 170),
        ]
        ETest.eq(indexes(resolve("link", 2, mixed).outcome), [2], "second link")
        ETest.eq(indexes(resolve("link", -1, mixed).outcome), [4], "last link")
        ETest.eq(indexes(resolve("link", mixed).outcome), [1, 2, 4], "role only without ordinal is ambiguous")
        let sameRow = [el(0, .link, ["B"], x: 200, y: 12), el(1, .link, ["A"], x: 10, y: 10)]
        ETest.eq(indexes(resolve("link", 1, sameRow).outcome), [1], "same row sorts left to right")
        let withNoFrame = [
            RioClickElement(index: 0, kind: .link, texts: ["X"], frame: nil, isEnabled: true, isChecked: nil),
            el(1, .link, ["Y"], x: 5, y: 5),
        ]
        ETest.eq(indexes(resolve("link", 1, withNoFrame).outcome), [1], "framed elements come first")
        let one = [el(0, .button, ["Compose"])]
        ETest.eq(indexes(resolve("Compose", 1, one).outcome), [0], "ordinal 1 of a single match")
    }

    private static func testRoleHints() {
        let list = [el(0, .link, ["Submit"], x: 10, y: 10), el(1, .button, ["Submit"], x: 10, y: 60)]
        ETest.eq(resolve("Submit button", list).outcome, .unique(list[1]), "button hint")
        ETest.eq(resolve("Submit link", list).outcome, .unique(list[0]), "link hint")
        ETest.eq(indexes(resolve("Submit", list).outcome), [0, 1], "no hint is ambiguous")
        let lone = [el(0, .link, ["Submit"])]
        ETest.eq(resolve("Submit button", lone).outcome, .unique(lone[0]), "hint is soft, not a filter")
        let icon = [el(0, .button, ["Plus"])]
        ETest.eq(resolve("plus icon", icon).outcome, .unique(icon[0]), "icon word is dropped")
        let tabs = [el(0, .tab, ["Inbox"], x: 10), el(1, .tab, ["Sent"], x: 120)]
        ETest.eq(indexes(resolve("tab", 2, tabs).outcome), [1], "second tab")
        ETest.eq(resolve("Sent tab", tabs).outcome, .unique(tabs[1]), "named tab")
    }

    private static func testNormalisation() {
        let signIn = [el(0, .button, ["Sign-in"]), el(1, .button, ["Cancel"], y: 40)]
        ETest.eq(resolve("sign in", signIn).outcome, .unique(signIn[0]), "hyphen vs space")
        let email = [el(0, .button, ["E-mail"]), el(1, .button, ["Cancel"], y: 40)]
        ETest.eq(resolve("email", email).outcome, .unique(email[0]), "compact equal")
        let submit = [el(0, .button, ["Submit"]), el(1, .button, ["Cancel"], y: 40)]
        ETest.eq(resolve("sub mit", submit).outcome, .unique(submit[0]), "speech split a word")
        ETest.eq(resolve("submitt", submit).outcome, .unique(submit[0]), "one typo")
        ETest.eq(resolve("SUBMIT!", submit).outcome, .unique(submit[0]), "case and punctuation")
        ETest.eq(resolve("the Submit", submit).outcome, .unique(submit[0]), "leading article")
        ETest.eq(resolve("sub", submit).outcome, .unique(submit[0]), "short prefix")
        ETest.eq(resolve("xq", submit).outcome, .none, "short junk never fuzzy matches")
        let arabic = [el(0, .button, ["إرسال"]), el(1, .button, ["إلغاء"], y: 40)]
        ETest.eq(resolve("إرسال", arabic).outcome, .unique(arabic[0]), "non-latin labels match")
    }

    private static func testDisabledAndDuplicates() {
        let disabledOnly = [el(0, .button, ["Send"], enabled: false)]
        ETest.eq(resolve("Send", disabledOnly).outcome, .none, "disabled elements are skipped")
        let mixed = [el(0, .button, ["Send"], enabled: false), el(1, .button, ["Send now"], y: 40)]
        ETest.eq(resolve("Send", mixed).outcome, .unique(mixed[1]), "enabled prefix wins over disabled exact")
        let dup = [el(0, .button, ["Send"], x: 10, y: 10), el(1, .button, ["Send"], x: 10, y: 10)]
        ETest.eq(indexes(resolve("Send", dup).outcome).count, 1, "same text and frame is one element")
        if case .unique = resolve("Send", dup).outcome {} else { TestSupport.expect(false, "duplicates collapse to unique") }
    }

    private static func testToggleIntent() {
        let boxes = [
            RioClickElement(index: 0, kind: .checkbox, texts: ["Remember me"], frame: CGRect(x: 0, y: 0, width: 20, height: 20),
                            isEnabled: true, isChecked: false),
            RioClickElement(index: 1, kind: .checkbox, texts: ["Subscribe"], frame: CGRect(x: 0, y: 40, width: 20, height: 20),
                            isEnabled: true, isChecked: true),
        ]
        let check = resolve("check remember me", boxes)
        ETest.eq(check.outcome, .unique(boxes[0]), "check finds the box")
        ETest.eq(check.toggle, .on, "check means on")
        let uncheck = resolve("uncheck subscribe", boxes)
        ETest.eq(uncheck.outcome, .unique(boxes[1]), "uncheck finds the box")
        ETest.eq(uncheck.toggle, .off, "uncheck means off")
        ETest.eq(resolve("tick remember me checkbox", boxes).toggle, .on, "tick with role noun")
        ETest.eq(resolve("untick subscribe", boxes).toggle, .off, "untick")
        let second = resolve("check checkbox", 2, boxes)
        ETest.eq(second.outcome, .unique(boxes[1]), "check the second box")
        ETest.eq(second.toggle, .on, "ordinal check")
        let checkout = [el(0, .button, ["Check out"]), el(1, .button, ["Cancel"], y: 40)]
        let out = resolve("check out", checkout)
        ETest.eq(out.outcome, .unique(checkout[0]), "a real 'Check out' button still clicks")
        ETest.eq(out.toggle, nil, "no toggle for Check out")
        ETest.eq(RioClickMatcher.needsToggle(.on, current: true), false, "already on")
        ETest.eq(RioClickMatcher.needsToggle(.on, current: false), true, "off, wants on")
        ETest.eq(RioClickMatcher.needsToggle(.off, current: true), true, "on, wants off")
        ETest.eq(RioClickMatcher.needsToggle(.off, current: nil), true, "unknown state toggles")
        ETest.eq(RioClickMatcher.needsToggle(nil, current: true), true, "plain click always acts")
    }

    private static func testSafety() {
        ETest.eq(RioClickSafety.isBlockedApp(bundleID: "com.apple.SecurityAgent"), true, "password prompt agent")
        ETest.eq(RioClickSafety.isBlockedApp(bundleID: "com.apple.UserNotificationCenter"), true, "permission alerts")
        ETest.eq(RioClickSafety.isBlockedApp(bundleID: "com.google.Chrome"), false, "Chrome is fine")
        ETest.eq(RioClickSafety.isBlockedApp(bundleID: nil), false, "unknown app is not blocked here")
        for title in ["Privacy & Security", "Screen Recording", "Accessibility", "Full Disk Access", "Microphone",
                      "Input Monitoring", "Camera", "Screen & System Audio Recording", "Security", "Location Services",
                      "Automation", "Files and Folders", "Developer Tools", "", "Privacy"] {
            ETest.eq(RioClickSafety.isBlockedWindow(bundleID: "com.apple.systempreferences", title: title), true, "settings: \(title)")
        }
        ETest.eq(RioClickSafety.isBlockedWindow(bundleID: "com.apple.systempreferences", title: nil), true, "settings, no title")
        ETest.eq(RioClickSafety.isBlockedWindow(bundleID: "com.apple.systempreferences", title: "Wi-Fi"), false, "Wi-Fi pane is fine")
        ETest.eq(RioClickSafety.isBlockedWindow(bundleID: "com.apple.systempreferences", title: "Displays"), false, "Displays pane")
        ETest.eq(RioClickSafety.isBlockedWindow(bundleID: "com.google.Chrome", title: "Privacy"), false, "other apps are fine")
        for label in ["password", "Password field", "enter my passcode", "one time code", "verification code",
                      "security code", "cvv", "card number", "credit card number", "pin", "otp", "2fa code", "cvc"] {
            ETest.eq(RioClickSafety.isSensitiveFieldLabel(label), true, "sensitive: \(label)")
        }
        for label in ["search box", "email", "subject", "name", "zip code", "pinterest", "shipping address"] {
            ETest.eq(RioClickSafety.isSensitiveFieldLabel(label), false, "not sensitive: \(label)")
        }
        for id in ["com.apple.keychainaccess", "com.1password.1password", "com.agilebits.onepassword7", "com.apple.passwords",
                   "com.bitwarden.desktop", "com.apple.SecurityAgent"] {
            ETest.eq(RioClickSafety.isSensitiveCaptureApp(bundleID: id), true, "no capture: \(id)")
        }
        ETest.eq(RioClickSafety.isSensitiveCaptureApp(bundleID: "com.google.Chrome"), false, "capture Chrome")
    }
}
