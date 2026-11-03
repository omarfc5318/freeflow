import ApplicationServices
import CoreGraphics
import Foundation

/// Posts allow-listed key presses and scroll-wheel nudges as synthetic CGEvents (need Accessibility).
/// Nothing here takes free-form text: a key must pass `RioKeyCombos.isAllowed` and have a key code.
@MainActor
enum RioKeyboard {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// False if the combo is not allowed. Modifier state comes from the combo only, never from keys
    /// the user is physically holding.
    @discardableResult
    static func post(_ combo: KeyCombo) -> Bool {
        guard RioKeyCombos.isAllowed(combo), let code = RioKeyCodes.code(for: combo.key) else { return false }
        var flags: CGEventFlags = []
        if combo.command { flags.insert(.maskCommand) }
        if combo.shift { flags.insert(.maskShift) }
        if combo.option { flags.insert(.maskAlternate) }
        if combo.control { flags.insert(.maskControl) }
        if RioKeyCodes.usesFunctionFlag(combo.key) { flags.insert(.maskSecondaryFn) }
        if RioKeyCodes.isArrow(combo.key) { flags.insert(.maskNumericPad) }
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: isDown) else { return false }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        return true
    }

    private static let scrollSteps = 12
    private static let scrollStepDelay: UInt64 = 10_000_000

    /// Scrolls whatever is under the pointer, in small pixel steps so it looks like a trackpad flick.
    /// Positive `pixelsDown` scrolls down. A wheel event's positive delta scrolls UP, hence the minus.
    static func scroll(pixelsDown: Int) async {
        let perStep = Int32(pixelsDown / scrollSteps)
        guard perStep != 0 else { return }
        for _ in 0..<scrollSteps {
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -perStep, wheel2: 0, wheel3: 0)
            event?.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: scrollStepDelay)
        }
    }
}
