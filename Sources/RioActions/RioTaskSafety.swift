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

    /// `resolution` is the control the label really resolves to (security H2): its own texts are
    /// checked as well as the model's wording, and a match that is not exact always asks.
    /// `currentPage` is the page the agent is on, for the "opens another site" check.
    static func risk(
        of action: RioAction, targetLabel: String?, narration: String, modelFlagged: Bool, goal: String,
        resolution: RioTaskTargetResolution = .notApplicable, currentPage: URL? = nil,
        focusInWebArea: Bool = true, focusIsAddressField: Bool = false
    ) -> RioTaskRisk {
        if modelFlagged { return .confirm(reason: "Rio thinks this step needs your OK.") }
        switch action {
        case .click(let label, _):
            if isRiskyText(label) || isRiskyText(targetLabel) || isRiskyText(narration) {
                return .confirm(reason: "This step may buy, send, submit, delete, book or sign in.")
            }
            if let reason = resolvedClickReason(resolution) { return .confirm(reason: reason) }
        case .pressKeys(let combo):
            if combo.key == "return" || combo.key == "space" {
                // The focused element may be a button ("Place order") or a form field whose Return
                // submits; only a search box on the page itself is exempt.
                let isSearchBox = (targetLabel.map { RioText.matches(#"(?i)\bsearch\b"#, $0) } ?? false)
                    && focusInWebArea && !focusIsAddressField
                if !isSearchBox || isRiskyText(targetLabel) || isRiskyText(narration) || isSensitiveLabel(targetLabel) {
                    return .confirm(reason: "Pressing this key may submit, send or sign in.")
                }
            }
        case .openURL(let url):
            let text = [url.host ?? "", url.path, url.query ?? ""].joined(separator: "/").lowercased()
            if RioText.matches(riskyURLPattern, text) {
                return .confirm(reason: "This page looks like a checkout, sign-in or account change.")
            }
            if let reason = exfiltrationReason(url: url, goal: goal, currentPage: currentPage) { return .confirm(reason: reason) }
        case .fillField(_, let text), .typeText(let text):
            if hasPersonalDetails(text), !goal.localizedCaseInsensitiveContains(text) {
                return .confirm(reason: "This types personal details the page asked for, not ones you gave.")
            }
            // Fills fail closed like clicks: an unresolved or loosely matched field asks first.
            if case .fillField = action, let reason = resolvedClickReason(resolution) { return .confirm(reason: reason) }
        default:
            break
        }
        return .safe
    }

    /// Why a click on the resolved control needs the user's OK, or nil. Every text the control has
    /// is checked, and anything short of an exact match asks ("Place" is "Place order").
    private static func resolvedClickReason(_ resolution: RioTaskTargetResolution) -> String? {
        switch resolution {
        case .notApplicable:
            return nil
        case .unresolved:
            return "Rio couldn't check which control that is."
        case .resolved(let candidates, let isExact):
            if candidates.contains(where: { $0.texts.contains(where: { isRiskyText($0) }) }) {
                return "This control may buy, send, submit, delete, book or sign in."
            }
            if !isExact { return "Rio isn't sure which control that is, so it wants your OK first." }
            return nil
        }
    }

    // MARK: Leaving the page (exfiltration)

    private static let longWordCount = 7
    private static let longTextCharacters = 80
    private static let opaqueTokenCharacters = 40

    /// A hostile page can steer `openURL` to `attacker.example/?d=<page data>`. Ask when the host
    /// is not the current page's and the goal doesn't name it, or when the path or query carries
    /// personal details, long free text or an opaque token that the goal doesn't contain.
    static func exfiltrationReason(url: URL, goal: String, currentPage: URL?) -> String? {
        if let host = url.host?.lowercased() {
            let current = currentPage?.host.map(RioWebHostRules.bareHost)
            if current != RioWebHostRules.bareHost(host), !RioWebHostRules.goalMentions(host: host, goal: goal) {
                return "This opens a different site (\(host)) than the one you asked for."
            }
        }
        if carriesPayload(url, goal: goal) {
            return "This address carries text or details you didn't give Rio."
        }
        return nil
    }

    private static func carriesPayload(_ url: URL, goal: String) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        var chunks = parts.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        for item in parts.queryItems ?? [] {
            chunks.append(item.name)
            if let value = item.value { chunks.append(value) }
        }
        if let fragment = parts.fragment { chunks.append(fragment.removingPercentEncoding ?? fragment) }
        let lowerGoal = goal.lowercased()
        for raw in chunks {
            let chunk = raw.replacingOccurrences(of: "+", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !chunk.isEmpty, !lowerGoal.contains(chunk.lowercased()) else { continue }
            if hasPersonalDetails(chunk) { return true }
            let words = chunk.split(whereSeparator: \.isWhitespace).count
            if words >= longWordCount || chunk.count >= longTextCharacters { return true }
            if words == 1, chunk.count >= opaqueTokenCharacters { return true }
        }
        return false
    }

    // MARK: Browser chrome (security H1)

    /// The agent never types into, or presses Return or Space in, browser chrome: the address bar
    /// would reach any URL (local hosts, file:) and Return there would pass as a search. Typing is
    /// allowed only when the focused or target element is inside the page (an AXWebArea).
    /// Returns the hand-back message, or nil.
    static func chromeHandBackReason(
        for action: RioAction, observation: RioTaskObservation, target: RioTaskTargetResolution
    ) -> String? {
        // Address fields are refused in ANY app that shows one (fail closed, even for a browser
        // missing from the list). Only the "outside the page" rule is limited to browsers, because
        // in other apps the fields are the app's own.
        let browser = observation.isBrowser || observation.pageURL != nil || observation.focusedIsAddressField
        let addressBar = "That's the browser's address bar, so please use it yourself."
        let chrome = "That's part of the browser, not the page, so please do that one yourself."
        switch action {
        case .fillField:
            guard case .resolved(let candidates, _) = target else { return nil }
            if candidates.contains(where: { $0.isAddressField }) { return addressBar }
            if browser, candidates.contains(where: { !$0.isInWebArea }) { return chrome }
        case .typeText:
            if observation.focusedIsAddressField { return addressBar }
            if browser, !observation.focusedInWebArea { return chrome }
        case .pressKeys(let combo):
            guard combo.key == "return" || combo.key == "space" else { return nil }
            if observation.focusedIsAddressField { return addressBar }
            if browser, !observation.focusedInWebArea { return chrome }
        default:
            break
        }
        return nil
    }

    /// Email addresses, phone numbers and long digit runs.
    static func hasPersonalDetails(_ text: String) -> Bool {
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
