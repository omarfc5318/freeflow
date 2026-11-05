import AppKit
import ServiceManagement

/// "Launch at login" through a bundled LaunchAgent instead of the plain login item, so launchd
/// also relaunches Rio after a crash (but not after a normal quit). The pure parts (plist,
/// migration plan, crash marker) live in RioLaunchCore.swift and are unit-tested.
enum RioLaunchAtLogin {
    private static var bundleIdentifier: String { Bundle.main.bundleIdentifier ?? "com.zachlatta.freeflow" }

    private static var agent: SMAppService {
        .agent(plistName: RioLaunchAgentPlist.fileName(bundleIdentifier: bundleIdentifier))
    }

    // MARK: Who started this process

    /// True when launchd started this process as the agent's job.
    static var isRunningUnderAgent: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == RioLaunchAgentPlist.label(bundleIdentifier: bundleIdentifier)
    }

    private static let pendingUnregisterKey = "rio_launch_agent_unregister_pending"

    private static var isUnregisterPending: Bool {
        UserDefaults.standard.bool(forKey: pendingUnregisterKey)
    }

    /// On when the agent is registered (or the old login item still is, before migration), unless
    /// switching it off is waiting for Rio to quit.
    static var isEnabled: Bool {
        if isUnregisterPending { return false }
        return agent.status == .enabled || SMAppService.mainApp.status == .enabled
    }

    static var needsApproval: Bool {
        agent.status == .requiresApproval || SMAppService.mainApp.status == .requiresApproval
    }

    /// Shown under the toggle in Settings: relaunch after a crash only covers a copy that macOS
    /// itself started at login (the agent's job). A copy opened from the Dock or Finder is not
    /// supervised: handing it over would have to quit and reopen Rio under the user's hands.
    static let crashRelaunchNote = "While this is on, Rio comes back by himself a few seconds after a crash, however you opened him."

    // MARK: Hand-off (a copy opened by hand becomes the agent's job)

    /// Called first thing at launch, before AppState. A copy opened by hand starts the agent's
    /// job and returns true, so the caller exits and launchd's copy takes over (and is restarted
    /// after a crash). False (run as is) when this is the agent's copy, "Launch at login" is off,
    /// another copy is running, or launchd refused.
    static func handOffToAgentIfPossible(otherCopyRunning: Bool) -> Bool {
        guard RioLaunchHandoff.shouldHandOff(
            runningUnderAgent: isRunningUnderAgent,
            agentEnabled: agent.status == .enabled,
            otherCopyRunning: otherCopyRunning
        ) else { return false }
        let defaults = UserDefaults.standard
        defaults.set(Date().timeIntervalSince1970, forKey: RioLaunchHandoff.defaultsKey)
        let kick = Process()
        kick.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        kick.arguments = ["kickstart", "gui/\(getuid())/\(RioLaunchAgentPlist.label(bundleIdentifier: bundleIdentifier))"]
        kick.standardOutput = FileHandle.nullDevice
        kick.standardError = FileHandle.nullDevice
        do {
            try kick.run()
            kick.waitUntilExit()
        } catch {
            defaults.removeObject(forKey: RioLaunchHandoff.defaultsKey)
            return false
        }
        guard kick.terminationStatus == 0 else {
            defaults.removeObject(forKey: RioLaunchHandoff.defaultsKey)
            return false
        }
        return true
    }

    /// True in the agent's copy started by a hand-off just now (read once, then cleared): the
    /// launch counts as the owner's for the crash marker.
    private static let wasHandedOff: Bool = {
        guard isRunningUnderAgent else { return false }
        let defaults = UserDefaults.standard
        let at = defaults.object(forKey: RioLaunchHandoff.defaultsKey) as? TimeInterval
        defaults.removeObject(forKey: RioLaunchHandoff.defaultsKey)
        return RioLaunchHandoff.isFresh(handedOffAt: at, now: Date().timeIntervalSince1970)
    }()

    /// The agent's copy started by a hand-off: the hand-opened copy may take a moment to exit.
    /// Waits for it (briefly) before deciding this copy is the duplicate.
    static func waitForHandingOffCopy(isOtherCopyRunning: () -> Bool) -> Bool {
        guard isRunningUnderAgent else { return isOtherCopyRunning() }
        let deadline = Date().addingTimeInterval(RioLaunchHandoff.duplicateWait)
        while isOtherCopyRunning() {
            if Date() >= deadline { return true }
            usleep(100_000)
        }
        return false
    }

    // MARK: Startup (before AppState exists)

    /// Decides this launch from the crash marker. The first access runs it and never again in
    /// one process. When launchd restarted Rio into a crash loop (3 crashes in about 2 minutes)
    /// this exits cleanly right here, so launchd leaves him stopped, and the next manual launch
    /// reports it. Reference this before `AppState()` is created.
    static let startup: RioLaunchStart = {
        let start = RioCrashMarker.standard.begin(startedByLaunchd: isRunningUnderAgent && !wasHandedOff)
        if start.stopForCrashLoop { exit(0) }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            finishPendingUnregister()
        }
        return start
    }()

    // MARK: Switching

    /// Switches the toggle: the agent replaces the old login item.
    static func set(_ enabled: Bool) throws {
        let plan = RioLaunchMigration.plan(
            wantsEnabled: enabled,
            mainAppEnabled: SMAppService.mainApp.status == .enabled,
            agentEnabled: agent.status == .enabled,
            runningUnderAgent: isRunningUnderAgent
        )
        // Turning it back on cancels a switch-off that was waiting for the quit.
        if enabled { UserDefaults.standard.removeObject(forKey: pendingUnregisterKey) }
        try apply(plan)
    }

    /// Moves someone who had the old login item on to the agent, and finishes a switch-off that
    /// could not happen while the agent's job was running. Never fails the launch.
    static func migrateAtLaunch() {
        if isUnregisterPending, !isRunningUnderAgent { finishPendingUnregister() }
        let plan = RioLaunchMigration.launchPlan(
            mainAppEnabled: SMAppService.mainApp.status == .enabled,
            agentEnabled: agent.status == .enabled
        )
        try? apply(plan)
    }

    /// Runs the unregister that was deferred because Rio was the agent's own job. Called as he
    /// quits (and at the next manual launch if he never got to quit cleanly).
    static func finishPendingUnregister() {
        guard isUnregisterPending else { return }
        UserDefaults.standard.removeObject(forKey: pendingUnregisterKey)
        try? agent.unregister()
    }

    private static func apply(_ plan: RioLaunchMigration.Plan) throws {
        // The old login item goes first: it is harmless to lose and must never double up.
        if plan.unregisterMainApp { try? SMAppService.mainApp.unregister() }
        if plan.deferAgentUnregister { UserDefaults.standard.set(true, forKey: pendingUnregisterKey) }
        if plan.unregisterAgent { try agent.unregister() }
        if plan.registerAgent { try agent.register() }
    }
}

extension RioCrashMarker {
    /// `~/Library/Application Support/<app name>/rio-running`.
    static let standard: RioCrashMarker = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return RioCrashMarker(url: support.appendingPathComponent("\(AppName.displayName)/rio-running"), memo: Memo())
    }()
}
