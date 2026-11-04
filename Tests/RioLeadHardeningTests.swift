import Foundation

/// Lead fixes for the automated review of fixer B's task hardening (2026-11-03).
enum RioLeadHardeningTests {
    static func run() {
        fillFailsClosed()
        bindsToCheckedElement()
        goalMentionNeedsTheRealDomain()
        sharedHostingSuffixesAreSeparateSites()
        wildcardDNSHostsAreLocal()
        phoneRefusesRiskyActions()
        claudeMishearings()
        automationsCantBeLaundered()
        plannedClicksResolveBeforeDeciding()
        addressBarGuardFailsClosed()
        claudeCodeSendIsGuarded()
    }

    /// "Tell Claude to …" drives a tool-capable agent: never from the phone or an automation,
    /// always confirmed in conversation mode, and confirmed when Claude Code auto-accepts edits.
    private static func claudeCodeSendIsGuarded() {
        let send = RioAction.claudeCode(.send("run the tests"))
        TestSupport.expect(RioCommandSource.phone.refuses(send), "phone can't drive Claude Code")
        TestSupport.expect(RioCommandSource.automation.refuses(send), "automations can't drive Claude Code")
        TestSupport.expect(RioCommandSource.automation.refuses(.claudeCode(.approve)), "automations can't approve")
        TestSupport.expect(send.conversationAlwaysNeedsConfirmation, "conversation mode always asks")
        TestSupport.expect(!RioCommandSource.actionKey.refuses(send), "the action key may")
        TestSupport.expect(RioClaudeScreen.isAutoAcceptMode("…\n⏵⏵ bypass permissions on (shift+tab to cycle)"), "bypass mode")
        TestSupport.expect(RioClaudeScreen.isAutoAcceptMode("⏵⏵ accept edits on (shift+tab to cycle)"), "accept-edits mode")
        TestSupport.expect(!RioClaudeScreen.isAutoAcceptMode("? for shortcuts"), "normal mode")
    }

    /// A click or fill the AI planned is judged on the element it really resolves to.
    private static func plannedClicksResolveBeforeDeciding() {
        let click = RioAction.click(label: "Place", ordinal: nil)
        let placeOrder = RioTaskTarget(texts: ["Place order"], kind: .button)
        TestSupport.expect(RioSmartRouting.resolvedPlannedStepNeedsConfirmation(click, .resolved(candidates: [placeOrder], isExact: false)),
                           "a loose match asks")
        TestSupport.expect(RioSmartRouting.resolvedPlannedStepNeedsConfirmation(click, .unresolved), "unresolved asks")
        let buy = RioTaskTarget(texts: ["Buy now"], kind: .button)
        TestSupport.expect(RioSmartRouting.resolvedPlannedStepNeedsConfirmation(.click(label: "Buy now", ordinal: nil), .resolved(candidates: [buy], isExact: true)),
                           "an exact but risky control asks")
        let next = RioTaskTarget(texts: ["Next page"], kind: .button)
        TestSupport.expect(!RioSmartRouting.resolvedPlannedStepNeedsConfirmation(.click(label: "Next page", ordinal: nil), .resolved(candidates: [next], isExact: true)),
                           "an exact harmless control runs")
        let email = RioTaskTarget(texts: ["Search"], kind: .textField)
        TestSupport.expect(RioSmartRouting.resolvedPlannedStepNeedsConfirmation(.fillField(label: "Search", text: "4111 1111 1111 1111"), .resolved(candidates: [email], isExact: true)),
                           "a card number never fills silently")
    }

    /// The address bar is refused in ANY app that shows one, not only listed browsers.
    private static func addressBarGuardFailsClosed() {
        var observation = RioTaskObservation(appName: "Some Browser", windowTitle: nil, outline: "", focusedField: nil, imageDataURL: nil)
        observation.isBrowser = false
        observation.focusedIsAddressField = true
        observation.focusedInWebArea = false
        let enter = RioAction.pressKeys(KeyCombo(key: "return", command: false, shift: false, option: false, control: false))
        TestSupport.expect(RioTaskSafety.chromeHandBackReason(for: enter, observation: observation, target: .notApplicable) != nil,
                           "Return in an address field is handed back even for an unlisted browser")
        TestSupport.expect(RioTaskSafety.chromeHandBackReason(for: .typeText("x"), observation: observation, target: .notApplicable) != nil,
                           "typing into an address field is handed back")
    }

