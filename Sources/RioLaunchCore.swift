import Foundation

// Pure logic for Rio's "come back after a crash" support: the bundled LaunchAgent plist, the
// crash marker and the login-item migration. No AppKit and no ServiceManagement, so all of it
// is unit-tested; AppState and AppDelegate do the real registering.

/// The LaunchAgent that relaunches Rio after a crash but not after a normal quit.
/// `KeepAlive.SuccessfulExit = false` means launchd restarts the job only when it exits
/// abnormally (crash, kill -9); an exit status of 0 (Quit) leaves it stopped.
enum RioLaunchAgentPlist {
    static let throttleInterval = 5

    static func label(bundleIdentifier: String) -> String { "\(bundleIdentifier).agent" }

    /// `SMAppService.agent(plistName:)` takes this name; the file lives in
    /// `Contents/Library/LaunchAgents/` inside the app.
    static func fileName(bundleIdentifier: String) -> String { "\(label(bundleIdentifier: bundleIdentifier)).plist" }

    /// Path of the executable relative to the app bundle (`BundleProgram`).
    static func bundleProgram(executableName: String) -> String { "Contents/MacOS/\(executableName)" }

    static func dictionary(bundleIdentifier: String, executableName: String) -> [String: Any] {
        [
            "Label": label(bundleIdentifier: bundleIdentifier),
            "BundleProgram": bundleProgram(executableName: executableName),
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": throttleInterval,
        ]
    }

    static func xmlData(bundleIdentifier: String, executableName: String) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: dictionary(bundleIdentifier: bundleIdentifier, executableName: executableName),
            format: .xml,
            options: 0
        )
    }
}

/// A file that exists exactly while Rio is running. Written at launch and removed on a clean
/// quit, so finding it at launch means the previous run did not end cleanly.
struct RioCrashMarker {
    let url: URL

    /// Marks this run as started. Returns true when a marker from an earlier run was still
    /// there (that run crashed).
    @discardableResult
    func beginRun(fileManager: FileManager = .default) -> Bool {
        let crashed = fileManager.fileExists(atPath: url.path)
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fileManager.createFile(atPath: url.path, contents: Data())
        return crashed
    }

    /// Marks a clean quit.
    func endRun(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: url)
    }
}

/// What to do about the old `SMAppService.mainApp` login item when "Launch at login" is set
/// or at launch. Pure: the caller performs the steps.
enum RioLaunchMigration {
    struct Plan: Equatable {
        var unregisterMainApp: Bool
        var registerAgent: Bool
        var unregisterAgent: Bool
    }

    /// The toggle was switched: on means the agent only (the old login item goes), off removes both.
    static func plan(wantsEnabled: Bool, mainAppEnabled: Bool, agentEnabled: Bool) -> Plan {
        if wantsEnabled {
            return Plan(unregisterMainApp: mainAppEnabled, registerAgent: !agentEnabled, unregisterAgent: false)
        }
        return Plan(unregisterMainApp: mainAppEnabled, registerAgent: false, unregisterAgent: agentEnabled)
    }

    /// At launch: someone who had the old login item on keeps "Launch at login" on, now as the
    /// agent. Nothing else changes (an enabled agent or no login item at all is left alone).
    static func launchPlan(mainAppEnabled: Bool, agentEnabled: Bool) -> Plan {
        guard mainAppEnabled else { return Plan(unregisterMainApp: false, registerAgent: false, unregisterAgent: false) }
        return plan(wantsEnabled: true, mainAppEnabled: true, agentEnabled: agentEnabled)
    }
}
