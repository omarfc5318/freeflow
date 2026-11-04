import Foundation

/// The pure builders behind the executor: volume, screenshots, shortcuts and URLs.
enum RioActionArgumentsTests {
    static func run() {
        testVolume()
        testScreenshot()
        testShortcuts()
        testMediaKeys()
        testMediaPlan()
        testRecentWindowTarget()
        testURLs()
        testCatalog()
    }

    private static func testVolume() {
        TestSupport.expectEqual(RioVolume.clamp(-5), 0)
        TestSupport.expectEqual(RioVolume.clamp(250), 100)
        TestSupport.expectEqual(RioVolume.clamp(42), 42)
        TestSupport.expectEqual(RioVolume.level(after: .up, from: 50), 60)
        TestSupport.expectEqual(RioVolume.level(after: .up, from: 98), 100)
        TestSupport.expectEqual(RioVolume.level(after: .down, from: 4), 0)
        TestSupport.expectEqual(RioVolume.level(after: .set(300), from: 10), 100)
        TestSupport.expectEqual(RioVolume.level(after: .set(-9), from: 10), 0)
        TestSupport.expectEqual(RioVolume.level(after: .mute, from: 10), nil)
        TestSupport.expectEqual(RioVolume.setScript(level: 40), "set volume output volume 40")
        TestSupport.expectEqual(RioVolume.setScript(level: 9999), "set volume output volume 100")
        TestSupport.expectEqual(RioVolume.setScript(level: -3), "set volume output volume 0")
    }

