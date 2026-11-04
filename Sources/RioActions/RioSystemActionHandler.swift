import Foundation

/// Runs builder I's actions: key presses, browser shortcuts, system toggles, brightness, battery
/// and Empty Trash. Returns nil for anything else so the executor offers it to the next handler.
/// `.emptyTrash` is only ever reached through the executor after the coordinator's confirmation.
@MainActor final class RioSystemActionHandler: RioActionHandling {
    static let shared = RioSystemActionHandler()

    func handle(_ action: RioAction, executor: RioActionExecuting) async -> RioActionResult? {
        switch action {
        case .pressKeys(let combo):
            return pressKeys(combo, summary: "Pressed \(RioKeyCombos.describe(combo))")
        case .browser(let command):
            return await browser(command)
        case .systemToggle(let setting, let isOn):
            return await toggle(setting, isOn: isOn)
        case .brightness(let change):
            return changeBrightness(change)
        case .batteryStatus:
            guard let info = RioSystemControls.battery() else { return .done(summary: RioBattery.noBatteryMessage) }
            return .done(summary: RioBattery.summary(info))
        case .emptyTrash:
            return RioSystemControls.emptyTrash()
        default:
            return nil
        }
    }

    // MARK: Keys and browser

    private func pressKeys(_ combo: KeyCombo, summary: String) -> RioActionResult {
        guard RioKeyCombos.isAllowed(combo) else { return .failed(message: "I can't press that key") }
        guard RioKeyboard.isTrusted else { return .failed(message: "I need Accessibility access to press keys") }
        return RioKeyboard.post(combo) ? .done(summary: summary) : .failed(message: "I couldn't press that key")
    }

    private func browser(_ command: BrowserCommand) async -> RioActionResult {
        guard RioKeyboard.isTrusted else { return .failed(message: "I need Accessibility access to do that") }
        switch RioBrowserKeys.plan(for: command) {
        case .keys(let combo):
            return pressKeys(combo, summary: RioBrowserKeys.summary(for: command))
        case .scroll(let pixelsDown):
            await RioKeyboard.scroll(pixelsDown: pixelsDown)
            return .done(summary: RioBrowserKeys.summary(for: command))
        }
    }

    // MARK: System

    private func toggle(_ setting: SystemSetting, isOn: Bool) async -> RioActionResult {
        switch setting {
        case .wifi:
            return await RioSystemControls.setWiFi(isOn)
        case .darkMode:
            return RioSystemControls.setDarkMode(isOn)
        case .bluetooth:
            if let reason = RioBluetoothPower.unavailableReason { return .failed(message: reason) }
            if await RioBluetoothPower.isOn() == isOn { return .done(summary: "Bluetooth is already \(isOn ? "on" : "off")") }
            return await RioBluetoothPower.set(isOn)
                ? .done(summary: "Turned Bluetooth \(isOn ? "on" : "off")")
                : .failed(message: "I couldn't turn Bluetooth \(isOn ? "on" : "off")")
        case .nightShift:
            if RioNightShift.isEnabled() == isOn { return .done(summary: "Night Shift is already \(isOn ? "on" : "off")") }
            return await RioNightShift.set(isOn)
                ? .done(summary: "Turned Night Shift \(isOn ? "on" : "off")")
                : .failed(message: "I couldn't change Night Shift")
        }
    }

    private func changeBrightness(_ change: VolumeChange) -> RioActionResult {
        let unsupported = RioActionResult.failed(message: "I can't change brightness on this display")
        guard let current = RioDisplayBrightness.currentPercent() else { return unsupported }
        guard let target = RioBrightness.target(after: change, fromPercent: current) else {
            return .failed(message: "I can only raise, lower or set brightness")
        }
        guard RioDisplayBrightness.set(percent: target) else { return unsupported }
        return .done(summary: RioBrightness.summary(target: target, after: change))
    }
}
