import Foundation

// Pure builders for everything the executor hands to a system tool. User text never reaches an
// executable path, a flag or AppleScript source: only clamped integers, enum cases and a
// formatted date do.

enum RioVolume {
    static let step = 10

    static func clamp(_ level: Int) -> Int { min(100, max(0, level)) }

    /// The level to set after `change`, or nil for mute/unmute (those don't change the level).
    static func level(after change: VolumeChange, from current: Int) -> Int? {
        switch change {
        case .up: return clamp(current + step)
        case .down: return clamp(current - step)
        case .set(let level): return clamp(level)
        case .mute, .unmute: return nil
        }
    }

    static let readScript = "output volume of (get volume settings)"
    static let muteScript = "set volume output muted true"
    static let unmuteScript = "set volume output muted false"

    /// AppleScript source built from an Int only.
    static func setScript(level: Int) -> String {
        "set volume output volume \(clamp(level))"
    }
}

enum RioMediaKey {
    // NX_KEYTYPE_* values from IOKit's ev_keymap.h.
    static func keyCode(for command: MediaCommand) -> Int32 {
        switch command {
        case .playPause: return 16
        case .next: return 17
        case .previous: return 18
        }
    }

    /// data1 of an NX_SYSDEFINED (subtype 8) event: key code, then 0xA for down or 0xB for up.
    static func eventData(key: Int32, isDown: Bool) -> Int {
        Int((key << 16) | ((isDown ? 0xA : 0xB) << 8))
    }
}

enum RioScreenshot {
    /// `~/Desktop/Rio Screenshot 2026-11-03 at 14.05.09.png`
    static func outputPath(now: Date, desktop: URL, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let stamp = String(
            format: "%04d-%02d-%02d at %02d.%02d.%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
        return desktop.appendingPathComponent("Rio Screenshot \(stamp).png").path
    }

    /// Fixed flags only. `-x` mutes the shutter sound, `-i` is interactive, `-W` starts in window
    /// pick mode, `-o` leaves out the window shadow, `-l<id>` captures one window by id.
    static func arguments(kind: ScreenshotKind, outputPath: String, windowID: Int?) -> [String] {
        switch kind {
        case .fullScreen:
            return ["-x", outputPath]
        case .selection:
            return ["-i", "-x", outputPath]
        case .window:
            if let windowID, windowID > 0 {
                return ["-x", "-o", "-l\(windowID)", outputPath]
            }
            return ["-i", "-W", "-x", outputPath]
        }
    }
}

enum RioShortcuts {
    /// The only two Shortcut names Rio will ever run. The user creates them once in Shortcuts.
    static let focusOnName = "Rio Focus On"
    static let focusOffName = "Rio Focus Off"

    static func name(isOn: Bool) -> String { isOn ? focusOnName : focusOffName }

    static func runArguments(isOn: Bool) -> [String] { ["run", name(isOn: isOn)] }

    static let listArguments = ["list"]

    static func listContains(_ output: String, isOn: Bool) -> Bool {
        let wanted = name(isOn: isOn)
        return output.split(whereSeparator: { $0.isNewline })
            .contains { $0.trimmingCharacters(in: .whitespaces) == wanted }
    }
}
