import Foundation

/// One thing the recorder saw. Raw facts only; `RioMacroMapper` decides what becomes an action.
struct RioMacroEvent: Equatable {
    enum Kind: Equatable {
        case appSwitch(name: String)
        /// `label` is the accessibility label of the element under the pointer, if it had one.
        case click(label: String?)
        /// `combo` is the key with its modifiers when it is an allowed key; `typed` is the characters.
        case key(combo: KeyCombo?, typed: String?)
    }

    let kind: Kind
    let bundleID: String?
    /// The focused field is a secure text field, or secure keyboard input is on.
    let isSecureContext: Bool
}

/// Whether "watch me" is recording, readable from the pure parser on any thread. The recorder
/// is the only writer.
enum RioMacroRecordingState {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recording = false

    static var isRecording: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return recording
        }
        set {
            lock.lock()
            recording = newValue
            lock.unlock()
        }
    }
}

/// Turns recorded events into the closed `RioAction` set. Pure. Anything secret is dropped here.
enum RioMacroMapper {
    static let maxSteps = 200
    /// A forgotten recording stops listening after this long (keystrokes are not kept forever).
    static let maxRecordingSeconds: TimeInterval = 5 * 60
    /// Typed text kept per macro and per step, so a forgotten recording can't hold a day of typing.
    static let maxTypedCharacters = 500
    static let maxTypedCharactersPerStep = 200

    /// Password managers, system password prompts and Settings panes that grant permissions.
    static func isSkippedApp(bundleID: String?) -> Bool {
        RioClickSafety.isSensitiveCaptureApp(bundleID: bundleID) || RioClickSafety.isBlockedApp(bundleID: bundleID)
    }

    static func action(for event: RioMacroEvent) -> RioAction? {
        guard !event.isSecureContext, !isSkippedApp(bundleID: event.bundleID) else { return nil }
        switch event.kind {
        case .appSwitch(let name):
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : .switchToApp(name: clean)
        case .click(let label):
            let clean = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, !RioClickSafety.isSensitiveFieldLabel(clean) else { return nil }
            return .click(label: clean, ordinal: nil)
        case .key(let combo, let typed):
            return keyAction(combo: combo, typed: typed)
        }
    }

    private static func keyAction(combo: KeyCombo?, typed: String?) -> RioAction? {
        if let combo, combo.command || combo.control || combo.option {
            return RioKeyCombos.isAllowed(combo) ? .pressKeys(combo) : nil
        }
        if let typed, isPrintable(typed) { return .typeText(typed) }
        if let combo, RioKeyCombos.isAllowed(combo) { return .pressKeys(combo) }
        return nil
    }

    private static func isPrintable(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }
    }

    /// Merges runs of typing, drops a repeated app switch, and caps the length and the typing.
    /// Running it again on its own output changes nothing.
    static func compact(_ actions: [RioAction]) -> [RioAction] {
        var result: [RioAction] = []
        var typed = 0
        for action in actions {
            if case .typeText(let more) = action {
                let room = maxTypedCharacters - typed
                guard room > 0 else { continue }
                var text = String(more.prefix(room))
                typed += text.count
                if case .typeText(let soFar)? = result.last, soFar.count < maxTypedCharactersPerStep {
                    let fits = maxTypedCharactersPerStep - soFar.count
                    result[result.count - 1] = .typeText(soFar + text.prefix(fits))
                    text = String(text.dropFirst(fits))
                }
                while !text.isEmpty {
                    result.append(.typeText(String(text.prefix(maxTypedCharactersPerStep))))
                    text = String(text.dropFirst(maxTypedCharactersPerStep))
                }
            } else if case .switchToApp(let name) = action, case .switchToApp(let previous)? = result.last, name == previous {
                continue
            } else {
                result.append(action)
            }
        }
        return Array(result.prefix(maxSteps))
    }

    /// Characters of typed text in a macro, for "Saved X: 4 steps, 38 typed characters".
    static func typedCharacterCount(_ steps: [RioAction]) -> Int {
        steps.reduce(0) { total, step in
            if case .typeText(let text) = step { return total + text.count }
            return total
        }
    }

    /// Only what the recorder can produce replays; a hand-edited file cannot smuggle in a task.
    static func isReplayable(_ action: RioAction) -> Bool {
        switch action {
        case .switchToApp, .click, .typeText: return true
        case .pressKeys(let combo): return RioKeyCombos.isAllowed(combo)
        default: return false
        }
    }
}
