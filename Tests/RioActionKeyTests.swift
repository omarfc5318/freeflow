import Foundation

/// Fn + Control ("Rio action key") detection, plus regressions proving that Fn alone,
/// the Right Option tap toggle and the lone Right Command Fix Last behave as before.
enum RioActionKeyTests {
    private static let fn: UInt16 = 63
    private static let leftControl: UInt16 = 59
    private static let rightControl: UInt16 = 62
    private static let rightOption: UInt16 = 61
    private static let rightCommand: UInt16 = 54

    private static let actionConfiguration = ShortcutConfiguration(
        hold: ShortcutPreset.fnKey.binding,
        toggle: ShortcutPreset.rightOption.binding,
        fixLast: .defaultFixLast,
        holdActionModifiers: [.control]
    )
    private static let plainConfiguration = ShortcutConfiguration(
        hold: ShortcutPreset.fnKey.binding,
        toggle: ShortcutPreset.rightOption.binding,
        fixLast: .defaultFixLast
    )

    static func run() {
        testFnThenControlEngagesActionKey()
        testControlThenFnEngagesActionKey()
        testRightControlCounts()
        testControlAloneDoesNothing()
        testFnAloneNeverEngages()
        testEngagesOncePerHold()
        testNewHoldStartsClean()
        testBackendResetClearsEngagement()
        testExactHoldBindingSurvivesControlOnlyWhenPermitted()
        testRightOptionToggleUnchanged()
        testFixLastUnchanged()
        testFnHoldEventsMatchPlainConfiguration()
        testSessionControllerIgnoresEngagementEvent()
        testRioActionModifiersPolicy()
        testControlTapStillPassesThroughWhenIdle()
    }

    private static func play(
        _ events: [ShortcutInputEvent], configuration: ShortcutConfiguration = actionConfiguration
    ) -> [[ShortcutEvent]] {
        var state = ShortcutInputState()
        var perEvent: [[ShortcutEvent]] = []
        for event in events {
            let result = ShortcutMatcher.reduce(state: state, event: event, configuration: configuration)
            state = result.state
            perEvent.append(result.emittedEvents)
        }
        return perEvent
    }

    private static func down(_ code: UInt16) -> ShortcutInputEvent { .modifierChanged(keyCode: code, isDown: true) }
    private static func up(_ code: UInt16) -> ShortcutInputEvent { .modifierChanged(keyCode: code, isDown: false) }

    private static func testFnThenControlEngagesActionKey() {
        let steps = play([down(fn), down(leftControl), up(leftControl), up(fn)])
        TestSupport.expectEqual(steps[0], [.holdActivated])
        TestSupport.expectEqual(steps[1], [.holdActionModifierEngaged])
        TestSupport.expectEqual(steps[2], [])
        TestSupport.expectEqual(steps[3], [.holdDeactivated])
    }

    private static func testControlThenFnEngagesActionKey() {
        let steps = play([down(leftControl), down(fn), up(fn), up(leftControl)])
        TestSupport.expectEqual(steps[0], [])
        TestSupport.expectEqual(steps[1], [.holdActivated, .holdActionModifierEngaged])
        TestSupport.expectEqual(steps[2], [.holdDeactivated])
        TestSupport.expectEqual(steps[3], [])
    }

    private static func testRightControlCounts() {
        let steps = play([down(fn), down(rightControl)])
        TestSupport.expectEqual(steps[1], [.holdActionModifierEngaged])
    }

    private static func testControlAloneDoesNothing() {
        let steps = play([down(leftControl), up(leftControl), down(rightControl), up(rightControl)])
        TestSupport.expectEqual(steps.flatMap { $0 }, [])
    }

    private static func testFnAloneNeverEngages() {
        let steps = play([down(fn), up(fn)])
        TestSupport.expectEqual(steps[0], [.holdActivated])
        TestSupport.expectEqual(steps[1], [.holdDeactivated])
    }

    private static func testEngagesOncePerHold() {
        let steps = play([down(fn), down(leftControl), up(leftControl), down(leftControl), up(fn)])
        let engaged = steps.flatMap { $0 }.filter { $0 == .holdActionModifierEngaged }
        TestSupport.expectEqual(engaged.count, 1)
        // Control released and re-pressed while Fn is still held: still the same hold.
        TestSupport.expectEqual(steps[3], [])
    }

    private static func testNewHoldStartsClean() {
        let steps = play([down(fn), down(leftControl), up(fn), up(leftControl), down(fn), up(fn)])
        TestSupport.expectEqual(steps[4], [.holdActivated])
        TestSupport.expectEqual(steps[5], [.holdDeactivated])
    }

    private static func testBackendResetClearsEngagement() {
        let steps = play([down(fn), down(leftControl), .backendReset, down(fn)])
        TestSupport.expectEqual(steps[2], [.holdDeactivated])
        TestSupport.expectEqual(steps[3], [.holdActivated])
    }

