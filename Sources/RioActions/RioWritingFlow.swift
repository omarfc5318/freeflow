import Foundation

/// Where the focused text field is, as far as the writing actions care. No AppKit.
struct RioWritingTarget: Equatable {
    var bundleIdentifier: String?
    var appName: String?
    var isSingleLine: Bool
    var isSecure: Bool
}

struct RioWritingLastDictation: Equatable {
    var text: String
    var bundleIdentifier: String?
    var isSingleLine: Bool
}

enum RioWritingReplaceOutcome: Equatable {
    case replaced
    case differentApp
    /// The field no longer holds what was dictated.
    case changed
    case unreadable
}

/// Everything the flows need from the Mac. The real one is `RioWritingActionHandler`; tests pass a
/// fake that records the order of calls.
@MainActor protocol RioWritingPlatform: AnyObject {
    var isEnabled: Bool { get }
    var isOnline: Bool { get }
    var hasAccessibility: Bool { get }
    /// Optional style hint (builder N's profile), nil when there is none.
    var styleHint: String? { get }

    func lastDictation() -> RioWritingLastDictation?
    func replaceLastDictation(expecting original: String, with text: String) async -> RioWritingReplaceOutcome
    func focusedTarget() -> RioWritingTarget?
    /// Types `text` into the field that `target` described. False if the app lost focus.
    func type(_ text: String, into target: RioWritingTarget) async -> Bool

    func clipboardText() -> String?
    func captureClipboard() -> Any
    func setClipboard(_ text: String)
    /// Presses paste in `target`'s app. False if it is no longer in front.
    func sendPaste(into target: RioWritingTarget) async -> Bool
    /// Gives the app time to read the clipboard before it is put back.
    func settle() async
    func restoreClipboard(_ snapshot: Any)
}

enum RioWritingMessages {
    static let disabled = "Writing help is turned off in Settings."
    static let needsAccessibility = "I need Accessibility permission to write into your apps."
    static let noLastDictation = "I can't find your last dictation in a text field. Dictate again, or select the text and say improve this."
    static let noField = "I don't see a text field to write into."
    static let secureField = "I won't write into a password field."
    static let terminal = "I won't paste into a terminal."
    static let tooLong = "That's too long for me to rewrite safely."
    static let emptyClipboard = "Your clipboard has no text."
    static let changed = "Your text changed, so I left it alone."
    static let switched = "You switched apps, so I left your text alone."
    static let unreadable = "I can't edit text in this field. Press Command Z and dictate again."
}

/// The three writing actions, with every safety rule in one testable place.
@MainActor struct RioWritingFlow {
    let platform: RioWritingPlatform
    let llm: RioSmartLLMCompleting

    // MARK: Gate

    private func gate() -> RioActionResult? {
        guard platform.isEnabled else { return .failed(message: RioWritingMessages.disabled) }
        guard platform.isOnline else { return .failed(message: RioSmartMessages.offline) }
        guard platform.hasAccessibility else { return .failed(message: RioWritingMessages.needsAccessibility) }
        return nil
    }

    private enum Asked {
        case text(String)
        case stop(RioActionResult)
    }

    private func ask(system: String, user: String) async -> Asked {
        do {
            let reply = try await llm.complete(system: system, user: user, maxOutputTokens: nil)
            let output = RioWritingPrompts.clean(reply)
            guard !output.isEmpty, output.count <= RioWritingPrompts.maxOutputCharacters else {
                return .stop(.failed(message: RioSmartMessages.unreachable))
            }
            return .text(output)
        } catch RioSmartLLMError.notConfigured {
            return .stop(.failed(message: RioSmartMessages.notConfigured))
        } catch {
            return .stop(.failed(message: RioSmartMessages.unreachable))
        }
    }

    // MARK: Edit last dictation

