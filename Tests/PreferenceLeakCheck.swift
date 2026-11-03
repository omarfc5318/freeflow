import Foundation

/// Scratch UserDefaults suites for tests. Every suite is named `FreeFlowTests.<label>.<uuid>`
/// and is registered here so it can be wiped (domain removed AND its plist deleted) when the
/// test is done. Without this each `make check` left dozens of plists in ~/Library/Preferences.
final class TestScratchDefaults: @unchecked Sendable {
    static let shared = TestScratchDefaults()
    static let prefix = "FreeFlowTests."

    private let lock = NSLock()
    private var suites: [String] = []
    /// Every suite ever made. cfprefsd writes a suite's plist a moment AFTER the test is done
    /// with it (even after removePersistentDomain), so the files are swept again at the end.
    private var everMade: Set<String> = []

    /// A fresh, empty suite. Returns its name too, so a test can reopen it.
    static func make(_ label: String) -> (defaults: UserDefaults, suite: String) {
        let suite = "\(prefix)\(label).\(UUID().uuidString)"
        return (shared.open(suite), suite)
    }

    /// Reopens a suite created earlier (and keeps it registered for cleanup).
    static func reopen(_ suite: String) -> UserDefaults { shared.open(suite) }

    /// Removes one suite's domain and its plist file.
    static func remove(_ suite: String) {
        shared.wipe(suite)
        shared.lock.lock()
        shared.suites.removeAll { $0 == suite }
        shared.lock.unlock()
    }

    /// Removes every suite made so far.
    static func removeAll() {
        shared.lock.lock()
        let all = shared.suites
        shared.suites = []
        shared.lock.unlock()
        for suite in all { shared.wipe(suite) }
    }

    /// Deletes the plist of every suite made so far, repeating until cfprefsd has stopped
    /// (re)writing them. Call once at the end of the run, after `removeAll()`.
    static func sweepFiles() {
        shared.lock.lock()
        let names = shared.everMade
        shared.lock.unlock()
        var quietPasses = 0
        var passes = 0
        while quietPasses < 3, passes < 40 {
            var removedAny = false
            for suite in names {
                let file = PreferenceLeakCheck.preferencesDirectory.appendingPathComponent("\(suite).plist")
                if FileManager.default.fileExists(atPath: file.path) {
                    try? FileManager.default.removeItem(at: file)
                    removedAny = true
                }
            }
            quietPasses = removedAny ? 0 : quietPasses + 1
            passes += 1
            Thread.sleep(forTimeInterval: 0.15)
        }
    }

    private func open(_ suite: String) -> UserDefaults {
        lock.lock()
        if !suites.contains(suite) { suites.append(suite) }
        everMade.insert(suite)
        lock.unlock()
        return UserDefaults(suiteName: suite)!
    }

    private func wipe(_ suite: String) {
        let defaults = UserDefaults(suiteName: suite)
        defaults?.removePersistentDomain(forName: suite)
        defaults?.synchronize()
        try? FileManager.default.removeItem(at: PreferenceLeakCheck.preferencesDirectory.appendingPathComponent("\(suite).plist"))
    }
}

/// Fails the run when a `FreeFlowTests.*.plist` created during it is still on disk.
enum PreferenceLeakCheck {
    static var preferencesDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Preferences")
    }

    /// Names of `FreeFlowTests.*.plist` files in `directory`.
    static func testPlists(in directory: URL, fileManager: FileManager = .default) -> Set<String> {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.filter { $0.hasPrefix(TestScratchDefaults.prefix) && $0.hasSuffix(".plist") })
    }

    /// Files present now that were not there before (files that pre-existed are ignored).
    static func leaked(before: Set<String>, after: Set<String>) -> [String] {
        after.subtracting(before).sorted()
    }

    /// Wipes the registered suites, gives cfprefsd a moment to settle, then returns the leak.
    static func leakedSinceStart(before: Set<String>, directory: URL = preferencesDirectory) -> [String] {
        TestScratchDefaults.removeAll()
        TestScratchDefaults.sweepFiles()
        var leaks = leaked(before: before, after: testPlists(in: directory))
        var attempts = 0
        while !leaks.isEmpty, attempts < 20 {
            Thread.sleep(forTimeInterval: 0.1)
            leaks = leaked(before: before, after: testPlists(in: directory))
            attempts += 1
        }
        return leaks
    }
}

enum PreferenceLeakCheckTests {
    static func run() {
        testLeakDetectionIgnoresPreExistingFiles()
        testScratchDefaultsAreRemovedFromDisk()
    }

    private static func testLeakDetectionIgnoresPreExistingFiles() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("leak-check-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func touch(_ name: String) { FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: Data()) }

        touch("FreeFlowTests.Old.1.plist")
        touch("com.apple.something.plist")
        let before = PreferenceLeakCheck.testPlists(in: directory)
        TestSupport.expectEqual(before, ["FreeFlowTests.Old.1.plist"])
        TestSupport.expect(PreferenceLeakCheck.leaked(before: before, after: before).isEmpty, "Pre-existing plists are not leaks")

        touch("FreeFlowTests.New.2.plist")
        touch("unrelated.plist")
        TestSupport.expectEqual(
            PreferenceLeakCheck.leaked(before: before, after: PreferenceLeakCheck.testPlists(in: directory)),
            ["FreeFlowTests.New.2.plist"]
        )
        TestSupport.expect(PreferenceLeakCheck.testPlists(in: directory.appendingPathComponent("missing")).isEmpty, "A missing directory lists nothing")
    }

    private static func testScratchDefaultsAreRemovedFromDisk() {
        let (defaults, suite) = TestScratchDefaults.make("LeakCheck")
        defaults.set("value", forKey: "key")
        defaults.synchronize()
        TestScratchDefaults.remove(suite)
        TestSupport.expect(UserDefaults(suiteName: suite)?.object(forKey: "key") == nil, "Removed suite keeps no values")
        TestScratchDefaults.remove(suite)
        let file = PreferenceLeakCheck.preferencesDirectory.appendingPathComponent("\(suite).plist")
        TestSupport.expect(!FileManager.default.fileExists(atPath: file.path), "Removed suite leaves no plist behind")
    }
}
