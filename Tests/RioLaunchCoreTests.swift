import Foundation

enum RioLaunchCoreTests {
    static func run() {
        testAgentPlistContent()
        testAgentPlistNaming()
        testShippedPlistMatchesBuilder()
        testCrashMarker()
        testCrashMarkerCreatesMissingDirectory()
        testMigrationPlan()
        testHandoffDecision()
        testHandoffFreshness()
    }

    private static func testAgentPlistContent() {
        let plist = RioLaunchAgentPlist.dictionary(bundleIdentifier: "com.zachlatta.freeflow", executableName: "Rio Dictate")
        TestSupport.expectEqual(plist["Label"] as? String, "com.zachlatta.freeflow.agent")
        TestSupport.expectEqual(plist["BundleProgram"] as? String, "Contents/MacOS/Rio Dictate")
        TestSupport.expectEqual(plist["RunAtLoad"] as? Bool, true)
        TestSupport.expectEqual(plist["ThrottleInterval"] as? Int, 5)
        let keepAlive = plist["KeepAlive"] as? [String: Bool]
        TestSupport.expectEqual(keepAlive, ["SuccessfulExit": false])
        TestSupport.expect(plist["ProgramArguments"] == nil && plist["Program"] == nil, "Only BundleProgram locates the executable")

        let data = try! RioLaunchAgentPlist.xmlData(bundleIdentifier: "com.zachlatta.freeflow", executableName: "Rio Dictate")
        let parsed = try! PropertyListSerialization.propertyList(from: data, format: nil) as! NSDictionary
        TestSupport.expect(parsed == (plist as NSDictionary), "The XML round-trips to the same dictionary")
    }

    private static func testAgentPlistNaming() {
        TestSupport.expectEqual(RioLaunchAgentPlist.fileName(bundleIdentifier: "com.zachlatta.freeflow"), "com.zachlatta.freeflow.agent.plist")
        TestSupport.expectEqual(RioLaunchAgentPlist.fileName(bundleIdentifier: "com.zachlatta.freeflow.dev"), "com.zachlatta.freeflow.dev.agent.plist")
        TestSupport.expectEqual(RioLaunchAgentPlist.bundleProgram(executableName: "FreeFlow Dev"), "Contents/MacOS/FreeFlow Dev")
    }

    /// The file the Makefile copies into the bundle must say what the builder says.
    private static func testShippedPlistMatchesBuilder() {
        let path = "Resources/com.zachlatta.freeflow.agent.plist"
        guard let shipped = NSDictionary(contentsOfFile: path) else {
            TestSupport.expect(false, "\(path) must exist and be a plist")
            return
        }
        let built = RioLaunchAgentPlist.dictionary(bundleIdentifier: "com.zachlatta.freeflow", executableName: "Rio Dictate") as NSDictionary
        TestSupport.expect(shipped == built, "The shipped LaunchAgent plist matches the builder")
    }

    private static func testCrashMarker() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rio-marker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = RioCrashMarker(url: directory.appendingPathComponent("running"))

        TestSupport.expect(!marker.beginRun(), "A first launch is not a recovery")
        TestSupport.expect(FileManager.default.fileExists(atPath: marker.url.path), "Launch writes the marker")
        TestSupport.expect(marker.beginRun(), "A marker left behind means the last run crashed")
        TestSupport.expect(FileManager.default.fileExists(atPath: marker.url.path), "The marker is rewritten for the new run")
        marker.endRun()
        TestSupport.expect(!FileManager.default.fileExists(atPath: marker.url.path), "A clean quit removes the marker")
        marker.endRun()
        TestSupport.expect(!marker.beginRun(), "After a clean quit the next launch is normal")
    }

    private static func testCrashMarkerCreatesMissingDirectory() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rio-marker-\(UUID().uuidString)/nested/deeper")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent().deletingLastPathComponent()) }
        let marker = RioCrashMarker(url: directory.appendingPathComponent("running"))
        _ = marker.beginRun()
        TestSupport.expect(FileManager.default.fileExists(atPath: marker.url.path), "Missing parent folders are created")
    }

    private static func testMigrationPlan() {
        typealias Plan = RioLaunchMigration.Plan
        TestSupport.expectEqual(
            RioLaunchMigration.plan(wantsEnabled: true, mainAppEnabled: true, agentEnabled: false),
            Plan(unregisterMainApp: true, registerAgent: true, unregisterAgent: false)
        )
        TestSupport.expectEqual(
            RioLaunchMigration.plan(wantsEnabled: true, mainAppEnabled: false, agentEnabled: true),
            Plan(unregisterMainApp: false, registerAgent: false, unregisterAgent: false)
        )
        TestSupport.expectEqual(
            RioLaunchMigration.plan(wantsEnabled: true, mainAppEnabled: false, agentEnabled: false),
            Plan(unregisterMainApp: false, registerAgent: true, unregisterAgent: false)
        )
        TestSupport.expectEqual(
            RioLaunchMigration.plan(wantsEnabled: false, mainAppEnabled: true, agentEnabled: true),
            Plan(unregisterMainApp: true, registerAgent: false, unregisterAgent: true)
        )
        TestSupport.expectEqual(
            RioLaunchMigration.plan(wantsEnabled: false, mainAppEnabled: false, agentEnabled: false),
            Plan(unregisterMainApp: false, registerAgent: false, unregisterAgent: false)
        )
        TestSupport.expectEqual(
            RioLaunchMigration.launchPlan(mainAppEnabled: true, agentEnabled: false),
            Plan(unregisterMainApp: true, registerAgent: true, unregisterAgent: false)
        )
        TestSupport.expectEqual(
            RioLaunchMigration.launchPlan(mainAppEnabled: false, agentEnabled: false),
            Plan(unregisterMainApp: false, registerAgent: false, unregisterAgent: false)
        )
    }

    /// Crash 2026-11-04: the copy that crashed had been opened by hand, so launchd never
    /// restarted it. A hand-opened copy now hands over to the agent's job whenever it can.
    private static func testHandoffDecision() {
        TestSupport.expect(
            RioLaunchHandoff.shouldHandOff(runningUnderAgent: false, agentEnabled: true, otherCopyRunning: false),
            "A copy opened by hand hands over to the agent so a crash is restarted"
        )
        TestSupport.expect(
            !RioLaunchHandoff.shouldHandOff(runningUnderAgent: true, agentEnabled: true, otherCopyRunning: false),
            "The agent's own job never hands over again (no relaunch loop)"
        )
        TestSupport.expect(
            !RioLaunchHandoff.shouldHandOff(runningUnderAgent: false, agentEnabled: false, otherCopyRunning: false),
            "With Launch at login off there is no agent: run as is"
        )
        TestSupport.expect(
            !RioLaunchHandoff.shouldHandOff(runningUnderAgent: false, agentEnabled: true, otherCopyRunning: true),
            "A second copy just leaves; it never kicks the agent"
        )
    }

    private static func testHandoffFreshness() {
        TestSupport.expect(RioLaunchHandoff.isFresh(handedOffAt: 100, now: 105), "A handoff a few seconds old belongs to this launch")
        TestSupport.expect(!RioLaunchHandoff.isFresh(handedOffAt: 100, now: 100 + RioLaunchHandoff.freshness + 1), "An old handoff is ignored")
        TestSupport.expect(!RioLaunchHandoff.isFresh(handedOffAt: nil, now: 100), "No handoff recorded")
        TestSupport.expect(!RioLaunchHandoff.isFresh(handedOffAt: 200, now: 100), "A handoff from the future is ignored")
    }
}
