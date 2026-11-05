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

/// How many crashes in how short a time count as a crash loop.
enum RioCrashLoopPolicy {
    /// This many crashes within `window` and Rio stops restarting himself.
    static let limit = 3
    static let window: TimeInterval = 120

    /// Drops crash times older than the window (and any from the future).
    static func recent(_ crashes: [TimeInterval], now: TimeInterval) -> [TimeInterval] {
        crashes.filter { $0 <= now && now - $0 <= window }
    }

    static func isLoop(_ crashes: [TimeInterval], now: TimeInterval) -> Bool {
        recent(crashes, now: now).count >= limit
    }
}

/// What the launch decided from the crash marker.
struct RioLaunchStart: Equatable {
    /// The previous run did not end cleanly.
    var recoveredFromCrash = false
    /// launchd restarted Rio into a crash loop: exit cleanly now, before AppState is built.
    var stopForCrashLoop = false
    /// A manual launch after Rio gave up restarting: tell the owner once.
    var showLoopNotice = false
}

/// What is on disk: whether a run is in progress, the recent crash times and whether Rio gave
/// up restarting himself. An empty file (the old marker format) means "a run is in progress".
struct RioCrashState: Codable, Equatable {
    var running = false
    var crashes: [TimeInterval] = []
    var stoppedForLoop = false
}

/// A file that exists exactly while Rio is running (or while a crash history is pending).
/// Written at launch and removed on a clean quit, so finding it at launch means the previous
/// run did not end cleanly. It also carries the crash timestamps that detect a crash loop.
struct RioCrashMarker {
    let url: URL
    /// Set on the process-wide marker so a second `beginRun()` in one process (it would see its
    /// own marker as a crash) returns the first answer.
    var memo: Memo?

    final class Memo: @unchecked Sendable {
        var start: RioLaunchStart?
        init() {}
    }

    init(url: URL, memo: Memo? = nil) {
        self.url = url
        self.memo = memo
    }

    func readState(fileManager: FileManager = .default) -> RioCrashState? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let data = fileManager.contents(atPath: url.path), !data.isEmpty,
              let state = try? JSONDecoder().decode(RioCrashState.self, from: data)
        else { return RioCrashState(running: true) }   // legacy empty marker
        return state
    }

    private func write(_ state: RioCrashState, fileManager: FileManager) {
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = (try? JSONEncoder().encode(state)) ?? Data()
        fileManager.createFile(atPath: url.path, contents: data)
    }

    /// Marks this run as started and decides what the launch should do.
    /// - `startedByLaunchd`: this process is the LaunchAgent's job (only that copy may give up).
    @discardableResult
    func begin(now: Date = Date(), startedByLaunchd: Bool, fileManager: FileManager = .default) -> RioLaunchStart {
        if let cached = memo?.start { return cached }
        let time = now.timeIntervalSince1970
        var state = readState(fileManager: fileManager) ?? RioCrashState()
        var start = RioLaunchStart()
        if state.running {
            start.recoveredFromCrash = true
            state.crashes = RioCrashLoopPolicy.recent(state.crashes + [time], now: time)
        } else {
            state.crashes = RioCrashLoopPolicy.recent(state.crashes, now: time)
        }
        if startedByLaunchd, start.recoveredFromCrash, RioCrashLoopPolicy.isLoop(state.crashes, now: time) {
            // Give up: no run marker is written, so a later manual launch is a normal start.
            state.running = false
            state.stoppedForLoop = true
            write(state, fileManager: fileManager)
            start.stopForCrashLoop = true
        } else {
            if !startedByLaunchd {
                // A person opened Rio: they get the one-time notice, and the history starts over.
                start.showLoopNotice = state.stoppedForLoop
                state.stoppedForLoop = false
                state.crashes = []
            }
            state.running = true
            write(state, fileManager: fileManager)
        }
        memo?.start = start
        return start
    }

    /// Marks a clean quit (also forgets the crash history).
    func endRun(fileManager: FileManager = .default) {
        // A give-up note must survive until the owner next opens Rio by hand.
        if let state = readState(fileManager: fileManager), state.stoppedForLoop, !state.running { return }
        try? fileManager.removeItem(at: url)
    }

    /// Compatibility wrapper: true when the previous run crashed.
    @discardableResult
    func beginRun(now: Date = Date(), startedByLaunchd: Bool = false, fileManager: FileManager = .default) -> Bool {
        begin(now: now, startedByLaunchd: startedByLaunchd, fileManager: fileManager).recoveredFromCrash
    }
}

/// What to do about the old `SMAppService.mainApp` login item when "Launch at login" is set
/// or at launch. Pure: the caller performs the steps.
enum RioLaunchMigration {
    struct Plan: Equatable {
        var unregisterMainApp: Bool
        var registerAgent: Bool
        var unregisterAgent: Bool
        /// Switching off while this process IS the agent's job: unregistering now would make
        /// launchd kill Rio, so the unregister waits until he quits.
        var deferAgentUnregister = false
    }

    /// The toggle was switched: on means the agent only (the old login item goes), off removes both.
    static func plan(wantsEnabled: Bool, mainAppEnabled: Bool, agentEnabled: Bool, runningUnderAgent: Bool = false) -> Plan {
        if wantsEnabled {
            return Plan(unregisterMainApp: mainAppEnabled, registerAgent: !agentEnabled, unregisterAgent: false)
        }
        return Plan(
            unregisterMainApp: mainAppEnabled, registerAgent: false,
            unregisterAgent: agentEnabled && !runningUnderAgent,
            deferAgentUnregister: agentEnabled && runningUnderAgent
        )
    }

    /// At launch: someone who had the old login item on keeps "Launch at login" on, now as the
    /// agent. Nothing else changes (an enabled agent or no login item at all is left alone).
    static func launchPlan(mainAppEnabled: Bool, agentEnabled: Bool) -> Plan {
        guard mainAppEnabled else { return Plan(unregisterMainApp: false, registerAgent: false, unregisterAgent: false) }
        return plan(wantsEnabled: true, mainAppEnabled: true, agentEnabled: agentEnabled)
    }
}

/// A copy of Rio opened by hand (Dock, Finder, Spotlight, `open`) is not watched by launchd, so a
/// crash would leave him gone (2026-11-04: build 123 crashed after 9.5 hours and stayed down).
/// When "Launch at login" is on, that copy starts the agent's job instead and leaves at once,
/// so every running Rio is the supervised one. Pure: RioLaunchAtLogin performs it.
enum RioLaunchHandoff {
    /// UserDefaults key holding when a hand-opened copy handed over (seconds since 1970). The
    /// agent's copy reads it so the launch still counts as the owner's (crash notice, history).
    static let defaultsKey = "rio_launch_handoff_at"
    /// A handoff older than this was not for the current launch.
    static let freshness: TimeInterval = 15
    /// How long the agent's copy waits for the hand-opened copy to leave before calling itself
    /// a duplicate.
    static let duplicateWait: TimeInterval = 3

    static func shouldHandOff(runningUnderAgent: Bool, agentEnabled: Bool, otherCopyRunning: Bool) -> Bool {
        !runningUnderAgent && agentEnabled && !otherCopyRunning
    }

    static func isFresh(handedOffAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard let handedOffAt, handedOffAt <= now else { return false }
        return now - handedOffAt <= freshness
    }
}
