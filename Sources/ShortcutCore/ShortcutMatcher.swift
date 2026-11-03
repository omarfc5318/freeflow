import Foundation

enum ShortcutInputEvent: Equatable {
    case modifierChanged(keyCode: UInt16, isDown: Bool)
    case modifierSnapshot(Set<UInt16>)
    case keyChanged(keyCode: UInt16, isDown: Bool, isRepeat: Bool)
    case backendReset
}

enum ShortcutConsumeDecision: Equatable {
    case consume
    case passthrough
}

struct ShortcutInputState: Equatable {
    var pressedKeyCodes: Set<UInt16> = []
    var pressedModifierKeyCodes: Set<UInt16> = []
    var holdIsActive = false
    var toggleIsActive = false
    var copyAgainIsActive = false
    var undoLastIsActive = false
    var fixLastIsActive = false
    /// A bare-modifier Fix Last press became part of a chord and must not fire on release.
    var fixLastTainted = false

    var currentModifiers: ShortcutModifiers {
        ShortcutBinding.modifiers(for: pressedModifierKeyCodes)
    }

    func hasPressedShortcutInputs(configuration: ShortcutConfiguration) -> Bool {
        let currentModifiers = currentModifiers
        let keyReferenceHeld = pressedKeyCodes.contains { keyCode in
            let isHoldKey = configuration.hold.kind == .key && configuration.hold.keyCode == keyCode
            let isToggleKey = configuration.toggle.kind == .key && configuration.toggle.keyCode == keyCode
            let isCopyAgainKey = configuration.copyAgain.kind == .key && configuration.copyAgain.keyCode == keyCode
            let isUndoLastKey = configuration.undoLast.kind == .key && configuration.undoLast.keyCode == keyCode
            let isFixLastKey = configuration.fixLast.kind == .key && configuration.fixLast.keyCode == keyCode
            return isHoldKey || isToggleKey || isCopyAgainKey || isUndoLastKey || isFixLastKey
        }
        if keyReferenceHeld {
            return true
        }

        if configuration.hold.referencesPressedModifiers(
            pressedModifierKeyCodes: pressedModifierKeyCodes,
            currentModifiers: currentModifiers,
            permittedAdditionalExactMatchModifiers: configuration.permittedAdditionalExactMatchModifiers
        ) {
            return true
        }

        if configuration.toggle.referencesPressedModifiers(
            pressedModifierKeyCodes: pressedModifierKeyCodes,
            currentModifiers: currentModifiers,
            permittedAdditionalExactMatchModifiers: configuration.permittedAdditionalExactMatchModifiers
        ) {
            return true
        }

        if configuration.copyAgain.referencesPressedModifiers(
            pressedModifierKeyCodes: pressedModifierKeyCodes,
            currentModifiers: currentModifiers,
            permittedAdditionalExactMatchModifiers: configuration.permittedAdditionalExactMatchModifiers
        ) {
            return true
        }

        if configuration.undoLast.referencesPressedModifiers(
            pressedModifierKeyCodes: pressedModifierKeyCodes,
            currentModifiers: currentModifiers,
            permittedAdditionalExactMatchModifiers: configuration.permittedAdditionalExactMatchModifiers
        ) {
            return true
        }

        if configuration.fixLast.referencesPressedModifiers(
            pressedModifierKeyCodes: pressedModifierKeyCodes,
            currentModifiers: currentModifiers,
            permittedAdditionalExactMatchModifiers: configuration.permittedAdditionalExactMatchModifiers
        ) {
            return true
        }

        return false
    }
}

struct ShortcutMatchResult: Equatable {
    let state: ShortcutInputState
    let emittedEvents: [ShortcutEvent]
    let consumeDecision: ShortcutConsumeDecision
}

