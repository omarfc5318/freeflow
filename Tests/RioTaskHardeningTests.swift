import Foundation

/// Security hardening of the task, screen and click code (audit H1, H2, M2 and LOWs): web host
/// rules, address-field detection, target resolution, exfiltration checks and observation policy.
enum RioTaskHardeningTests {
    static func run() {
        hostRules()
        addressFields()
        targetResolution()
        exfiltration()
        chromeHandBack()
        observationPolicy()
        stepAndPromptSurface()
        colourHints()
    }

    private static func el(
        _ index: Int, _ kind: RioClickKind, _ texts: [String], web: Bool = true, address: Bool = false
    ) -> RioClickElement {
        RioClickElement(
            index: index, kind: kind, texts: texts, frame: CGRect(x: 0, y: Double(index) * 40, width: 80, height: 24),
            isEnabled: true, isChecked: nil, isInWebArea: web, isAddressField: address
        )
    }

    private static func hostRules() {
        for host in ["localhost", "127.0.0.1", "192.168.1.1", "10.0.0.1", "172.20.0.1", "169.254.169.254", "2130706433",
                     "0x7f.0.0.1", "::1", "[::1]", "printer.local", "router.internal", "app.localhost"] {
            TestSupport.expect(RioWebHostRules.isLocalHost(host), "\(host) is local")
        }
        for host in ["example.com", "www.kayak.com", "shop.example.co.uk", "EXAMPLE.COM"] {
            TestSupport.expect(!RioWebHostRules.isLocalHost(host), "\(host) is public")
        }
        TestSupport.expectEqual(RioWebHostRules.registrableDomain("www.shop.example.co.uk"), "example.co.uk")
        TestSupport.expectEqual(RioWebHostRules.registrableDomain("accounts.google.com"), "google.com")
        TestSupport.expectEqual(RioWebHostRules.registrableDomain("kayak.com"), "kayak.com")
        TestSupport.expectEqual(RioWebHostRules.originKey(URL(string: "https://www.kayak.com/a")!), "https://kayak.com")
        TestSupport.expectEqual(RioWebHostRules.originKey(URL(string: "https://checkout.kayak.com/b")!), "https://kayak.com")
        TestSupport.expect(RioWebHostRules.originKey(URL(string: "http://kayak.com")!) != RioWebHostRules.originKey(URL(string: "https://kayak.com")!),
                           "scheme is part of the origin")
        TestSupport.expect(RioWebHostRules.goalMentions(host: "www.kayak.com", goal: "find a flight on Kayak"), "name as a word")
        TestSupport.expect(RioWebHostRules.goalMentions(host: "www.kayak.com", goal: "open kayak.com and search"), "domain")
        TestSupport.expect(!RioWebHostRules.goalMentions(host: "attacker.example", goal: "find a flight to Doha"), "unrelated")
        TestSupport.expect(!RioWebHostRules.goalMentions(host: "ka.com", goal: "find a flight to Doha"), "short names never match loosely")
    }

    private static func addressFields() {
        TestSupport.expect(RioBrowserChrome.isAddressField(identifier: nil, texts: ["Address and search bar"]), "Chrome")
        TestSupport.expect(RioBrowserChrome.isAddressField(identifier: "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD", texts: []), "Safari identifier")
        TestSupport.expect(RioBrowserChrome.isAddressField(identifier: "urlbar-input", texts: []), "Firefox identifier")
        TestSupport.expect(RioBrowserChrome.isAddressField(identifier: nil, texts: ["Search with Google or enter address"]), "Firefox placeholder")
        TestSupport.expect(RioBrowserChrome.isAddressField(identifier: nil, texts: ["Smart Search Field"]), "Safari label")
        TestSupport.expect(!RioBrowserChrome.isAddressField(identifier: nil, texts: ["Where to?"]), "page field")
        TestSupport.expect(!RioBrowserChrome.isAddressField(identifier: "email", texts: ["Email"]), "page field with id")
    }

    // MARK: H2

    private static func askFor(_ label: String, real: String) -> Bool {
        let elements = [el(0, .button, [real]), el(1, .button, ["Cancel"])]
        let action = RioAction.click(label: label, ordinal: nil)
        let resolution = RioTaskTargetMapper.resolution(for: action, elements: elements)
        if case .confirm = RioTaskSafety.risk(
            of: action, targetLabel: label, narration: "Clicking", modelFlagged: false, goal: "find flights", resolution: resolution
        ) { return true }
        return false
    }

