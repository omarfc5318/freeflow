import Foundation

enum FixLastShortcutTests {
    private static let rightCommand: UInt16 = 54
    private static let leftCommand: UInt16 = 55
    private static let fnKey: UInt16 = 63
    private static let cKey: UInt16 = 8

    private static let configuration = ShortcutConfiguration(
        hold: ShortcutPreset.fnKey.binding, toggle: ShortcutPreset.rightOption.binding,
        fixLast: .defaultFixLast
    )

    static func run() {
        testDefaultIsLoneRightCommand()
        testLoneTapFiresOnRelease()
        testChordWithKeyDoesNotFire()
        testKeyHeldBeforeModifierDoesNotFire()
        testChordWithOtherModifierDoesNotFire()
        testModifierHeldBeforeTapDoesNotFire()
        testSecondTapAfterChordFires()
        testBackendResetDoesNotFire()
        testNeverConsumesModifierEvents()
        testKeyBindingFiresOnPress()
    }

    private static func play(
        _ events: [ShortcutInputEvent], configuration: ShortcutConfiguration = configuration
    ) -> (events: [ShortcutEvent], consumed: Bool) {
        var state = ShortcutInputState()
        var emitted: [ShortcutEvent] = []
        var consumed = false
        for event in events {
            let result = ShortcutMatcher.reduce(state: state, event: event, configuration: configuration)
            state = result.state
            emitted += result.emittedEvents
            consumed = consumed || result.consumeDecision == .consume
        }
        return (emitted, consumed)
    }

    private static func testDefaultIsLoneRightCommand() {
        let binding = ShortcutBinding.defaultFixLast
        TestSupport.expectEqual(binding.keyCode, rightCommand)
        TestSupport.expectEqual(binding.kind, .modifierKey)
        TestSupport.expectEqual(binding.normalizedForStorageMigration(), binding)
    }

    private static func testLoneTapFiresOnRelease() {
        let pressOnly = play([.modifierChanged(keyCode: rightCommand, isDown: true)])
        TestSupport.expectEqual(pressOnly.events, [])
        let tap = play([
            .modifierChanged(keyCode: rightCommand, isDown: true),
            .modifierChanged(keyCode: rightCommand, isDown: false)
        ])
        TestSupport.expectEqual(tap.events, [.fixLastTriggered])
    }

    private static func testChordWithKeyDoesNotFire() {
        // Cmd+C, and Cmd+Tab style (any key while held).
        let chord = play([
            .modifierChanged(keyCode: rightCommand, isDown: true),
            .keyChanged(keyCode: cKey, isDown: true, isRepeat: false),
            .keyChanged(keyCode: cKey, isDown: false, isRepeat: false),
            .modifierChanged(keyCode: rightCommand, isDown: false)
        ])
        TestSupport.expectEqual(chord.events, [])
    }

    private static func testKeyHeldBeforeModifierDoesNotFire() {
        let chord = play([
            .keyChanged(keyCode: cKey, isDown: true, isRepeat: false),
            .modifierChanged(keyCode: rightCommand, isDown: true),
            .modifierChanged(keyCode: rightCommand, isDown: false),
            .keyChanged(keyCode: cKey, isDown: false, isRepeat: false)
        ])
        TestSupport.expectEqual(chord.events, [])
    }

    private static func testChordWithOtherModifierDoesNotFire() {
        let chord = play([
            .modifierChanged(keyCode: rightCommand, isDown: true),
            .modifierChanged(keyCode: leftCommand, isDown: true),
            .modifierChanged(keyCode: leftCommand, isDown: false),
            .modifierChanged(keyCode: rightCommand, isDown: false)
        ])
        TestSupport.expectEqual(chord.events, [])
    }

    private static func testModifierHeldBeforeTapDoesNotFire() {
        // Fn is held for dictation; a Right Command press meanwhile must not open the editor.
        let result = play([
            .modifierChanged(keyCode: fnKey, isDown: true),
            .modifierChanged(keyCode: rightCommand, isDown: true),
            .modifierChanged(keyCode: rightCommand, isDown: false),
            .modifierChanged(keyCode: fnKey, isDown: false)
        ])
        TestSupport.expectEqual(result.events, [.holdActivated, .holdDeactivated])
    }

    private static func testSecondTapAfterChordFires() {
        let result = play([
            .modifierChanged(keyCode: rightCommand, isDown: true),
            .keyChanged(keyCode: cKey, isDown: true, isRepeat: false),
            .keyChanged(keyCode: cKey, isDown: false, isRepeat: false),
            .modifierChanged(keyCode: rightCommand, isDown: false),
            .modifierChanged(keyCode: rightCommand, isDown: true),
            .modifierChanged(keyCode: rightCommand, isDown: false)
        ])
        TestSupport.expectEqual(result.events, [.fixLastTriggered])
    }

    private static func testBackendResetDoesNotFire() {
        let result = play([
            .modifierChanged(keyCode: rightCommand, isDown: true),
            .backendReset
        ])
        TestSupport.expectEqual(result.events, [])
    }

    private static func testNeverConsumesModifierEvents() {
        let result = play([
            .modifierChanged(keyCode: rightCommand, isDown: true),
            .modifierChanged(keyCode: rightCommand, isDown: false)
        ])
        TestSupport.expect(!result.consumed, "Right Command presses must reach apps")
    }

    private static func testKeyBindingFiresOnPress() {
        let binding = ShortcutBinding(
            keyCode: 3, keyDisplay: "F", modifiers: [.control, .option], kind: .key, preset: nil
        )
        let custom = ShortcutConfiguration(hold: .disabled, toggle: .disabled, fixLast: binding)
        let result = play([
            .modifierChanged(keyCode: 59, isDown: true),
            .modifierChanged(keyCode: 58, isDown: true),
            .keyChanged(keyCode: 3, isDown: true, isRepeat: false)
        ], configuration: custom)
        TestSupport.expectEqual(result.events, [.fixLastTriggered])
    }
}
