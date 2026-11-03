import Cocoa

final class HotkeyManager {
    private let backend = GlobalShortcutBackend()
    private var configuration = ShortcutConfiguration(
        hold: .defaultHold,
        toggle: .defaultToggle
    )
    private var inputState = ShortcutInputState()
    /// When a modifier key last went down; used to tell a clean Fix Last tap from a Cmd-click.
    private var lastModifierDownUptime: TimeInterval?

    var onShortcutEvent: ((ShortcutEvent) -> Void)?
    var onEscapeKeyPressed: (() -> Bool)?

    var currentPressedModifiers: ShortcutModifiers {
        inputState.currentModifiers
    }

    var hasPressedShortcutInputs: Bool {
        inputState.hasPressedShortcutInputs(configuration: configuration)
    }

    func start(configuration: ShortcutConfiguration) throws {
        stop()
        self.configuration = configuration
        backend.onInputEvent = { [weak self] event in
            self?.handleInputEvent(event) ?? .passthrough
        }
        backend.onEscapeKeyPressed = { [weak self] in
            self?.onEscapeKeyPressed?() ?? false
        }
        do {
            try backend.start()
        } catch {
            backend.onInputEvent = nil
            backend.onEscapeKeyPressed = nil
            inputState = ShortcutInputState()
            throw error
        }
    }

    func stop() {
        backend.stop()
        backend.onInputEvent = nil
        backend.onEscapeKeyPressed = nil
        inputState = ShortcutInputState()
    }

    deinit {
        stop()
    }

    private func handleInputEvent(_ event: ShortcutInputEvent) -> ShortcutConsumeDecision {
        if case .modifierChanged(_, let isDown) = event, isDown {
            lastModifierDownUptime = ProcessInfo.processInfo.systemUptime
        }
        let result = ShortcutMatcher.reduce(
            state: inputState,
            event: event,
            configuration: configuration
        )
        inputState = result.state
        for event in result.emittedEvents {
            if event == .fixLastTriggered, mouseWentDownSinceModifierPress() { continue }
            onShortcutEvent?(event)
        }
        return result.consumeDecision
    }

    /// The event tap does not listen to mouse events (it must never consume them), so ask the
    /// session whether a button went down after the modifier was pressed (Cmd-click).
    private func mouseWentDownSinceModifierPress() -> Bool {
        guard let pressed = lastModifierDownUptime else { return false }
        let sincePress = ProcessInfo.processInfo.systemUptime - pressed
        let sinceMouseDown = [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown]
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? .greatestFiniteMagnitude
        return ModifierTapMouseGuard.mouseDownedDuringPress(
            secondsSincePress: sincePress, secondsSinceLastMouseDown: sinceMouseDown
        )
    }
}