enum ShortcutMatcher {
    static func reduce(
        state: ShortcutInputState,
        event: ShortcutInputEvent,
        configuration: ShortcutConfiguration
    ) -> ShortcutMatchResult {
        switch event {
        case .backendReset:
            return reduceBackendReset(state: state, configuration: configuration)

        case .modifierSnapshot(let pressedModifierKeyCodes):
            var nextState = state
            nextState.pressedModifierKeyCodes = pressedModifierKeyCodes

            let emittedEvents = updateActiveBindings(in: &nextState, configuration: configuration)
            return ShortcutMatchResult(
                state: nextState,
                emittedEvents: emittedEvents,
                consumeDecision: emittedEvents.isEmpty ? .passthrough : .consume
            )

        case .modifierChanged(let keyCode, let isDown):
            let shouldConsumeBefore = shouldConsumeModifierEvent(
                for: keyCode,
                state: state,
                configuration: configuration
            )

            var nextState = state
            if isDown {
                nextState.pressedModifierKeyCodes.insert(keyCode)
            } else {
                nextState.pressedModifierKeyCodes.remove(keyCode)
            }

            let shouldConsumeAfter = shouldConsumeModifierEvent(
                for: keyCode,
                state: nextState,
                configuration: configuration
            )
            let emittedEvents = updateActiveBindings(in: &nextState, configuration: configuration)
            return ShortcutMatchResult(
                state: nextState,
                emittedEvents: emittedEvents,
                consumeDecision: (shouldConsumeBefore || shouldConsumeAfter) ? .consume : .passthrough
            )

        case .keyChanged(let keyCode, let isDown, let isRepeat):
            let shouldConsumeBefore = shouldConsumeKeyEvent(
                for: keyCode,
                state: state,
                configuration: configuration
            )

            var nextState = state
            if isRepeat {
                return ShortcutMatchResult(
                    state: nextState,
                    emittedEvents: [],
                    consumeDecision: shouldConsumeBefore ? .consume : .passthrough
                )
            }

            if isDown {
                nextState.pressedKeyCodes.insert(keyCode)
            } else {
                nextState.pressedKeyCodes.remove(keyCode)
            }

            let shouldConsumeAfter = shouldConsumeKeyEvent(
                for: keyCode,
                state: nextState,
                configuration: configuration
            )
            let emittedEvents = updateActiveBindings(in: &nextState, configuration: configuration)
            return ShortcutMatchResult(
                state: nextState,
                emittedEvents: emittedEvents,
                consumeDecision: (shouldConsumeBefore || shouldConsumeAfter) ? .consume : .passthrough
            )
        }
    }

    private static func reduceBackendReset(
        state: ShortcutInputState,
        configuration: ShortcutConfiguration
    ) -> ShortcutMatchResult {
        var nextState = state
        nextState.pressedKeyCodes.removeAll()
        nextState.pressedModifierKeyCodes.removeAll()
        nextState.fixLastTainted = true
        let emittedEvents = updateActiveBindings(in: &nextState, configuration: configuration)
        return ShortcutMatchResult(
            state: nextState,
            emittedEvents: emittedEvents,
            consumeDecision: .passthrough
        )
    }

    private static func updateActiveBindings(
        in state: inout ShortcutInputState,
        configuration: ShortcutConfiguration
    ) -> [ShortcutEvent] {
        let previousHold = state.holdIsActive
        let previousToggle = state.toggleIsActive
        let previousCopyAgain = state.copyAgainIsActive
        let previousUndoLast = state.undoLastIsActive
        let previousFixLast = state.fixLastIsActive

        state.holdIsActive = bindingIsActive(configuration.hold, state: state, configuration: configuration)
        state.toggleIsActive = bindingIsActive(configuration.toggle, state: state, configuration: configuration)
        state.copyAgainIsActive = bindingIsActive(configuration.copyAgain, state: state, configuration: configuration)
        state.undoLastIsActive = bindingIsActive(configuration.undoLast, state: state, configuration: configuration)
        state.fixLastIsActive = bindingIsActive(configuration.fixLast, state: state, configuration: configuration)

        var events = emitChanges(
            previousHold: previousHold,
            previousToggle: previousToggle,
            previousCopyAgain: previousCopyAgain,
            currentHold: state.holdIsActive,
            currentToggle: state.toggleIsActive,
            currentCopyAgain: state.copyAgainIsActive,
            configuration: configuration
        )
        // Undo Last Dictation is a one-shot like Paste Again: leading edge only.
        if !previousUndoLast && state.undoLastIsActive {
            events.insert(.undoLastTriggered, at: 0)
        }
        if fixLastFired(previous: previousFixLast, state: &state, binding: configuration.fixLast) {
            events.insert(.fixLastTriggered, at: 0)
        }
        return events
    }

