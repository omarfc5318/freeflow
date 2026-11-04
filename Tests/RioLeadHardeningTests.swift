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
