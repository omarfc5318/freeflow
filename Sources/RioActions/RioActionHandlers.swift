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
    /// In order: earlier parsers win, so each must only claim phrasings that are its own.
    private static let parsers: [(String, String) -> RioAction?] = [
        { RioTranslatorPhrases.parse(raw: $0, simplified: $1) },     // M (before E's "translate this")
        { RioWritingPhrases.parse(raw: $0, simplified: $1) },        // O (before E's reply/selection)
        { RioAutomationPhrases.parse(raw: $0, simplified: $1) },     // P
        { RioMeetingPhrases.parse(raw: $0, simplified: $1) },        // T
        { RioOutsidePhrases.parse(raw: $0, simplified: $1) },        // S
        { RioFindPhrases.parse(raw: $0, simplified: $1) },           // Q
        { RioContextMemoryPhrases.parse(raw: $0, simplified: $1) },  // N
        { RioContextPhrases.parse(raw: $0, simplified: $1) },        // E
        { RioScreenPhrases.parse(raw: $0, simplified: $1) },         // J
        { RioVoicePhrases.parse(raw: $0, simplified: $1) },          // G
        { RioKnowledgePhrases.parse(raw: $0, simplified: $1) },      // H
        { RioMemoryPhrases.parse(raw: $0, simplified: $1) },         // L
        { RioSystemPhrases.parse(raw: $0, simplified: $1) },         // I
        { RioTaskPhrases.parse(raw: $0, simplified: $1) },           // K (last: the broadest)
    ]

    static func parse(raw: String, simplified: String) -> RioAction? {
        for parser in parsers {
            if let action = parser(raw, simplified) { return action }
        }
        return nil
    }
}
