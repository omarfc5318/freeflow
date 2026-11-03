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

    /// On when the agent is registered (or the old login item still is, before migration).
    static var isEnabled: Bool {
        agent.status == .enabled || SMAppService.mainApp.status == .enabled
    }

    static var needsApproval: Bool {
        agent.status == .requiresApproval || SMAppService.mainApp.status == .requiresApproval
    }

    /// Switches the toggle: the agent replaces the old login item.
    static func set(_ enabled: Bool) throws {
        try apply(RioLaunchMigration.plan(
            wantsEnabled: enabled,
            mainAppEnabled: SMAppService.mainApp.status == .enabled,
            agentEnabled: agent.status == .enabled
        ))
    }

    /// Moves someone who had the old login item on to the agent. Never fails the launch.
    static func migrateAtLaunch() {
        let plan = RioLaunchMigration.launchPlan(
            mainAppEnabled: SMAppService.mainApp.status == .enabled,
            agentEnabled: agent.status == .enabled
        )
        try? apply(plan)
    }

    private static func apply(_ plan: RioLaunchMigration.Plan) throws {
        // The old login item goes first: it is harmless to lose and must never double up.
        if plan.unregisterMainApp { try? SMAppService.mainApp.unregister() }
        if plan.unregisterAgent { try agent.unregister() }
        if plan.registerAgent { try agent.register() }
    }
}

extension RioCrashMarker {
    /// `~/Library/Application Support/<app name>/rio-running`.
    static let standard: RioCrashMarker = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return RioCrashMarker(url: support.appendingPathComponent("\(AppName.displayName)/rio-running"))
    }()
}
