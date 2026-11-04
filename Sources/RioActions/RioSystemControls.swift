import AppKit
import Foundation
import IOKit.ps

/// Wi-Fi, dark mode, battery and Empty Trash. The only executable is `/usr/sbin/networksetup` with
/// fixed arguments and a device name Rio discovered and validated itself; AppleScript source is
/// always one of the fixed strings below.
@MainActor
enum RioSystemControls {
    // MARK: Wi-Fi

    private struct ToolOutput: Sendable {
        let status: Int32
        let output: String
    }

    /// Thread-safe growing buffer for a child process's output.
    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        var string: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private static func networksetup(_ arguments: [String]) async -> ToolOutput? {
        await withCheckedContinuation { (continuation: CheckedContinuation<ToolOutput?, Never>) in
            guard FileManager.default.isExecutableFile(atPath: RioNetworkSetup.executablePath) else {
                continuation.resume(returning: nil)
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: RioNetworkSetup.executablePath)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            // Drain the pipe while the tool runs: reading only after exit would deadlock once the
            // output outgrows the pipe buffer (the tool blocks on write, never exits).
            let collected = OutputCollector()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    collected.append(chunk)
                }
            }
            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                collected.append(pipe.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: ToolOutput(status: finished.terminationStatus, output: collected.string))
            }
            do { try process.run() } catch { continuation.resume(returning: nil) }
        }
    }

    private static func wifiDevice() async -> String? {
        guard let listing = await networksetup(RioNetworkSetup.listPortsArguments), listing.status == 0 else { return nil }
        return RioNetworkSetup.wifiDevice(fromHardwarePorts: listing.output)
    }

    static func isWiFiOn() async -> Bool? {
        guard let device = await wifiDevice(), let arguments = RioNetworkSetup.getPowerArguments(device: device),
              let result = await networksetup(arguments), result.status == 0 else { return nil }
        return RioNetworkSetup.isPoweredOn(output: result.output)
    }

    static func setWiFi(_ isOn: Bool) async -> RioActionResult {
        guard let device = await wifiDevice() else { return .failed(message: "I can't find this Mac's Wi-Fi") }
        if let getArguments = RioNetworkSetup.getPowerArguments(device: device),
           let current = await networksetup(getArguments), RioNetworkSetup.isPoweredOn(output: current.output) == isOn {
            return .done(summary: "Wi-Fi is already \(isOn ? "on" : "off")")
        }
        guard let arguments = RioNetworkSetup.setPowerArguments(device: device, isOn: isOn),
              let result = await networksetup(arguments), result.status == 0 else {
            return .failed(message: "I couldn't turn Wi-Fi \(isOn ? "on" : "off")")
        }
        return .done(summary: "Turned Wi-Fi \(isOn ? "on" : "off")")
    }

    // MARK: Dark mode

    private static let darkOnScript = #"tell application "System Events" to tell appearance preferences to set dark mode to true"#
    private static let darkOffScript = #"tell application "System Events" to tell appearance preferences to set dark mode to false"#

    static func isDarkMode() -> Bool {
        let key = "AppleInterfaceStyle" as CFString
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let value = CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
        return value == "Dark"
    }

    static func setDarkMode(_ isOn: Bool) -> RioActionResult {
        if isDarkMode() == isOn { return .done(summary: isOn ? "Dark mode is already on" : "It's already light mode") }
        guard let script = NSAppleScript(source: isOn ? darkOnScript : darkOffScript) else {
            return .failed(message: "I couldn't change dark mode")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 {
                return .failed(message: "I need permission to control System Events. Allow it in Privacy and Security, Automation")
            }
            return .failed(message: "I couldn't change dark mode")
        }
        return .done(summary: isOn ? "Switched to dark mode" : "Switched to light mode")
    }

    // MARK: Battery

    /// Nil when this Mac has no internal battery.
    static func battery() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let info = BatteryInfo(powerSource: description) else { continue }
            return info
        }
        return nil
    }

    // MARK: Empty Trash (callers must have the user's confirmation; the coordinator asks)

    private static let trashCountScript = #"tell application "Finder" to return count of items in trash"#
    private static let emptyTrashScript = #"tell application "Finder" to empty trash"#

    static func emptyTrash() -> RioActionResult {
        var error: NSDictionary?
        if let counter = NSAppleScript(source: trashCountScript) {
            let count = counter.executeAndReturnError(&error)
            if error == nil, count.int32Value == 0 { return .done(summary: "The Trash is already empty") }
        }
        error = nil
        guard let script = NSAppleScript(source: emptyTrashScript) else { return .failed(message: "I couldn't empty the Trash") }
        script.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 {
                return .failed(message: "I need permission to control Finder. Allow it in Privacy and Security, Automation")
            }
            return .failed(message: "I couldn't empty the Trash")
        }
        return .done(summary: "Emptied the Trash")
    }

    // MARK: Undo support (builder G's journal reads this in `willExecute`)

    /// The state this action is about to change, so it can be put back with `inverseAction`. Nil for
    /// actions with nothing to restore (or when the current state can't be read).
    static func priorState(for action: RioAction) async -> RioSystemPriorState? {
        switch action {
        case .systemToggle(let setting, _):
            let wasOn: Bool?
            switch setting {
            case .wifi: wasOn = await isWiFiOn()
            case .bluetooth: wasOn = await RioBluetoothPower.isOn()
            case .darkMode: wasOn = isDarkMode()
            case .nightShift: wasOn = RioNightShift.isEnabled()
            }
            return wasOn.map { .toggle(setting, wasOn: $0) }
        case .brightness:
            return RioDisplayBrightness.currentPercent().map { .brightness(percent: $0) }
        default:
            return nil
        }
    }
}