    func editLast(instruction: String) async -> RioActionResult {
        if let blocked = gate() { return blocked }
        guard let last = platform.lastDictation() else { return .failed(message: RioWritingMessages.noLastDictation) }
        guard !RioImprovePolicy.refusesReplacement(bundleIdentifier: last.bundleIdentifier) else {
            return .failed(message: RioWritingMessages.terminal)
        }
        let original = last.text
        guard original.count <= RioWritingPrompts.maxSourceCharacters else {
            return .failed(message: RioWritingMessages.tooLong)
        }
        let output: String
        switch await ask(
            system: RioWritingPrompts.editSystem(styleHint: platform.styleHint),
            user: RioWritingPrompts.editUser(instruction: instruction, text: original)
        ) {
        case .stop(let result): return result
        case .text(let value): output = value
        }
        let shaped = RioWritingPrompts.shaped(output, singleLine: last.isSingleLine)
        let trailing = RioWritingPrompts.trailingWhitespace(of: original)
        let replacement = shaped + trailing
        if replacement == original { return .done(summary: "It already says that") }
        switch await platform.replaceLastDictation(expecting: original, with: replacement) {
        case .replaced: return .done(summary: "Rewrote that")
        case .differentApp: return .failed(message: RioWritingMessages.switched)
        case .changed: return .failed(message: RioWritingMessages.changed)
        case .unreadable: return .failed(message: RioWritingMessages.unreadable)
        }
    }

    // MARK: Write for me

    func writeForMe(instruction: String) async -> RioActionResult {
        if let blocked = gate() { return blocked }
        guard let target = platform.focusedTarget() else { return .failed(message: RioWritingMessages.noField) }
        if let refused = refusal(for: target) { return refused }
        let output: String
        switch await ask(
            system: RioWritingPrompts.writeSystem(
                styleHint: platform.styleHint, appName: target.appName, singleLine: target.isSingleLine
            ),
            user: RioWritingPrompts.writeUser(instruction: instruction)
        ) {
        case .stop(let result): return result
        case .text(let value): output = value
        }
        // The model took a moment: the same field must still be in front.
        guard let now = platform.focusedTarget(), now.bundleIdentifier == target.bundleIdentifier else {
            return .failed(message: RioWritingMessages.switched)
        }
        if let refused = refusal(for: now) { return refused }
        let text = RioWritingPrompts.shaped(output, singleLine: now.isSingleLine)
        guard await platform.type(text, into: now) else { return .failed(message: RioWritingMessages.switched) }
        return .done(summary: "Wrote it")
    }

    // MARK: Smart paste

    func smartPaste(instruction: String) async -> RioActionResult {
        if let blocked = gate() { return blocked }
        guard let target = platform.focusedTarget() else { return .failed(message: RioWritingMessages.noField) }
        if let refused = refusal(for: target) { return refused }
        guard let source = platform.clipboardText(),
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed(message: RioWritingMessages.emptyClipboard)
        }
        guard source.count <= RioWritingPrompts.maxSourceCharacters else {
            return .failed(message: RioWritingMessages.tooLong)
        }
        let output: String
        switch await ask(
            system: RioWritingPrompts.pasteSystem(singleLine: target.isSingleLine),
            user: RioWritingPrompts.pasteUser(instruction: instruction, text: source)
        ) {
        case .stop(let result): return result
        case .text(let value): output = value
        }
        // Fail closed: the clipboard and the field in front must be what they were.
        guard platform.clipboardText() == source else { return .failed(message: RioWritingMessages.changed) }
        guard let now = platform.focusedTarget(), now.bundleIdentifier == target.bundleIdentifier else {
            return .failed(message: RioWritingMessages.switched)
        }
        if let refused = refusal(for: now) { return refused }
        let text = RioWritingPrompts.shaped(output, singleLine: now.isSingleLine)
        // Borrow the clipboard: set, paste, wait, and always put the owner's clipboard back.
        let snapshot = platform.captureClipboard()
        platform.setClipboard(text)
        let pasted = await platform.sendPaste(into: now)
        if pasted { await platform.settle() }
        platform.restoreClipboard(snapshot)
        return pasted ? .done(summary: "Pasted it") : .failed(message: RioWritingMessages.switched)
    }

    private func refusal(for target: RioWritingTarget) -> RioActionResult? {
        if target.isSecure { return .failed(message: RioWritingMessages.secureField) }
        if RioImprovePolicy.refusesReplacement(bundleIdentifier: target.bundleIdentifier) {
            return .failed(message: RioWritingMessages.terminal)
        }
        return nil
    }
}
