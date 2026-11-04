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
    /// A Fn press during a double-tap session: it stops the session when Fn is let go, unless
    /// the conversation chord claims the press first.
    private var toggleStopPending = false
    /// When the running hold began (in `now`'s clock).
    private var holdStartedAt: TimeInterval?
    /// The toggle is a double-tap of the hold key, so a hold shorter than a tap may be the first
    /// half of a double-tap: it ends silently (no transcription, no Pop, no shrug) instead of
    /// stopping normally, and the second press is free to start the hands-free session.
    var discardsShortHoldTaps = false
    /// The action modifier (Control) joined the running hold.
    private var actionModifierEngagedDuringHold = false
    /// The last `.cancelSilently` was a short Fn + Control tap (not a double-tap half and not the
    /// conversation chord): it still brakes a running multi-step task.
    private(set) var lastSilentCancelWasActionKeyTap = false

    /// True when a tap of the hold key can be the first half of the toggle's double-tap.
    static func shortHoldTapsMayStartDoubleTap(hold: ShortcutBinding, toggle: ShortcutBinding) -> Bool {
        toggle.kind == .doubleTapModifierKey && !toggle.isDisabled && !hold.isDisabled && hold.keyCode == toggle.keyCode
    }

    func handle(
        event: ShortcutEvent, isTranscribing: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> DictationShortcutAction? {
        // Paste Again is handled before this controller runs; if it ever
        // reaches here, treat as a no-op so dictation state is unaffected.
        lastSilentCancelWasActionKeyTap = false
        if event == .holdActionModifierEngaged {
            if activeMode == .hold { actionModifierEngagedDuringHold = true }
            return nil
        }
        if event == .copyAgainTriggered || event == .undoLastTriggered || event == .fixLastTriggered { return nil }
        if event == .conversationChord {
            guard let mode = activeMode else { return nil }
            // A hands-free session keeps recording: the Fn press that was part of the chord is
            // not a stop. Only a hold (Fn, Fn + Control) is thrown away.
            if mode == .toggle {
                toggleStopPending = false
                return nil
            }
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
                holdStartedAt = now
                actionModifierEngagedDuringHold = false
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
                let wasTap = holdStartedAt.map { now - $0 < ShortcutTiming.maxTapDuration } ?? false
                let withActionKey = actionModifierEngagedDuringHold
                reset()
                guard discardsShortHoldTaps && wasTap else { return .stop }
                lastSilentCancelWasActionKeyTap = withActionKey
                return .cancelSilently
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
                // After a Fn double-tap started it, one more Fn press (released first) stops it
                // when Fn is let go: the press may still turn out to be the conversation chord.
                guard startedByDoubleTap, toggleStopArmed else { return nil }
                toggleStopPending = true
                return nil
            case .holdDeactivated:
                guard toggleStopPending else { return nil }
                return stopFromToggle()
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
        toggleStopPending = false
    }

    func forceToggleMode() {
        activeMode = .toggle
        toggleStopArmed = false
        startedByDoubleTap = false
        toggleStopPending = false
    }

    func reset() {
        activeMode = nil
        toggleStopArmed = false
        startedByDoubleTap = false
        toggleStopPending = false
        holdStartedAt = nil
        actionModifierEngagedDuringHold = false
    }
}