    private static func testExactHoldBindingSurvivesControlOnlyWhenPermitted() {
        let exactHold = ShortcutBinding(
            keyCode: fn, keyDisplay: "Fn", modifiers: [.option], kind: .modifierKey, preset: nil,
            exactModifierKeyCodes: [58, 63]
        )
        let permitted = ShortcutConfiguration(hold: exactHold, toggle: .disabled, holdActionModifiers: [.control])
        let strict = ShortcutConfiguration(hold: exactHold, toggle: .disabled)
        let sequence = [down(58), down(fn), down(leftControl)]

        let permittedSteps = play(sequence, configuration: permitted)
        TestSupport.expectEqual(permittedSteps[1], [.holdActivated])
        TestSupport.expectEqual(permittedSteps[2], [.holdActionModifierEngaged])

        let strictSteps = play(sequence, configuration: strict)
        TestSupport.expectEqual(strictSteps[1], [.holdActivated])
        TestSupport.expectEqual(strictSteps[2], [.holdDeactivated])
    }

    private static func testRightOptionToggleUnchanged() {
        let tap = play([down(rightOption), up(rightOption)])
        TestSupport.expectEqual(tap[0], [.toggleActivated])
        TestSupport.expectEqual(tap[1], [.toggleDeactivated])
        // Control never turns the toggle into an action session.
        let withControl = play([down(leftControl), down(rightOption), up(rightOption), up(leftControl)])
        TestSupport.expectEqual(withControl.flatMap { $0 }.contains(.holdActionModifierEngaged), false)
        TestSupport.expectEqual(withControl.flatMap { $0 }, play(
            [down(leftControl), down(rightOption), up(rightOption), up(leftControl)],
            configuration: plainConfiguration
        ).flatMap { $0 })
    }

    private static func testFixLastUnchanged() {
        let tap = play([down(rightCommand), up(rightCommand)])
        TestSupport.expectEqual(tap[1], [.fixLastTriggered])
        // Holding the action key never makes a Right Command tap fire Fix Last.
        let chord = play([down(fn), down(leftControl), down(rightCommand), up(rightCommand), up(leftControl), up(fn)])
        TestSupport.expectEqual(chord.flatMap { $0 }.contains(.fixLastTriggered), false)
    }

    private static func testFnHoldEventsMatchPlainConfiguration() {
        let sequences: [[ShortcutInputEvent]] = [
            [down(fn), up(fn)],
            [down(fn), down(55), up(55), up(fn)],
            [down(rightOption), down(fn), up(fn), up(rightOption)],
            [down(fn), down(rightOption), up(rightOption), up(fn)],
            [down(rightCommand), up(rightCommand), down(fn), up(fn)]
        ]
        for sequence in sequences {
            TestSupport.expectEqual(play(sequence), play(sequence, configuration: plainConfiguration))
        }
    }

    private static func testSessionControllerIgnoresEngagementEvent() {
        let controller = DictationShortcutSessionController()
        TestSupport.expectEqual(controller.handle(event: .holdActivated, isTranscribing: false), .start(.hold))
        TestSupport.expectEqual(controller.handle(event: .holdActionModifierEngaged, isTranscribing: false), nil)
        TestSupport.expectEqual(controller.activeMode, .hold)
        TestSupport.expectEqual(controller.handle(event: .holdDeactivated, isTranscribing: false), .stop)

        let idle = DictationShortcutSessionController()
        TestSupport.expectEqual(idle.handle(event: .holdActionModifierEngaged, isTranscribing: false), nil)
        TestSupport.expectEqual(idle.activeMode, nil)
    }

    private static func testRioActionModifiersPolicy() {
        let fnHold = ShortcutPreset.fnKey.binding
        TestSupport.expectEqual(ShortcutConfiguration.rioActionModifiers(enabled: true, hold: fnHold), [.control])
        TestSupport.expectEqual(ShortcutConfiguration.rioActionModifiers(enabled: false, hold: fnHold), [])
        let controlHold = ShortcutBinding(
            keyCode: rightControl, keyDisplay: "Right Control", modifiers: [], kind: .modifierKey, preset: nil
        )
        TestSupport.expectEqual(ShortcutConfiguration.rioActionModifiers(enabled: true, hold: controlHold), [])
        let ctrlChord = ShortcutBinding(
            keyCode: 96, keyDisplay: "F5", modifiers: [.control], kind: .key, preset: nil
        )
        TestSupport.expectEqual(ShortcutConfiguration.rioActionModifiers(enabled: true, hold: ctrlChord), [])
        TestSupport.expectEqual(ShortcutConfiguration.rioActionModifiers(enabled: true, hold: .disabled), [])
    }

    private static func testControlTapStillPassesThroughWhenIdle() {
        var state = ShortcutInputState()
        let result = ShortcutMatcher.reduce(state: state, event: down(leftControl), configuration: actionConfiguration)
        state = result.state
        TestSupport.expectEqual(result.consumeDecision, .passthrough)
    }
}