    /// Automations run later with automation trust, so creating or running one is refused from the
    /// phone and always confirmed in conversation mode (review finding, 2026-11-03).
    private static func automationsCantBeLaundered() {
        let risky: [RioAction] = [
            .scheduleCommand(command: "empty the trash", when: "in 5 minutes"),
            .addTrigger(command: "open Safari", trigger: "when my AirPods connect"),
            .recordMacro(name: "x"), .runMacro(name: "x"), .removeAutomation(name: "x"),
        ]
        for action in risky {
            TestSupport.expect(RioCommandSource.phone.refuses(action), "phone refuses \(action)")
            TestSupport.expect(action.conversationAlwaysNeedsConfirmation, "conversation confirms \(action)")
            TestSupport.expect(!RioCommandSource.actionKey.refuses(action), "the action key may \(action)")
        }
        TestSupport.expect(!RioAction.listAutomations.conversationAlwaysNeedsConfirmation, "listing is harmless")
    }

    /// Whisper hears "Claude" as "cloud" (owner report, 2026-11-03): "go to the cloud window".
    private static func claudeMishearings() {
        let apps = [
            InstalledApp(name: "Claude", bundleIdentifier: "com.anthropic.claudefordesktop", url: URL(fileURLWithPath: "/Applications/Claude.app")),
            InstalledApp(name: "Warp", bundleIdentifier: "dev.warp.Warp-Stable", url: URL(fileURLWithPath: "/Applications/Warp.app")),
        ]
        for spoken in ["cloud", "Cloud", "clawed", "claud", "Cloud Code", "claude code", "cloud desktop", "Claude AI"] {
            TestSupport.expectEqual(AppNameMatcher.bestMatch(for: spoken, in: apps)?.name, "Claude")
        }
        // Whether "go to the cloud window" is parsed locally or handed to the smart resolver, it
        // must never become "I couldn't find an app called Cloud".
        let parsed = RioActionParser(installedApps: apps).parse("Go to the cloud window.")
        if case .actions(let actions) = parsed, case .switchToApp(let name)? = actions.first {
            TestSupport.expectEqual(AppNameMatcher.bestMatch(for: name, in: apps)?.name, "Claude")
        }
    }

    /// From the iPhone, nothing that would need a confirmation runs (no one can press Return).
    private static func phoneRefusesRiskyActions() {
        TestSupport.expect(RioCommandSource.phone.refuses(.sendMessage(to: "Ali", body: "hi")), "phone can't send messages")
        TestSupport.expect(RioCommandSource.phone.refuses(.emptyTrash), "phone can't empty the trash")
        TestSupport.expect(RioCommandSource.phone.refuses(.typeText("x")), "phone can't type into the Mac")
        TestSupport.expect(!RioCommandSource.phone.refuses(.openApp(name: "Spotify")), "phone can open an app")
        TestSupport.expect(!RioCommandSource.automation.refuses(.emptyTrash), "automation asks instead of refusing")
        TestSupport.expect(!RioCommandSource.actionKey.refuses(.sendMessage(to: "Ali", body: "hi")), "the action key asks")
    }

    private static func target(_ texts: [String], webArea: Bool = true) -> RioTaskTarget {
        RioTaskTarget(texts: texts, kind: .textField, isInWebArea: webArea)
    }

    /// A fill whose field can't be resolved, or resolves loosely, never types silently.
    private static func fillFailsClosed() {
        let fill = RioAction.fillField(label: "Email", text: "hello")
        if case .safe = RioTaskSafety.risk(of: fill, targetLabel: nil, narration: "", modelFlagged: false, goal: "sign up",
                                           resolution: .unresolved) {
            TestSupport.expect(false, "an unresolved fill must ask")
        }
        if case .safe = RioTaskSafety.risk(of: fill, targetLabel: nil, narration: "", modelFlagged: false, goal: "sign up",
                                           resolution: .resolved(candidates: [target(["Email address"])], isExact: false)) {
            TestSupport.expect(false, "a non-exact fill must ask")
        }
        if case .confirm = RioTaskSafety.risk(of: fill, targetLabel: nil, narration: "", modelFlagged: false, goal: "sign up",
                                              resolution: .resolved(candidates: [target(["Email"])], isExact: true)) {
            TestSupport.expect(false, "an exact, harmless fill doesn't ask")
        }
    }

