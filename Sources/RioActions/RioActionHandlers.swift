import Foundation

// Wave 2 extension points (lead-owned). Builders implement these in their own files; see
// docs/rio-actions-plan.md "Wave 2".

/// Runs the wave 2 actions. The executor offers every action it doesn't handle itself to each
/// handler in turn; a handler returns nil when the action isn't its own. `executor` lets a
/// handler run other actions (undo runs the inverse action through it).
@MainActor protocol RioActionHandling: AnyObject {
    func handle(_ action: RioAction, executor: RioActionExecuting) async -> RioActionResult?
}

/// Sees every action the coordinator runs, before and after (the undo journal).
@MainActor protocol RioActionObserving: AnyObject {
    func willExecute(_ action: RioAction) async
    func didExecute(_ action: RioAction, result: RioActionResult)
}

/// Asks the user before an action whose `requiresConfirmation` is true. False = don't run it.
@MainActor protocol RioConfirming: AnyObject {
    func confirm(_ action: RioAction) async -> Bool
}

/// Local phrase parsers added in wave 2. Pure (no AppKit). Tried after the built-in controls and
/// before window/app verbs, so each must only claim phrasings that are unambiguously its own
/// ("open my resume" yes, "open Chrome" never).
enum RioExtraPhrases {
    static func parse(raw: String, simplified: String) -> RioAction? {
        RioContextPhrases.parse(raw: raw, simplified: simplified)
            ?? RioVoicePhrases.parse(raw: raw, simplified: simplified)
            ?? RioKnowledgePhrases.parse(raw: raw, simplified: simplified)
            ?? RioSystemPhrases.parse(raw: raw, simplified: simplified)
    }
}
