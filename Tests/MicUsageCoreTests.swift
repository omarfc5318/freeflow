import Foundation

enum MicUsageCoreTests {
    private struct FakeSource: AudioInputProcessSource {
        var processes: [AudioInputProcess]
        func inputProcesses() -> [AudioInputProcess] { processes }
    }

    private static func process(_ pid: Int32, _ bundle: String?, running: Bool) -> AudioInputProcess {
        AudioInputProcess(pid: pid, bundleID: bundle, isRunningInput: running)
    }

    static func run() {
        testNoProcesses()
        testOtherAppRecording()
        testOtherAppIdle()
        testOwnProcessIgnored()
        testOnlyOwnProcessRecording()
        testSystemListenersIgnored()
        testRealCallAmongSystemListeners()
        testUnavailableSourceMeansNotInUse()
        testMonitorUsesSource()
    }

    private static func testNoProcesses() {
        TestSupport.expect(!MicUsageDecision.isOtherAppUsingMicrophone([], ownPID: 100), "nothing running")
    }

    private static func testOtherAppRecording() {
        let list = [process(200, "us.zoom.xos", running: true)]
        TestSupport.expect(MicUsageDecision.isOtherAppUsingMicrophone(list, ownPID: 100), "Zoom call")
    }

    private static func testOtherAppIdle() {
        let list = [process(200, "us.zoom.xos", running: false)]
        TestSupport.expect(!MicUsageDecision.isOtherAppUsingMicrophone(list, ownPID: 100), "Zoom open, not capturing")
    }

    private static func testOwnProcessIgnored() {
        let list = [process(100, "com.example.rio", running: true), process(200, "com.apple.Safari", running: false)]
        TestSupport.expect(!MicUsageDecision.isOtherAppUsingMicrophone(list, ownPID: 100), "Rio's own mic")
    }

    private static func testOnlyOwnProcessRecording() {
        let list = [process(100, nil, running: true)]
        TestSupport.expect(!MicUsageDecision.isOtherAppUsingMicrophone(list, ownPID: 100), "own pid with no bundle")
    }

    private static func testSystemListenersIgnored() {
        // Always-on voice-trigger daemons hold an input stream all day; they are not a call.
        let list = [
            process(300, "com.apple.corespeechd", running: true),
            process(301, "com.apple.assistant_service", running: true),
            process(302, "com.apple.siri.something", running: true),
        ]
        TestSupport.expect(!MicUsageDecision.isOtherAppUsingMicrophone(list, ownPID: 100), "system listeners")
    }

    private static func testRealCallAmongSystemListeners() {
        let list = [
            process(300, "com.apple.corespeechd", running: true),
            process(400, "com.apple.FaceTime", running: true),
        ]
        TestSupport.expect(MicUsageDecision.isOtherAppUsingMicrophone(list, ownPID: 100), "FaceTime is a call")
    }

    private static func testUnavailableSourceMeansNotInUse() {
        // Older macOS: the source returns no processes, so nothing pauses.
        TestSupport.expect(!MicUsageDecision.isOtherAppUsingMicrophone(FakeSource(processes: []), ownPID: 100), "old macOS")
    }

    private static func testMonitorUsesSource() {
        let source = FakeSource(processes: [process(200, "com.microsoft.teams2", running: true)])
        TestSupport.expect(MicUsageDecision.isOtherAppUsingMicrophone(source, ownPID: 100), "Teams call via a source")
    }
}
