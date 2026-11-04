import AppKit
import CoreGraphics
import CoreServices
import Foundation

/// Thin wrappers over the system calls Rio Actions needs. Nothing here takes free-form user
/// text: AppleScript source is built only from `RioVolume` (an Int clamped to 0...100) or is a
/// fixed string, and the only executables ever run are the two in `FixedTool`, with arguments
/// from `RioScreenshot` and `RioShortcuts`.
@MainActor
enum MacControls {
    // MARK: Volume (in-process AppleScript, Standard Additions: no Automation prompt)

    static func currentVolume() -> Int? {
        guard let descriptor = runScript(RioVolume.readScript) else { return nil }
        return RioVolume.clamp(Int(descriptor.int32Value))
    }

    @discardableResult
    static func setVolume(_ level: Int) -> Bool {
        runScript(RioVolume.setScript(level: level)) != nil
    }

    @discardableResult
    static func setMuted(_ muted: Bool) -> Bool {
        runScript(muted ? RioVolume.muteScript : RioVolume.unmuteScript) != nil
    }

    /// Only ever called with the fixed strings, the Int-built script from `RioVolume` and the
    /// fixed player scripts from `RioMediaPlan`.
    private static func runScript(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        return error == nil ? result : nil
    }

    // MARK: Media keys and lock screen (synthetic HID events, need Accessibility)

    static func pressMediaKey(_ command: MediaCommand) {
        let key = RioMediaKey.keyCode(for: command)
        for isDown in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: isDown ? 0xA00 : 0xB00)
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, subtype: 8,
                data1: RioMediaKey.eventData(key: key, isDown: isDown), data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Ctrl+Cmd+Q, the system "Lock Screen" shortcut.
    static func lockScreen() {
        let qKey: CGKeyCode = 12
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: qKey, keyDown: isDown)
            event?.flags = [.maskCommand, .maskControl]
            event?.post(tap: .cghidEventTap)
        }
    }

    // MARK: Playback state (Spotify and Music only, never prompting)

    /// Asks only players that are running and that Rio is already allowed to automate: an
    /// Automation permission prompt is never raised from here. The scripts are fixed strings.
    static func playbackState() -> RioPlaybackState {
        var answers: [String?] = []
        for bundleIdentifier in RioMediaPlan.players {
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty,
                  mayAutomate(bundleIdentifier),
                  let source = RioMediaPlan.stateScript(bundleIdentifier: bundleIdentifier) else { continue }
            answers.append(runScript(source)?.stringValue)
        }
        return RioPlaybackState.combine(answers)
    }

    /// True only when macOS already allows Rio to send Apple Events to the app. Asks nobody.
    private static func mayAutomate(_ bundleIdentifier: String) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        guard let desc = target.aeDesc else { return false }
        return AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false) == noErr
    }

    // MARK: Screenshots and Shortcuts (fixed executables, fixed arguments)

    enum FixedTool {
        case screencapture
        case shortcuts

        var path: String {
            switch self {
            case .screencapture: return "/usr/sbin/screencapture"
            case .shortcuts: return "/usr/bin/shortcuts"
            }
        }
    }

    struct ToolResult: Sendable {
        let status: Int32
        let output: String
    }

    /// Runs one of the two fixed tools off the main thread. Nil if it could not be started.
    nonisolated static func run(_ tool: FixedTool, arguments: [String]) async -> ToolResult? {
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<ToolResult?, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool.path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: ToolResult(
                    status: finished.terminationStatus,
                    output: String(decoding: data, as: UTF8.self)
                ))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    /// The CGWindowID of the frontmost app's front window, for `screencapture -l`.
    static func frontmostWindowID() -> Int? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for window in list {
            guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let number = window[kCGWindowNumber as String] as? Int else { continue }
            return number
        }
        return nil
    }

    static var desktopURL: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }
}