    private static func testScreenshot() {
        let desktop = URL(fileURLWithPath: "/Users/test/Desktop")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_793_714_709)  // 2026-11-03 14:05:09 UTC
        let path = RioScreenshot.outputPath(now: date, desktop: desktop, calendar: calendar)
        TestSupport.expectEqual(path, "/Users/test/Desktop/Rio Screenshot 2026-11-03 at 14.05.09.png")
        TestSupport.expectEqual(RioScreenshot.arguments(kind: .fullScreen, outputPath: "/p.png", windowID: nil), ["-x", "/p.png"])
        TestSupport.expectEqual(RioScreenshot.arguments(kind: .selection, outputPath: "/p.png", windowID: nil), ["-i", "-x", "/p.png"])
        TestSupport.expectEqual(RioScreenshot.arguments(kind: .window, outputPath: "/p.png", windowID: 4821), ["-x", "-o", "-l4821", "/p.png"])
        TestSupport.expectEqual(RioScreenshot.arguments(kind: .window, outputPath: "/p.png", windowID: nil), ["-i", "-W", "-x", "/p.png"])
        TestSupport.expectEqual(RioScreenshot.arguments(kind: .window, outputPath: "/p.png", windowID: -1), ["-i", "-W", "-x", "/p.png"])
    }

    private static func testShortcuts() {
        TestSupport.expectEqual(RioShortcuts.runArguments(isOn: true), ["run", "Rio Focus On"])
        TestSupport.expectEqual(RioShortcuts.runArguments(isOn: false), ["run", "Rio Focus Off"])
        TestSupport.expect(RioShortcuts.listContains("Morning\nRio Focus On\nOther", isOn: true), "finds the shortcut")
        TestSupport.expect(!RioShortcuts.listContains("Rio Focus Off\n", isOn: true), "wrong shortcut not found")
        TestSupport.expect(!RioShortcuts.listContains("My Rio Focus On copy\n", isOn: true), "must be an exact name")
    }

    private static func testMediaKeys() {
        TestSupport.expectEqual(RioMediaKey.keyCode(for: .playPause), 16)
        TestSupport.expectEqual(RioMediaKey.keyCode(for: .next), 17)
        TestSupport.expectEqual(RioMediaKey.keyCode(for: .previous), 18)
        TestSupport.expectEqual(RioMediaKey.keyCode(for: .play), 16)
        TestSupport.expectEqual(RioMediaKey.keyCode(for: .pause), 16)
        TestSupport.expectEqual(RioMediaKey.eventData(key: 16, isDown: true), (16 << 16) | 0xA00)
        TestSupport.expectEqual(RioMediaKey.eventData(key: 16, isDown: false), (16 << 16) | 0xB00)
    }

    /// F22/K51: "pause" when nothing plays must not start music; "play" while playing must not pause.
    private static func testMediaPlan() {
        TestSupport.expectEqual(RioPlaybackState.combine([]), .unknown)
        TestSupport.expectEqual(RioPlaybackState.combine([nil]), .unknown)
        TestSupport.expectEqual(RioPlaybackState.combine(["paused", nil]), .notPlaying)
        TestSupport.expectEqual(RioPlaybackState.combine(["stopped", "Playing\n"]), .playing)
        // Finding 92: Spotify paused while YouTube plays in a browser: "pause" and a bare "stop"
        // still press the media key, and "play" doesn't toggle the browser off.
        let pausedSpotifyWithBrowser = RioPlaybackState.combine(["paused"], otherAppPlaying: true)
        TestSupport.expectEqual(pausedSpotifyWithBrowser, .playing)
        TestSupport.expectEqual(RioMediaPlan.decide(.pause, state: pausedSpotifyWithBrowser).pressesKey, true)
        TestSupport.expectEqual(RioMediaPlan.decide(.play, state: pausedSpotifyWithBrowser).pressesKey, false)
        TestSupport.expectEqual(RioPlaybackState.combine([], otherAppPlaying: true), .playing)
        // Nothing else playing: round 1's "never resume by accident" stays.
        TestSupport.expectEqual(RioPlaybackState.combine(["paused"], otherAppPlaying: false), .notPlaying)
        let browser = RioAudioOutputProcess(pid: 200, bundleID: "com.google.Chrome.helper", isRunningOutput: true)
        let idleBrowser = RioAudioOutputProcess(pid: 200, bundleID: "com.google.Chrome.helper", isRunningOutput: false)
        let spotify = RioAudioOutputProcess(pid: 300, bundleID: "com.spotify.client", isRunningOutput: true)
        let rio = RioAudioOutputProcess(pid: 42, bundleID: "com.example.rio", isRunningOutput: true)
        let voice = RioAudioOutputProcess(pid: 400, bundleID: "com.apple.speech.speechsynthesisd", isRunningOutput: true)
        let daemon = RioAudioOutputProcess(pid: 500, bundleID: nil, isRunningOutput: true)
        TestSupport.expect(RioOtherAudio.isOtherAppPlaying([browser], ownPID: 42), "a browser playing counts")
        TestSupport.expect(!RioOtherAudio.isOtherAppPlaying([idleBrowser, spotify, rio, voice, daemon], ownPID: 42),
                           "idle apps, the asked players, Rio, system voices and unnamed daemons don't")
        let pause = RioMediaPlan.decide(.pause, state: .notPlaying)
        TestSupport.expectEqual(pause, RioMediaPlan.Decision(pressesKey: false, summary: "Nothing is playing"))
        TestSupport.expectEqual(RioMediaPlan.decide(.pause, state: .playing), RioMediaPlan.Decision(pressesKey: true, summary: "Paused"))
        TestSupport.expectEqual(RioMediaPlan.decide(.play, state: .playing).pressesKey, false)
        TestSupport.expectEqual(RioMediaPlan.decide(.play, state: .notPlaying), RioMediaPlan.Decision(pressesKey: true, summary: "Playing"))
        TestSupport.expectEqual(RioMediaPlan.decide(.play, state: .unknown).pressesKey, true)
        TestSupport.expectEqual(RioMediaPlan.decide(.playPause, state: .playing).summary, "Toggled play and pause")
        TestSupport.expectEqual(RioMediaPlan.needsState(.next), false)
        TestSupport.expectEqual(RioMediaPlan.needsState(.pause), true)
        TestSupport.expectEqual(RioMediaPlan.stateScript(bundleIdentifier: "com.example.evil"), nil)
        let script = RioMediaPlan.stateScript(bundleIdentifier: "com.spotify.client") ?? ""
        TestSupport.expect(script.contains("tell application id \"com.spotify.client\"") && script.contains("with timeout"), "fixed script")
    }

    /// F29/F30: an unnamed window command right after Rio opened an app acts on that app.
    private static func testRecentWindowTarget() {
        let target = RioRecentWindowTarget()
        let start = Date(timeIntervalSince1970: 1_000_000)
        TestSupport.expect(target.current(now: start, isUsable: { _ in true }) == nil, "nothing yet")
        target.note(processIdentifier: 42, name: "TextEdit", now: start)
        TestSupport.expectEqual(target.current(now: start.addingTimeInterval(10), isUsable: { _ in true })?.name, "TextEdit")
        TestSupport.expect(target.current(now: start.addingTimeInterval(10), isUsable: { _ in false }) == nil, "quit or hidden")
        TestSupport.expect(
            target.current(now: start.addingTimeInterval(RioRecentWindowTarget.lifetime + 1), isUsable: { _ in true }) == nil, "expired"
        )
        target.clear()
        TestSupport.expect(target.current(now: start, isUsable: { _ in true }) == nil, "cleared")
    }

    private static func testURLs() {
        TestSupport.expectEqual(
            RioWebURLs.googleSearchURL(query: "a&b+c d")?.absoluteString,
            "https://www.google.com/search?q=a%26b%2Bc%20d"
        )
        TestSupport.expectEqual(RioWebURLs.googleSearchURL(query: "  ")?.absoluteString, nil)
        TestSupport.expectEqual(
            RioWebURLs.youtubeSearchURL(query: "lofi beats")?.absoluteString,
            "https://www.youtube.com/results?search_query=lofi%20beats"
        )
        TestSupport.expectEqual(RioWebURLs.domainURL(fromSpoken: "hala discover dot com")?.absoluteString, "https://haladiscover.com")
        TestSupport.expectEqual(RioWebURLs.domainURL(fromSpoken: "evil dot zzz")?.absoluteString, nil)
        TestSupport.expectEqual(RioWebURLs.domainURL(fromSpoken: "banana")?.absoluteString, nil)
        TestSupport.expectEqual(RioWebURLs.domainURL(fromSpoken: "a.com/../x; run")?.absoluteString, nil)
        TestSupport.expect(!RioWebURLs.isSafeWebURL(URL(string: "file:///etc/passwd")!), "file urls are unsafe")
        TestSupport.expect(!RioWebURLs.isSafeWebURL(URL(string: "javascript:alert(1)")!), "javascript urls are unsafe")
        TestSupport.expect(!RioWebURLs.isSafeWebURL(URL(string: "ftp://example.com")!), "ftp urls are unsafe")
        TestSupport.expect(RioWebURLs.isSafeWebURL(URL(string: "http://example.com")!), "http is allowed")
        TestSupport.expect(RioWebURLs.isSafeWebURL(URL(string: "https://example.com")!), "https is allowed")
        TestSupport.expect(RioWebURLs.knownSite(compactName: "youtube") != nil, "youtube is a known site")
    }

    /// Reads the real /Applications folders (read-only); launches nothing.
    private static func testCatalog() {
        let apps = InstalledAppCatalog.scan()
        let names = apps.map(\.name)
        TestSupport.expectEqual(names.count, Set(names).count)
        TestSupport.expect(apps.allSatisfy { $0.url.pathExtension == "app" }, "every entry is an .app bundle")
        TestSupport.expect(apps.allSatisfy { !$0.name.hasSuffix(".app") }, "names have no .app suffix")
        TestSupport.expectEqual(apps.map(\.name), InstalledAppCatalog.scan().map(\.name))
    }
}
