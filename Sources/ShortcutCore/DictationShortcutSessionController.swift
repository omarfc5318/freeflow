import Foundation

enum DictationShortcutAction: Equatable {
    case start(RecordingTriggerMode)
    case stop
    case switchedToToggle
    /// Throw the recording away: no paste, no action, no error. The conversation chord does
    /// this to a Fn hold or Fn + Control session it interrupted.
    case cancelSilently
}

final class DictationShortcutSessionController {
    private(set) var activeMode: RecordingTriggerMode?
    private(set) var toggleStopArmed = false
    /// The hands-free session was started by a Fn double-tap, so a plain Fn press stops it.
    private(set) var startedByDoubleTap = false
    /// A Fn tap just ended a session; the double-press that can follow it is the same gesture
    /// and must not restart one.
    private var swallowNextDoubleTap = false

    func handle(event: ShortcutEvent, isTranscribing: Bool) -> DictationShortcutAction? {
        // Paste Again is handled before this controller runs; if it ever
        // reaches here, treat as a no-op so dictation state is unaffected.
        if event == .copyAgainTriggered || event == .undoLastTriggered || event == .fixLastTriggered
            || event == .holdActionModifierEngaged { return nil }
        if event == .conversationChord {
            guard activeMode != nil else { return nil }
            reset()
            return .cancelSilently
        }

        if activeMode == nil {
            guard !isTranscribing else { return nil }
            switch event {
            case .toggleActivated:
                if swallowNextDoubleTap {
                    swallowNextDoubleTap = false
                    return nil
                }
                activeMode = .toggle
                toggleStopArmed = false
                startedByDoubleTap = true
                return .start(.toggle)
            case .holdActivated:
                swallowNextDoubleTap = false
                activeMode = .hold
                toggleStopArmed = false
                return .start(.hold)
            case .holdDeactivated, .toggleDeactivated:
                return nil
            case .copyAgainTriggered, .undoLastTriggered, .fixLastTriggered, .holdActionModifierEngaged,
                 .conversationChord:
                return nil
            }
        }

        guard let mode = activeMode else { return nil }

        switch mode {
        case .hold:
            switch event {
            case .toggleActivated:
                activeMode = .toggle
                toggleStopArmed = false
                return .switchedToToggle
            case .holdDeactivated:
                reset()
                return .stop
            case .holdActivated, .toggleDeactivated:
                return nil
            case .copyAgainTriggered, .undoLastTriggered, .fixLastTriggered, .holdActionModifierEngaged,
                 .conversationChord:
                return nil
            }

        case .toggle:
            switch event {
            case .toggleDeactivated:
                toggleStopArmed = true
                return nil
            case .toggleActivated:
                guard toggleStopArmed else { return nil }
                return stopFromToggle()
            case .holdActivated:
                // After a Fn double-tap started it, one more Fn press (released first) stops it.
                guard startedByDoubleTap, toggleStopArmed else { return nil }
                return stopFromToggle()
            case .holdDeactivated:
                return nil
            case .copyAgainTriggered, .undoLastTriggered, .fixLastTriggered, .holdActionModifierEngaged,
                 .conversationChord:
                return nil
            }
        }
    }

    private func stopFromToggle() -> DictationShortcutAction {
        let byFnTap = startedByDoubleTap
        reset()
        swallowNextDoubleTap = byFnTap
        return .stop
    }

    func beginManual(mode: RecordingTriggerMode) {
        activeMode = mode
        toggleStopArmed = false
        startedByDoubleTap = false
    }

    func forceToggleMode() {
        activeMode = .toggle
        toggleStopArmed = false
        startedByDoubleTap = false
    }

    func reset() {
        activeMode = nil
        toggleStopArmed = false
        startedByDoubleTap = false
    }
}