    /// After the check, the step is rewritten to the checked element's exact text, so a page that
    /// swaps the control in between makes the step fail instead of pressing something else.
    private static func bindsToCheckedElement() {
        let checked = RioTaskTarget(texts: ["Search flights", "button"], kind: .button)
        TestSupport.expectEqual(
            RioTaskTargetMapper.bind(.click(label: "search", ordinal: nil), to: .resolved(candidates: [checked], isExact: false)),
            .click(label: "Search flights", ordinal: nil)
        )
        TestSupport.expectEqual(
            RioTaskTargetMapper.bind(.fillField(label: "from", text: "SFO"), to: .resolved(candidates: [target(["From airport"])], isExact: false)),
            .fillField(label: "From airport", text: "SFO")
        )
        // Ambiguous or unresolved steps are left alone (they already asked or failed closed).
        let two = [checked, RioTaskTarget(texts: ["Search hotels"], kind: .button)]
        TestSupport.expectEqual(
            RioTaskTargetMapper.bind(.click(label: "search", ordinal: nil), to: .resolved(candidates: two, isExact: false)),
            .click(label: "search", ordinal: nil)
        )
        TestSupport.expectEqual(RioTaskTargetMapper.bind(.browser(.back), to: .notApplicable), .browser(.back))
        // An ordinal ("the second link") was resolved against the original label; relabelling would
        // make it count against a different list, so such steps stay exactly as checked.
        TestSupport.expectEqual(
            RioTaskTargetMapper.bind(.click(label: "link", ordinal: 2), to: .resolved(candidates: [checked], isExact: false)),
            .click(label: "link", ordinal: 2)
        )
    }

    /// Saying "amazon" doesn't make amazon.xyz or amazon-deals.shop the site you named.
    private static func goalMentionNeedsTheRealDomain() {
        TestSupport.expect(RioWebHostRules.goalMentions(host: "www.amazon.com", goal: "find headphones on amazon"), "amazon.com")
        TestSupport.expect(RioWebHostRules.goalMentions(host: "www.kayak.com", goal: "find a flight on kayak"), "kayak.com")
        TestSupport.expect(RioWebHostRules.goalMentions(host: "amazon.ae", goal: "order from amazon.ae"), "full domain named")
        TestSupport.expect(!RioWebHostRules.goalMentions(host: "amazon.xyz", goal: "find headphones on amazon"), "amazon.xyz is not amazon")
        TestSupport.expect(!RioWebHostRules.goalMentions(host: "amazon.evil.io", goal: "find headphones on amazon"), "subdomain trick")
    }

    /// Two different people's sites on a shared host are different sites.
    private static func sharedHostingSuffixesAreSeparateSites() {
        TestSupport.expectEqual(RioWebHostRules.registrableDomain("alice.github.io"), "alice.github.io")
        TestSupport.expectEqual(RioWebHostRules.registrableDomain("x.y.vercel.app"), "y.vercel.app")
        TestSupport.expectEqual(RioWebHostRules.registrableDomain("www.shop.example.co.uk"), "example.co.uk")
        TestSupport.expect(RioWebHostRules.registrableDomain("alice.github.io") != RioWebHostRules.registrableDomain("mallory.github.io"), "separate sites")
    }

    /// Wildcard DNS names that point at your own machine or network (best effort).
    private static func wildcardDNSHostsAreLocal() {
        for host in ["127.0.0.1.nip.io", "192-168-1-1.sslip.io", "app.localtest.me", "x.lvh.me", "10.0.0.1.xip.io", "foo.localhost.direct"] {
            TestSupport.expect(RioWebHostRules.isLocalHost(host), "\(host) is local")
        }
        TestSupport.expect(!RioWebHostRules.isLocalHost("www.nip.com"), "an ordinary domain is fine")
    }
}