    private static func targetResolution() {
        TestSupport.expect(askFor("Place", real: "Place order"), "Place -> Place order")
        TestSupport.expect(askFor("Yes", real: "Yes, delete my account"), "Yes -> Yes, delete my account")
        TestSupport.expect(askFor("Bay now", real: "Buy now"), "Bay now -> Buy now")
        TestSupport.expect(askFor("Continue", real: "Continue to payment"), "Continue -> Continue to payment")
        let described = [RioClickElement(index: 0, kind: .button, texts: ["Go", "Pay now"], frame: CGRect(x: 0, y: 0, width: 80, height: 24), isEnabled: true, isChecked: nil)]
        let resolution = RioTaskTargetMapper.resolution(for: .click(label: "Go", ordinal: nil), elements: described)
        if case .confirm = RioTaskSafety.risk(of: .click(label: "Go", ordinal: nil), targetLabel: "Go", narration: "Go", modelFlagged: false, goal: "g", resolution: resolution) {} else {
            TestSupport.expect(false, "a risky secondary text asks even on an exact match")
        }
        TestSupport.expect(!askFor("Search", real: "Search"), "exact harmless")
        if case .resolved(_, let exact) = RioTaskTargetMapper.resolution(for: .click(label: "Cancel", ordinal: nil), elements: [el(0, .button, ["Cancel"])]) {
            TestSupport.expect(exact, "exact")
        } else { TestSupport.expect(false, "resolved") }
        TestSupport.expectEqual(RioTaskTargetMapper.resolution(for: .click(label: "Zzz", ordinal: nil), elements: [el(0, .button, ["Cancel"])]), .unresolved)
        TestSupport.expectEqual(RioTaskTargetMapper.resolution(for: .typeText("x"), elements: []), .notApplicable)
        let window = [el(0, .button, ["Search"]), el(1, .textField, ["Search"], web: false, address: true)]
        if case .resolved(let candidates, _) = RioTaskTargetMapper.resolution(for: .fillField(label: "Search", text: "x"), elements: window) {
            TestSupport.expectEqual(candidates.count, 1)
            TestSupport.expect(candidates[0].isAddressField && !candidates[0].isInWebArea, "fill carries the address-field fact")
        } else { TestSupport.expect(false, "fill resolved") }
        TestSupport.expect(RioClickMatcher.resolve(label: "Send", ordinal: nil, in: [el(0, .button, ["Send"])]).isExact, "exact")
        TestSupport.expect(RioClickMatcher.resolve(label: "Send", ordinal: nil, in: [el(0, .button, ["Send now"])]).isExact == false, "prefix is not exact")
        TestSupport.expect(RioClickMatcher.resolve(label: "Send button", ordinal: nil, in: [el(0, .button, ["Send"])]).isExact, "role noun dropped, still exact")
    }

    // MARK: Exfiltration

    private static func exfilReason(_ url: String, goal: String = "find a flight to Doha", page: String? = nil) -> String? {
        RioTaskSafety.exfiltrationReason(url: URL(string: url)!, goal: goal, currentPage: page.flatMap { URL(string: $0) })
    }

    private static func exfiltration() {
        TestSupport.expect(exfilReason("https://attacker.example/?d=hello") != nil, "unnamed other site")
        TestSupport.expect(exfilReason("https://www.kayak.com/flights", goal: "find a flight on kayak") == nil, "named site")
        TestSupport.expect(exfilReason("https://www.kayak.com/flights", goal: "find a flight on kayak.com") == nil, "named domain")
        TestSupport.expect(exfilReason("https://www.google.com/search?q=doha", page: "https://www.google.com/") == nil, "same host, harmless query")
        TestSupport.expect(exfilReason("https://google.com/x", page: "https://www.google.com/") == nil, "www is the same host")
        TestSupport.expect(exfilReason("https://news.example/", page: "https://www.google.com/") != nil, "different host from the page")
        let page = "https://www.google.com/"
        TestSupport.expect(exfilReason("https://www.google.com/?e=bob@example.com", page: page) != nil, "email in the query")
        TestSupport.expect(exfilReason("https://www.google.com/call/+14155550123", page: page) != nil, "phone in the path")
        TestSupport.expect(exfilReason("https://www.google.com/?q=account+number+4111111111111111", page: page) != nil, "digits")
        TestSupport.expect(exfilReason("https://www.google.com/?q=" + String(repeating: "word%20", count: 9), page: page) != nil, "long free text")
        TestSupport.expect(exfilReason("https://www.google.com/?t=" + String(repeating: "a1B2", count: 12), page: page) != nil, "opaque token")
        TestSupport.expect(exfilReason("https://www.google.com/?q=flights+to+doha", page: page) == nil, "short search")
        TestSupport.expect(exfilReason("https://www.google.com/?e=bob@example.com", goal: "look up bob@example.com", page: page) == nil, "in the goal")
        let risky = RioTaskSafety.risk(
            of: .openURL(URL(string: "https://attacker.example/?d=x")!), targetLabel: nil, narration: "Opening", modelFlagged: false,
            goal: "find a flight", currentPage: URL(string: page)
        )
        if case .confirm = risky {} else { TestSupport.expect(false, "openURL to an unnamed site asks") }
    }

