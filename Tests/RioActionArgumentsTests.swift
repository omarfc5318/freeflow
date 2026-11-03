import Foundation

/// The pure builders behind the executor: volume, screenshots, shortcuts and URLs.
enum RioActionArgumentsTests {
    static func run() {
        testVolume()
        testScreenshot()
        testShortcuts()
        testMediaKeys()
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
        TestSupport.expectEqual(RioMediaKey.eventData(key: 16, isDown: true), (16 << 16) | 0xA00)
        TestSupport.expectEqual(RioMediaKey.eventData(key: 16, isDown: false), (16 << 16) | 0xB00)
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
