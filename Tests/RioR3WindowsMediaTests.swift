import CoreGraphics
import Foundation

/// Round 3, windows / media / UI fixes. Synthetic apps, sites and geometry only: nothing here
/// presses a key, opens a window, plays audio or reads a real field.
enum RioR3WindowsMediaTests {
    private static let apps: [InstalledApp] = [
        "Google Chrome", "Safari", "Notes", "Warp", "Finder", "zoom.us", "Messages",
    ].map { InstalledApp(name: $0, bundleIdentifier: "test.\(RioText.compact($0))", url: URL(fileURLWithPath: "/Applications/\($0).app")) }
    private static let parser = RioActionParser(installedApps: apps, isRecordingMacro: false)
    private static let gc = "Google Chrome"

    private static func o(_ n: String) -> RioAction { .openApp(name: n) }
    private static func u(_ s: String) -> RioAction { .openURL(URL(string: s)!) }
    private static func w(_ app: String?, _ p: WindowPlacement) -> RioAction { .window(WindowCommand(appName: app, placement: p)) }

    static func run() {
        testCallsNeverResumePausedSpotify()
        testDocsSites()
        testNamedBrowser()
        testBrowserChoice()
        testSideBySideWithOpen()
        testOpenInsideLayoutChain()
        testHelpPanelPlacement()
        testReopenBlankTab()
        testReturnKeyNeverSettlesHalfTypedValue()
        testFuzzySites()
        testScreenFailureHistory()
        testHeldSignFromCancelledDictation()
    }

    private static func expectParse(_ text: String, _ expected: [RioAction], confident: Bool? = nil, line: UInt = #line) {
        let analysis = parser.analyze(text)
        TestSupport.expectEqual(analysis.parse, .actions(expected), line: line)
        if let confident { TestSupport.expect(analysis.isConfident == confident, "\"\(text)\" confident should be \(confident)", line: line) }
    }

    private static func expectResolver(_ text: String, line: UInt = #line) {
        let analysis = parser.analyze(text)
        if case .actions(let actions) = analysis.parse, analysis.isConfident {
            TestSupport.expect(false, "\"\(text)\" must reach the resolver, got \(actions)", line: line)
        }
        if case .actions(let actions) = analysis.parse {
            for case .openFile(let query) in actions {
                TestSupport.expect(false, "\"\(text)\" must not search files for \"\(query)\"", line: line)
            }
        }
    }

    // MARK: 88

    /// Finding 88: a call (or a YouTube tab) never makes "pause"/"stop" resume a paused Spotify,
    /// and never makes "play" refuse.
    private static func testCallsNeverResumePausedSpotify() {
        // Scenario A: Spotify paused, on a Zoom call. The call's output doesn't count.
        let zoom = RioAudioOutputProcess(pid: 600, bundleID: "us.zoom.xos", isRunningOutput: true)
        let teams = RioAudioOutputProcess(pid: 601, bundleID: "com.microsoft.teams2", isRunningOutput: true)
        let facetime = RioAudioOutputProcess(pid: 602, bundleID: "com.apple.FaceTime", isRunningOutput: true)
        let discord = RioAudioOutputProcess(pid: 603, bundleID: "com.hnc.Discord", isRunningOutput: true)
        TestSupport.expect(!RioOtherAudio.isOtherAppPlaying([zoom, teams, facetime, discord], ownPID: 42), "call apps are not music")
        let onCall = RioOtherAudio.isOtherAppPlaying([zoom], ownPID: 42)
        let pauseOnCall = RioPlaybackState.forCommand(.pause, answers: ["paused"], otherAppPlaying: onCall)
        TestSupport.expectEqual(RioMediaPlan.decide(.pause, state: pauseOnCall), RioMediaPlan.Decision(pressesKey: false, summary: "Nothing is playing"))
        // A browser call (Meet): the tab outputs, but someone is on the microphone.
        let browser = RioAudioOutputProcess(pid: 200, bundleID: "com.google.Chrome.helper", isRunningOutput: true)
        TestSupport.expect(!RioOtherAudio.isOtherAppPlaying([browser], ownPID: 42, isOtherAppUsingMicrophone: true),
                           "nothing else counts while another app uses the microphone")
        TestSupport.expect(RioOtherAudio.isOtherAppPlaying([browser], ownPID: 42, isOtherAppUsingMicrophone: false),
                           "a playing browser still counts with the microphone free")
        // Finding 92 stays: Spotify paused, YouTube playing, no call: "pause" still presses the key.
        let pauseYouTube = RioPlaybackState.forCommand(.pause, answers: ["paused"], otherAppPlaying: true)
        TestSupport.expectEqual(RioMediaPlan.decide(.pause, state: pauseYouTube).pressesKey, true)
        // Scenario B: Spotify paused while something else outputs: "play" plays (and undo knows it wasn't).
        let play = RioPlaybackState.forCommand(.play, answers: ["paused"], otherAppPlaying: true)
        TestSupport.expectEqual(play, .notPlaying)
        TestSupport.expectEqual(RioMediaPlan.decide(.play, state: play), RioMediaPlan.Decision(pressesKey: true, summary: "Playing"))
        TestSupport.expectEqual(RioPlaybackState.forCommand(.play, answers: ["playing"], otherAppPlaying: false), .playing)
        TestSupport.expectEqual(RioPlaybackState.forCommand(.play, answers: [], otherAppPlaying: true), .unknown)
        // No player running, a browser playing: "pause" presses the key.
        TestSupport.expectEqual(RioPlaybackState.forCommand(.pause, answers: [], otherAppPlaying: true), .playing)
    }