    // MARK: H1

    private static func observation(web: Bool = true, address: Bool = false) -> RioTaskObservation {
        RioTaskObservation(
            appName: "Chrome", windowTitle: "t", outline: "", focusedField: nil, imageDataURL: nil,
            focusedInWebArea: web, focusedIsAddressField: address
        )
    }

    private static func chromeHandBack() {
        let ret = RioAction.pressKeys(KeyCombo(key: "return", command: false, shift: false, option: false, control: false))
        let tab = RioAction.pressKeys(KeyCombo(key: "tab", command: false, shift: false, option: false, control: false))
        let page = RioTaskTargetResolution.resolved(candidates: [RioTaskTarget(texts: ["Where to?"], kind: .textField)], isExact: true)
        let bar = RioTaskTargetResolution.resolved(
            candidates: [RioTaskTarget(texts: ["Address and search bar"], kind: .textField, isInWebArea: false, isAddressField: true)], isExact: true
        )
        TestSupport.expect(RioTaskSafety.chromeHandBackReason(for: .fillField(label: "x", text: "y"), observation: observation(), target: bar) != nil, "fill address bar")
        TestSupport.expect(RioTaskSafety.chromeHandBackReason(for: .fillField(label: "x", text: "y"), observation: observation(), target: page) == nil, "fill page field")
        TestSupport.expect(RioTaskSafety.chromeHandBackReason(for: .typeText("y"), observation: observation(web: false), target: .notApplicable) != nil, "type in chrome")
        TestSupport.expect(RioTaskSafety.chromeHandBackReason(for: .typeText("y"), observation: observation(web: false, address: true), target: .notApplicable) != nil, "type in the address bar")
        TestSupport.expect(RioTaskSafety.chromeHandBackReason(for: .typeText("y"), observation: observation(), target: .notApplicable) == nil, "type in the page")
        TestSupport.expect(RioTaskSafety.chromeHandBackReason(for: ret, observation: observation(web: false), target: .notApplicable) != nil, "return in chrome")
        TestSupport.expect(RioTaskSafety.chromeHandBackReason(for: ret, observation: observation(), target: .notApplicable) == nil, "return in the page")
        TestSupport.expect(RioTaskSafety.chromeHandBackReason(for: tab, observation: observation(web: false), target: .notApplicable) == nil, "tab is not Return")
        TestSupport.expect(
            RioTaskSafety.risk(of: ret, targetLabel: "Search", narration: "", modelFlagged: false, goal: "g", focusInWebArea: false) != .safe,
            "search label outside the page is not exempt"
        )
        TestSupport.expect(
            RioTaskSafety.risk(of: ret, targetLabel: "Address and search bar", narration: "", modelFlagged: false, goal: "g", focusIsAddressField: true) != .safe,
            "address field is not exempt"
        )
        TestSupport.expectEqual(
            RioTaskSafety.risk(of: ret, targetLabel: "Search flights", narration: "", modelFlagged: false, goal: "g"), .safe
        )
    }

    // MARK: M2

