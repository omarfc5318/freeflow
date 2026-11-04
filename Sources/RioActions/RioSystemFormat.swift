import Foundation

// Pure helpers for system control (builder I): battery text, networksetup parsing and arguments,
// brightness math, and the "what was it before" value the undo journal reads. No AppKit, no I/O.

/// What the undo journal needs to put a system setting back. Read it BEFORE the action runs
/// (`RioSystemControls.priorState(for:)`); `inverseAction` is the action that restores it.
enum RioSystemPriorState: Equatable {
    case toggle(SystemSetting, wasOn: Bool)
    /// Brightness as a percent, 0...100.
    case brightness(percent: Int)

    var inverseAction: RioAction {
        switch self {
        case .toggle(let setting, let wasOn): return .systemToggle(setting, isOn: wasOn)
        case .brightness(let percent): return .brightness(.set(RioBrightness.clamp(percent)))
        }
    }
}

// MARK: Battery

struct BatteryInfo: Equatable {
    let percent: Int
    let isCharging: Bool
    let isPluggedIn: Bool
    let isFullyCharged: Bool
    /// Minutes to full (while charging) or to empty (on battery); nil while macOS is still working it out.
    let minutesRemaining: Int?

    init(percent: Int, isCharging: Bool, isPluggedIn: Bool, isFullyCharged: Bool, minutesRemaining: Int?) {
        self.percent = percent
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.isFullyCharged = isFullyCharged
        self.minutesRemaining = minutesRemaining
    }

    /// From one IOKit power-source description dictionary. Nil unless it is the internal battery
    /// with sane capacities.
    init?(powerSource: [String: Any]) {
        guard (powerSource["Type"] as? String) == "InternalBattery",
              let current = powerSource["Current Capacity"] as? Int,
              let maximum = powerSource["Max Capacity"] as? Int, maximum > 0, current >= 0 else { return nil }
        let charging = (powerSource["Is Charging"] as? Bool) ?? false
        let minutes = (powerSource[charging ? "Time to Full Charge" : "Time to Empty"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        self.init(
            percent: min(100, Int((Double(current) * 100 / Double(maximum)).rounded())),
            isCharging: charging,
            isPluggedIn: (powerSource["Power Source State"] as? String) == "AC Power",
            isFullyCharged: (powerSource["Is Charged"] as? Bool) ?? false,
            minutesRemaining: minutes
        )
    }
}

enum RioBattery {
    static let noBatteryMessage = "This Mac doesn't have a battery"

    static func durationPhrase(minutes: Int) -> String {
        let total = max(0, minutes)
        let hours = total / 60, rest = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if rest > 0 || hours == 0 { parts.append("\(rest) minute\(rest == 1 ? "" : "s")") }
        return parts.joined(separator: " ")
    }

    /// "You're at 64%, charging, about 1 hour to full".
    static func summary(_ info: BatteryInfo) -> String {
        let base = "You're at \(info.percent)%"
        if info.isFullyCharged && info.isPluggedIn { return "\(base) and fully charged" }
        if info.isCharging {
            guard let minutes = info.minutesRemaining else { return "\(base), charging" }
            return "\(base), charging, about \(durationPhrase(minutes: minutes)) to full"
        }
        if info.isPluggedIn { return "\(base), plugged in and not charging" }
        guard let minutes = info.minutesRemaining else { return "\(base) on battery" }
        return "\(base) on battery, about \(durationPhrase(minutes: minutes)) left"
    }
}

// MARK: networksetup

/// The Wi-Fi switch. The only executable is `/usr/sbin/networksetup`; the only free value is the
/// device name Rio discovered itself, validated as `en` plus digits before it is ever used.
enum RioNetworkSetup {
    static let executablePath = "/usr/sbin/networksetup"
    static let listPortsArguments = ["-listallhardwareports"]

    static func isValidDevice(_ device: String) -> Bool {
        guard device.hasPrefix("en") else { return false }
        let digits = device.dropFirst(2)
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func setPowerArguments(device: String, isOn: Bool) -> [String]? {
        isValidDevice(device) ? ["-setairportpower", device, isOn ? "on" : "off"] : nil
    }

    static func getPowerArguments(device: String) -> [String]? {
        isValidDevice(device) ? ["-getairportpower", device] : nil
    }

    /// The Wi-Fi device from `-listallhardwareports` output, nil if none or if it isn't `enN`.
    static func wifiDevice(fromHardwarePorts output: String) -> String? {
        var inWifiPort = false
        for line in output.split(whereSeparator: { $0.isNewline }) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("Hardware Port:") {
                let name = text.dropFirst("Hardware Port:".count).trimmingCharacters(in: .whitespaces).lowercased()
                inWifiPort = name == "wi-fi" || name == "airport"
            } else if inWifiPort, text.hasPrefix("Device:") {
                let device = text.dropFirst("Device:".count).trimmingCharacters(in: .whitespaces)
                return isValidDevice(device) ? device : nil
            }
        }
        return nil
    }

    /// "Wi-Fi Power (en0): On" -> true.
    static func isPoweredOn(output: String) -> Bool? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(": On") { return true }
        if text.hasSuffix(": Off") { return false }
        return nil
    }
}

// MARK: Brightness

enum RioBrightness {
    static let step = 10
    /// The lowest brightness Rio sets on request: a hands-free user who says "brightness to 0"
    /// must still be able to see the screen.
    static let minimumSpoken = 5

    static func clamp(_ percent: Int) -> Int { min(100, max(0, percent)) }

    /// A brightness the owner asked for, never below `minimumSpoken`.
    static func clampSpoken(_ percent: Int) -> Int { min(100, max(minimumSpoken, percent)) }

    static func percent(fromScalar scalar: Float) -> Int { clamp(Int((scalar * 100).rounded())) }

    static func scalar(fromPercent percent: Int) -> Float { Float(clamp(percent)) / 100 }

    /// The percent to set after `change`; nil for mute/unmute, which mean nothing for brightness.
    static func target(after change: VolumeChange, fromPercent current: Int) -> Int? {
        switch change {
        case .up: return clamp(current + step)
        // Down stops at the floor (or where it already is, when it was set lower by hand).
        case .down: return max(min(clamp(current), minimumSpoken), current - step)
        case .set(let level): return clampSpoken(level)
        case .mute, .unmute: return nil
        }
    }
}