    // MARK: 25

    private static func testDocsSites() {
        for text in ["open the next js docs", "open the react docs", "open the stripe docs", "open the react documentation"] {
            expectResolver(text)
        }
        // Real documents keep working.
        expectParse("open my MAT 108 notes", [.openFile(query: "MAT 108 notes")])
        expectParse("open the homework docs", [.openFile(query: "homework docs")])
        expectParse("open the doc about taxes", [.openFile(query: "doc about taxes")])
        expectParse("open google docs", [u("https://docs.google.com")])
    }

    // MARK: 27

    private static func testNamedBrowser() {
        expectParse("open localhost 3000 in safari", [o("Safari"), u("http://localhost:3000")])
        expectParse("open github in safari", [o("Safari"), u("https://github.com")])
        expectParse("open youtube in chrome", [o(gc), u("https://www.youtube.com")])
        expectParse("open github.com in google chrome", [o(gc), u("https://github.com")])
        // Not installed: the default browser, as before.
        expectParse("open github in firefox", [u("https://github.com")])
        // An app stays an app.
        expectParse("open notes in safari", [o("Notes")])
        expectParse("open github", [u("https://github.com")])
    }

    private static func testBrowserChoice() {
        let safari = URL(fileURLWithPath: "/Applications/Safari.app")
        let chrome = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        let notes = URL(fileURLWithPath: "/System/Applications/Notes.app")
        let browsers: Set<URL> = [safari, chrome]
        TestSupport.expectEqual(RioBrowserChoice.target(recentlyOpened: safari, openedSecondsAgo: 1, frontmost: notes, browsers: browsers), safari)
        TestSupport.expectEqual(RioBrowserChoice.target(recentlyOpened: safari, openedSecondsAgo: 60, frontmost: chrome, browsers: browsers), chrome)
        TestSupport.expectEqual(RioBrowserChoice.target(recentlyOpened: notes, openedSecondsAgo: 1, frontmost: safari, browsers: browsers), safari)
        TestSupport.expect(RioBrowserChoice.target(recentlyOpened: notes, openedSecondsAgo: 1, frontmost: notes, browsers: browsers) == nil,
                           "no browser involved: the default browser")
        TestSupport.expect(RioBrowserChoice.target(recentlyOpened: nil, openedSecondsAgo: nil, frontmost: nil, browsers: browsers) == nil, "nothing known")
    }

    // MARK: 9

    private static func testSideBySideWithOpen() {
        expectResolver("open the homework and the notes side by side")
        let unknown = parser.analyze("open the homework and the notes side by side")
        if case .unknown = unknown.parse {} else { TestSupport.expect(false, "unplaceable layout goes to the resolver whole, got \(unknown.parse)") }
        expectParse("open chrome and safari side by side", [o(gc), o("Safari"), w(gc, .leftHalf), w("Safari", .rightHalf)], confident: true)
        expectParse("open Chrome and Safari in split screen", [o(gc), o("Safari"), w(gc, .leftHalf), w("Safari", .rightHalf)])
        expectParse("put Chrome and Safari side by side", [w(gc, .leftHalf), w("Safari", .rightHalf)])
        expectParse("open Chrome and Safari and put them side by side", [o(gc), o("Safari"), w(gc, .leftHalf), w("Safari", .rightHalf)])
        // Not a layout request: untouched.
        TestSupport.expect(parser.parse("type we sat side by side") != .unknown("type we sat side by side"), "typing keeps its words")
    }