    /// Key shortcuts fire when pressed. A bare modifier (a lone Right Command tap) fires on
    /// release, and only if nothing else was pressed meanwhile, so chords like Cmd+C or
    /// Cmd+Tab and a modifier held for something else (Fn dictation) never trigger it.
    private static func fixLastFired(
        previous: Bool,
        state: inout ShortcutInputState,
        binding: ShortcutBinding
    ) -> Bool {
        guard binding.kind == .modifierKey else {
            return !previous && state.fixLastIsActive
        }
        let otherModifiers = state.pressedModifierKeyCodes.subtracting([binding.keyCode])
        let isTainted = !otherModifiers.isEmpty || !state.pressedKeyCodes.isEmpty
        if state.fixLastIsActive {
            state.fixLastTainted = (previous ? state.fixLastTainted : false) || isTainted
            return false
        }
        defer { state.fixLastTainted = false }
        return previous && !state.fixLastTainted && !isTainted
    }

    private static func emitChanges(
        previousHold: Bool,
        previousToggle: Bool,
        previousCopyAgain: Bool,
        currentHold: Bool,
        currentToggle: Bool,
        currentCopyAgain: Bool,
        configuration: ShortcutConfiguration
    ) -> [ShortcutEvent] {
        var activations: [(ShortcutEvent, Int)] = []
        var deactivations: [(ShortcutEvent, Int)] = []

        if !previousHold && currentHold {
            activations.append((.holdActivated, configuration.hold.specificityScore))
        }
        if !previousToggle && currentToggle {
            activations.append((.toggleActivated, configuration.toggle.specificityScore))
        }
        // Paste Again is a one-shot: fire on the leading edge only.
        if !previousCopyAgain && currentCopyAgain {
            activations.append((.copyAgainTriggered, configuration.copyAgain.specificityScore))
        }
        if previousHold && !currentHold {
            deactivations.append((.holdDeactivated, configuration.hold.specificityScore))
        }
        if previousToggle && !currentToggle {
            deactivations.append((.toggleDeactivated, configuration.toggle.specificityScore))
        }

        let orderedActivations = activations.sorted(by: { $0.1 > $1.1 }).map(\.0)
        let orderedDeactivations = deactivations.sorted(by: { $0.1 < $1.1 }).map(\.0)
        return orderedActivations + orderedDeactivations
    }

    private static func bindingIsActive(
        _ binding: ShortcutBinding,
        state: ShortcutInputState,
        configuration: ShortcutConfiguration
    ) -> Bool {
        guard !binding.isDisabled else { return false }
        let activeModifiers = state.currentModifiers
        guard binding.modifiersAreActive(
            pressedModifierKeyCodes: state.pressedModifierKeyCodes,
            currentModifiers: activeModifiers,
            permittedAdditionalExactMatchModifiers: configuration.permittedAdditionalExactMatchModifiers
        ) else {
            return false
        }

        switch binding.kind {
        case .disabled:
            return false
        case .key:
            return state.pressedKeyCodes.contains(binding.keyCode)
        case .modifierKey:
            return state.pressedModifierKeyCodes.contains(binding.keyCode)
        }
    }