    private static func observationPolicy() {
        typealias Policy = RioTaskObservationPolicy
        TestSupport.expectEqual(Policy.decide(bundleID: "com.1password.1password", windowTitle: "Vault", screenUnderstandingEnabled: true, screenshotsEnabled: true), .blocked)
        TestSupport.expectEqual(Policy.decide(bundleID: "com.apple.keychainaccess", windowTitle: nil, screenUnderstandingEnabled: true, screenshotsEnabled: true), .blocked)
        TestSupport.expectEqual(Policy.decide(bundleID: "com.apple.securityagent", windowTitle: nil, screenUnderstandingEnabled: true, screenshotsEnabled: true), .blocked)
        TestSupport.expectEqual(Policy.decide(bundleID: "com.apple.systempreferences", windowTitle: "Privacy & Security", screenUnderstandingEnabled: true, screenshotsEnabled: true), .blocked)
        TestSupport.expectEqual(Policy.decide(bundleID: "com.google.Chrome", windowTitle: "Flights", screenUnderstandingEnabled: true, screenshotsEnabled: true), .outlineAndScreenshot)
        TestSupport.expectEqual(Policy.decide(bundleID: "com.google.Chrome", windowTitle: "Flights", screenUnderstandingEnabled: false, screenshotsEnabled: true), .outlineOnly)
        TestSupport.expectEqual(Policy.decide(bundleID: "com.google.Chrome", windowTitle: "Flights", screenUnderstandingEnabled: true, screenshotsEnabled: false), .outlineOnly)
        TestSupport.expectEqual(Policy.fieldValue(label: "Password", isSecure: true, isAddressField: false, value: "hunter2"), nil)
        TestSupport.expectEqual(Policy.fieldValue(label: "Card number", isSecure: false, isAddressField: false, value: "4111 1111 1111 1111"), nil)
        TestSupport.expectEqual(Policy.fieldValue(label: "Notes", isSecure: false, isAddressField: false, value: "4111 1111 1111 1111"), nil)
        TestSupport.expectEqual(Policy.fieldValue(label: "Email", isSecure: false, isAddressField: false, value: "bob@example.com"), nil)
        TestSupport.expectEqual(Policy.fieldValue(label: "Address and search bar", isSecure: false, isAddressField: true, value: "http://x"), nil)
        TestSupport.expectEqual(Policy.fieldValue(label: "Where to?", isSecure: false, isAddressField: false, value: "  "), nil)
        TestSupport.expectEqual(Policy.fieldValue(label: "Where to?", isSecure: false, isAddressField: false, value: "Doha"), "Doha")
        TestSupport.expectEqual(
            Policy.fieldValue(label: "Notes", isSecure: false, isAddressField: false, value: String(repeating: "x", count: 100))?.count, Policy.maxFieldValueCharacters
        )
        let sentence = Policy.disclosure(providerName: "api.groq.com")
        TestSupport.expect(sentence.contains("picture of the front window") && sentence.contains("controls") && sentence.contains("api.groq.com"), sentence)
    }

    // MARK: LOWs

    private static func stepAndPromptSurface() {
        func action(_ json: String) -> RioAction? {
            if case .success(.act(let action, _, _)) = RioTaskStepParser.parse(json) { return action }
            return nil
        }
        for command in ["newTab", "nextTab", "previousTab"] {
            TestSupport.expect(action(#"{"step":"browser","command":"\#(command)"}"#) == nil, "\(command) is not allowed")
        }
        TestSupport.expect(action(#"{"step":"browser","command":"back"}"#) != nil, "back stays")
        for key in ["l", "t"] {
            TestSupport.expect(action(#"{"step":"pressKeys","key":"\#(key)","command":true}"#) == nil, "command-\(key)")
        }
        let system = RioTaskPrompt.system
        for word in ["newTab", "nextTab", "previousTab", "l, f, a or t"] {
            TestSupport.expect(!system.contains(word), "prompt no longer offers \(word)")
        }
        TestSupport.expect(system.contains("command with f or a"), "prompt lists f and a only")
        TestSupport.expect(action(#"{"step":"openURL","url":"http://192.168.0.1/"}"#) == nil, "task refuses IP hosts")
        TestSupport.expect(action(#"{"step":"openURL","url":"https://example.com/"}"#) != nil, "task allows public hosts")
    }

    private static func colourHints() {
        func resolve(_ label: String, _ elements: [RioClickElement]) -> RioClickResolution {
            RioClickMatcher.resolve(label: label, ordinal: nil, in: elements)
        }
        func only(_ resolution: RioClickResolution) -> Int? {
            if case .unique(let element) = resolution.outcome { return element.index }
            return nil
        }
        TestSupport.expectEqual(only(resolve("blue Submit button", [el(0, .button, ["Submit"]), el(1, .link, ["Cancel"])])), 0)
        let two = [el(0, .button, ["Submit", "red"]), el(1, .button, ["Submit", "blue"])]
        TestSupport.expectEqual(only(resolve("blue Submit button", two)), 1)
        TestSupport.expectEqual(only(resolve("red Submit button", two)), 0)
        let buttons = [el(0, .button, ["Next"]), el(1, .button, ["Back", "blue"]), el(2, .link, ["More"])]
        TestSupport.expectEqual(only(resolve("blue button", buttons)), 1)
        if case .ambiguous(let choices) = resolve("blue button", [el(0, .button, ["Next"]), el(1, .button, ["Back"])]).outcome {
            TestSupport.expectEqual(choices.count, 2)
        } else { TestSupport.expect(false, "no blue control: still ambiguous, not dropped") }
        TestSupport.expectEqual(only(resolve("Blue Cross", [el(0, .button, ["Cross"]), el(1, .button, ["Blue Cross"])])), 1)
        TestSupport.expectEqual(only(resolve("blue Send", [el(0, .button, ["Send", "blue"]), el(1, .button, ["Send now"])])), 0)
    }
}