    // MARK: 68

    private static func testOpenInsideLayoutChain() {
        expectParse(
            "Rio open safari and put it on the left and open notes on the right",
            [o("Safari"), w("Safari", .leftHalf), o("Notes"), w("Notes", .rightHalf)], confident: true
        )
        expectParse("open notes on the right", [o("Notes"), w("Notes", .rightHalf)], confident: true)
        expectParse("put chrome on the left and launch warp on the right", [w(gc, .leftHalf), o("Warp"), w("Warp", .rightHalf)])
        expectParse("open safari and put it on the left", [o("Safari"), w("Safari", .leftHalf)])
    }

    // MARK: 75

    private static func testHelpPanelPlacement() {
        // The external display from the report, in Cocoa coordinates: 1920 x 1080, menu bar 25.
        let visible = CGRect(x: 1470, y: 0, width: 1920, height: 1055)
        let frame = RioPanelPlacement.frame(size: CGSize(width: 720, height: 756), visible: visible, leftInset: 100, margin: 16)
        TestSupport.expect(visible.contains(frame), "help panel inside the screen: \(frame)")
        TestSupport.expectEqual(frame.minX, 1570)
        TestSupport.expectEqual(frame.minY, 16)
        // A first, too-tall measurement can never push it off the top.
        let tall = RioPanelPlacement.frame(size: CGSize(width: 720, height: 3000), visible: visible, leftInset: 100, margin: 16)
        TestSupport.expect(visible.contains(tall), "a too-tall panel is cut to fit: \(tall)")
        // A panel that grew with its top edge pinned 358 pt above the screen is pulled back in.
        let offTop = CGRect(x: 1568, y: 682, width: 720, height: 756)
        let clamped = RioPanelPlacement.clamped(offTop, to: visible, margin: 16)
        TestSupport.expect(visible.contains(clamped), "clamped inside: \(clamped)")
        TestSupport.expectEqual(clamped.size, offTop.size)
        TestSupport.expectEqual(RioPanelPlacement.clamped(frame, to: visible, margin: 16), frame)
        // Narrow screen: never off the left or right edge.
        let narrow = CGRect(x: 0, y: 0, width: 600, height: 800)
        TestSupport.expect(narrow.contains(RioPanelPlacement.frame(size: CGSize(width: 720, height: 500), visible: narrow, leftInset: 100, margin: 16)),
                           "narrow screen")
    }

    // MARK: 77

    private static func testReopenBlankTab() {
        for title in ["New Tab", "New Tab - Google Chrome", "new tab - Google Chrome - Work", "Start Page", "Untitled", "Favorites"] {
            TestSupport.expect(RioBrowserKeys.isBlankTabTitle(title), "blank: \(title)")
        }
        for title in ["Example Domain", "YouTube", nil, "", "New Tabs for kids - Google Search"] as [String?] {
            TestSupport.expect(!RioBrowserKeys.isBlankTabTitle(title), "not blank: \(title ?? "nil")")
        }
        let blank = RioClosedTabNote(appID: "com.google.Chrome", wasBlank: true, at: 100)
        TestSupport.expectEqual(RioBrowserKeys.reopenPlan(lastClosed: blank, appID: "com.google.Chrome", now: 105), .openBlank)
        TestSupport.expectEqual(RioBrowserKeys.reopenPlan(lastClosed: blank, appID: "com.apple.Safari", now: 105), .reopen)
        TestSupport.expectEqual(RioBrowserKeys.reopenPlan(lastClosed: blank, appID: "com.google.Chrome", now: 400), .reopen)
        let page = RioClosedTabNote(appID: "com.google.Chrome", wasBlank: false, at: 100)
        TestSupport.expectEqual(RioBrowserKeys.reopenPlan(lastClosed: page, appID: "com.google.Chrome", now: 105), .reopen)
        TestSupport.expectEqual(RioBrowserKeys.reopenPlan(lastClosed: nil, appID: "com.google.Chrome", now: 105), .reopen)
        TestSupport.expectEqual(RioBrowserKeys.reopenSummary(windowsBefore: 2, windowsAfter: 3), RioBrowserKeys.reopenedWindowSummary)
        TestSupport.expectEqual(RioBrowserKeys.reopenSummary(windowsBefore: 2, windowsAfter: 2), "Reopened the tab")
        TestSupport.expectEqual(RioBrowserKeys.reopenSummary(windowsBefore: nil, windowsAfter: 3), "Reopened the tab")
    }