    private static func shouldConsumeKeyEvent(
        for keyCode: UInt16,
        state: ShortcutInputState,
        configuration: ShortcutConfiguration
    ) -> Bool {
        relevantKeyBindings(for: keyCode, configuration: configuration).contains {
            bindingIsActive($0, state: state, configuration: configuration)
        }
    }

    private static func shouldConsumeModifierEvent(
        for keyCode: UInt16,
        state: ShortcutInputState,
        configuration: ShortcutConfiguration
    ) -> Bool {
        relevantModifierBindings(for: keyCode, configuration: configuration).contains {
            bindingIsActive($0, state: state, configuration: configuration)
        }
    }

    private static func relevantKeyBindings(
        for keyCode: UInt16,
        configuration: ShortcutConfiguration
    ) -> [ShortcutBinding] {
        [configuration.hold, configuration.toggle, configuration.copyAgain, configuration.undoLast, configuration.fixLast].filter { binding in
            binding.kind == .key && binding.keyCode == keyCode
        }
    }

    private static func relevantModifierBindings(
        for keyCode: UInt16,
        configuration: ShortcutConfiguration
    ) -> [ShortcutBinding] {
        // A bare-modifier Fix Last is a tap: its modifier events always pass through to apps.
        let fixLast = configuration.fixLast.kind == .modifierKey ? ShortcutBinding.disabled : configuration.fixLast
        return [configuration.hold, configuration.toggle, configuration.copyAgain, configuration.undoLast, fixLast].filter { binding in
            switch binding.kind {
            case .key, .modifierKey:
                return modifierEvent(for: keyCode, affects: binding)
            case .disabled:
                return false
            }
        }
    }

    private static func modifierEvent(for keyCode: UInt16, affects binding: ShortcutBinding) -> Bool {
        if binding.keyCode == keyCode {
            return true
        }

        if binding.exactModifierKeyCodes != nil {
            return ShortcutBinding.modifierKeyCodes.contains(keyCode)
        }

        return ShortcutBinding.modifierKeyCodes.contains(keyCode)
            && ShortcutBinding.logicalModifier(forKeyCode: keyCode).map(binding.modifiers.contains) == true
    }
}

private extension ShortcutBinding {
    func modifiersAreActive(
        pressedModifierKeyCodes: Set<UInt16>,
        currentModifiers: ShortcutModifiers,
        permittedAdditionalExactMatchModifiers: ShortcutModifiers
    ) -> Bool {
        guard currentModifiers.isSuperset(of: modifiers) else {
            return false
        }

        guard let exactModifierKeyCodes = exactModifierKeyCodes else {
            return true
        }

        if ShortcutBinding.exactModifierKeyCodesMatch(
            pressedModifierKeyCodes,
            exactModifierKeyCodes: exactModifierKeyCodes,
            permittedAdditionalExactMatchModifiers: permittedAdditionalExactMatchModifiers
        ) {
            return true
        }
        return false
    }

    func referencesPressedModifiers(
        pressedModifierKeyCodes: Set<UInt16>,
        currentModifiers: ShortcutModifiers,
        permittedAdditionalExactMatchModifiers: ShortcutModifiers
    ) -> Bool {
        if let exactModifierKeyCodes = exactModifierKeyCodes {
            if !exactModifierKeyCodes.isDisjoint(with: pressedModifierKeyCodes) {
                return true
            }
            if !permittedAdditionalExactMatchModifiers.isEmpty {
                let additionalModifierKeyCodes = ShortcutBinding.matchingModifierKeyCodes(
                    for: permittedAdditionalExactMatchModifiers
                )
                if !additionalModifierKeyCodes.isDisjoint(with: pressedModifierKeyCodes) {
                    return true
                }
            }
        } else if !modifiers.isDisjoint(with: currentModifiers) {
            return true
        }

        guard kind == .modifierKey else { return false }
        return pressedModifierKeyCodes.contains(keyCode)
    }
}
