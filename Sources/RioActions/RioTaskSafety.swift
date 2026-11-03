import Foundation

// Safety rules for the multi-step agent (builder K). Pure, no AppKit.
//  - Risky steps (anything that buys, pays, submits, sends, deletes, books or signs in) always
//    ask the user first. The classifier errs toward asking and can only be made stricter by
//    the model, never looser.
//  - Rio never types passwords, card numbers, security codes or one-time codes: it hands the
//    field back to the user and carries on afterwards.

/// The text field that has keyboard focus, as Accessibility describes it.
struct RioTaskFieldInfo: Equatable {
    let label: String?
    let isSecure: Bool
}

enum RioTaskRisk: Equatable {
    case safe
    /// `reason` is the short user-facing line above the exact step.
    case confirm(reason: String)
}

enum RioTaskSafety {
    // MARK: Risky steps

    private static let riskyWords = [
        "buy", "purchase", "pay", "payment", "checkout", "check out", "order", "submit", "send", "post", "publish", "tweet",
        "delete", "remove", "erase", "trash", "book", "booking", "reserve", "reservation", "confirm", "sign in", "sign up",
        "signin", "signup", "log in", "login", "register", "subscribe", "unsubscribe", "donate", "transfer", "withdraw",
        "apply", "accept", "agree", "authorize", "approve", "finish", "complete", "upgrade", "renew", "cancel",
        "proceed to payment", "deleting", "removing", "buying", "paying", "placing", "signing in", "logging in", "confirming",
    ]
    private static let riskyWordPattern: String = {
        let words = riskyWords.map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: #"\s+"#) }
        return #"(?<![\p{L}\p{N}])(?:"# + words.joined(separator: "|") + #")(?:s|es|ed|d|ing|ting)?(?![\p{L}\p{N}])"#
    }()
    private static let riskyURLPattern =
        #"(?:checkout|payment|/pay\b|/pay/|purchase|order|/buy|delete|unsubscribe|logout|signout|sign-out|signin|sign-in|login|log-in|/book|reserve|confirm)"#

    static func isRiskyText(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        return RioText.matches(riskyWordPattern, text)
    }

    static func risk(
        of action: RioAction, targetLabel: String?, narration: String, modelFlagged: Bool, goal: String
    ) -> RioTaskRisk {
        if modelFlagged { return .confirm(reason: "Rio thinks this step needs your OK.") }
        switch action {
        case .click(let label, _):
            if isRiskyText(label) || isRiskyText(targetLabel) || isRiskyText(narration) {
                return .confirm(reason: "This step may buy, send, submit, delete, book or sign in.")
            }
        case .pressKeys(let combo):
            if combo.key == "return" || combo.key == "space" {
                if isRiskyText(targetLabel) || isRiskyText(narration) || isSensitiveLabel(targetLabel) {
                    return .confirm(reason: "Pressing this key may submit, send or sign in.")
                }
            }
        case .openURL(let url):
            let text = [url.host ?? "", url.path, url.query ?? ""].joined(separator: "/").lowercased()
            if RioText.matches(riskyURLPattern, text) {
                return .confirm(reason: "This page looks like a checkout, sign-in or account change.")
            }
        case .fillField(_, let text), .typeText(let text):
            if hasPersonalDetails(text), !goal.localizedCaseInsensitiveContains(text) {
                return .confirm(reason: "This types personal details the page asked for, not ones you gave.")
            }
        default:
            break
        }
        return .safe
    }

    /// Email addresses, phone numbers and long digit runs.
    private static func hasPersonalDetails(_ text: String) -> Bool {
        if RioText.matches(#"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, text) { return true }
        if RioText.matches(#"\d{6,}"#, text) { return true }
        if let groups = RioText.firstMatch(#"\+?\d[\d\s().\-]{7,}\d"#, in: text), let run = groups[0] {
            return run.filter(\.isNumber).count >= 9
        }
        return false
    }

    // MARK: Sensitive fields and values

    private static let sensitiveLabelPattern =
        #"(?<![\p{L}\p{N}])(?:password|passwords|passcode|pass\s?code|passphrase|pin|pin\s+code|cvv|cvc|cvv2|csc|ssn|otp|2fa|mfa|"#
        + #"card\s+number|credit\s+card|debit\s+card|card\s+no|security\s+code|verification\s+code|one[\s\-]?time(?:\s+(?:code|password|passcode|pin))?|"#
        + #"authentication\s+code|authenticator|expiration|expiry|exp\s+date|social\s+security|routing\s+number|account\s+number|iban|"#
        + #"secret\s+answer|security\s+answer|رمز|كلمة\s+المرور|كلمة\s+السر)(?![\p{L}\p{N}])"#

    static func isSensitiveLabel(_ label: String?) -> Bool {
        guard let label, !label.isEmpty else { return false }
        return RioText.matches(sensitiveLabelPattern, label)
    }

    /// Card-like digit runs, social security numbers and "password: ..." style text.
    static func containsSensitiveValue(_ text: String) -> Bool {
        if RioText.matches(#"(?<!\d)\d{3}-\d{2}-\d{4}(?!\d)"#, text) { return true }
        if RioText.matches(#"(?:password|passcode|passphrase|cvv|cvc|otp)\s*(?:is|:|=)"#, text) { return true }
        if RioText.matches(#"(?<!\d)\d(?:[ \-]?\d){12,18}(?!\d)"#, text) { return true }
        return false
    }

    /// Why Rio must not type this itself, or nil when it may. The reason never contains the text.
    static func handBackReason(for action: RioAction, focused: RioTaskFieldInfo?) -> String? {
        switch action {
        case .fillField(let label, let text):
            if isSensitiveLabel(label) { return "\"\(label)\" is private, so please fill it in yourself." }
            if containsSensitiveValue(text) { return "That looks like a card number or password, so please type it yourself." }
        case .typeText(let text):
            if let focused, focused.isSecure || isSensitiveLabel(focused.label) {
                return "That field is private, so please type it yourself."
            }
            if containsSensitiveValue(text) { return "That looks like a card number or password, so please type it yourself." }
        default:
            break
        }
        return nil
    }
}