    // MARK: 90

    private static func testReturnKeyNeverSettlesHalfTypedValue() {
        // Slow field, the last poll caught a keystroke ("Gro"): the settled state is left alone.
        TestSupport.expect(!CorrectionReturnKeyPolicy.settlesOnReturn(isLiveRead: false, isPendingSettled: false, pendingSeenUnchanged: false),
                           "a stale, still-changing value is never settled")
        TestSupport.expect(CorrectionReturnKeyPolicy.settlesOnReturn(isLiveRead: false, isPendingSettled: false, pendingSeenUnchanged: true),
                           "a value one poll saw unchanged may settle")
        TestSupport.expect(CorrectionReturnKeyPolicy.settlesOnReturn(isLiveRead: false, isPendingSettled: true, pendingSeenUnchanged: false),
                           "an already settled value may settle")
        TestSupport.expect(CorrectionReturnKeyPolicy.settlesOnReturn(isLiveRead: true, isPendingSettled: false, pendingSeenUnchanged: false),
                           "a live read is the field as sent")
    }

    // MARK: 15

    private static func testFuzzySites() {
        expectParse("open spotfy", [u("https://open.spotify.com")], confident: false)
        expectParse("open pia za", [u("https://piazza.com")], confident: false)
        expectParse("open canvass", [u("https://canvas.ucdavis.edu")], confident: false)
        // Exact names and installed apps are unchanged.
        expectParse("open canva", [u("https://www.canva.com")], confident: true)
        expectParse("open crome", [o(gc)])
        TestSupport.expect(RioWebURLs.fuzzySite(compactName: "canvas") == nil, "canvas is never Canva")
        TestSupport.expect(RioWebURLs.fuzzySite(compactName: "github") == nil, "an exact name is not fuzzy")
        TestSupport.expect(RioWebURLs.fuzzySite(compactName: "maps") == nil, "short words never fuzzy-match")
        TestSupport.expectEqual(RioWebURLs.fuzzySite(compactName: "gradscope"), URL(string: "https://www.gradescope.com"))
    }

    // MARK: 78

    private static func testScreenFailureHistory() {
        let permission = RioHistoryPolicy.entry(
            transcript: "what's on my screen", actions: [.describeScreen(question: nil)],
            outcomeText: RioVisionMessages.needsScreenRecording, didSucceed: false
        )
        TestSupport.expectEqual(permission.outcome, "I can't see your screen yet: turn on Screen Recording for Rio in System Settings")
        TestSupport.expect(!permission.outcome.hasPrefix("Looked at your screen"), "a failure never reads like success")
        let offline = RioHistoryPolicy.entry(
            transcript: "what's on my screen", actions: [.describeScreen(question: nil)],
            outcomeText: RioVisionMessages.offline, didSucceed: false
        )
        TestSupport.expectEqual(offline.outcome, "Couldn't look at your screen: offline")
        let worked = RioHistoryPolicy.entry(
            transcript: "what's on my screen", actions: [.describeScreen(question: nil)],
            outcomeText: "A spreadsheet", didSucceed: true
        )
        TestSupport.expectEqual(worked.outcome, "Looked at your screen")
    }

    // MARK: 93

    private static func testHeldSignFromCancelledDictation() {
        // Dictation A ends without a paste; B starts before A's drop timer and pastes later.
        var moment = HeldLearnMoment()
        moment.hold(.learned("Hala"), now: 100)
        moment.sessionStarted(now: 100.01)
        moment.sessionEnded(now: 101)
        moment.sessionStarted(now: 101.5)
        moment.sessionEnded(now: 106)
        TestSupport.expect(moment.take(now: 106) == nil, "A's sign never shows after B")
        // B's own sign, held while B starts, still shows.
        var own = HeldLearnMoment()
        own.hold(.learned("Hala"), now: 100)
        own.sessionStarted(now: 100.01)
        own.sessionEnded(now: 101)
        own.hold(.learned("Groq"), now: 101.4)
        own.sessionStarted(now: 101.5)
        own.sessionEnded(now: 106)
        TestSupport.expectEqual(own.take(now: 106), .learned("Groq"))
    }
}
