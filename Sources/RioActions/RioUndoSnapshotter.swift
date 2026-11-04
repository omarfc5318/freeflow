import AppKit
import Foundation

/// Reads the bit of the world an action is about to change, so `RioUndoPlan` can say how to put
/// it back. Cheap and synchronous: it runs before the action, and the bear must never add
/// delay to opening an app, so app lookups only use the running-app list (no disk scan).
@MainActor
enum RioUndoSnapshotter {
    static func capture(for action: RioAction, timers: RioTimerCenter) -> (RioUndoSnapshot, RioWindowSnapshot?) {
        var snapshot = RioUndoSnapshot()
        var window: RioWindowSnapshot?
        switch action {
        case .openApp(let name), .switchToApp(let name):
            describeApp(named: name, in: &snapshot)
            snapshot.previousFrontApp = frontmostOtherApp()
        case .quitApp(let name), .hideApp(let name):
            describeApp(named: name, in: &snapshot)
        case .volume:
            snapshot.volumeLevel = MacControls.currentVolume()
            snapshot.wasMuted = isMuted()
        case .brightness:
            snapshot.brightness = RioBrightnessReader.current()
        case .window(let command):
            window = WindowController().captureSnapshot(for: command)
            snapshot.hasWindowSnapshot = window != nil
        case .media(let command) where RioMediaPlan.needsState(command):
            switch MacControls.playbackState() {
            case .playing: snapshot.wasPlaying = true
            case .notPlaying: snapshot.wasPlaying = false
            case .unknown: break
            }
        case .cancelTimer:
            // A bare "stop" or "be quiet" never cancels a running countdown, so there is nothing
            // to restart on undo (RioStopPlan).
            if RioVoiceActionHandler.stopStep(kind: RioStopRequest.current, timers: timers) == .cancelCountdown,
               let timer = timers.countdown {
                snapshot.timerRemaining = Int(timer.remaining(at: timers.now).rounded(.up))
                snapshot.timerLabel = timer.label
            }
        default:
            break
        }
        return (snapshot, window)
    }

    // MARK: Apps

    private static func runningApps() -> [InstalledApp] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let url = app.bundleURL, let name = app.localizedName else { return nil }
            return InstalledApp(name: name, bundleIdentifier: app.bundleIdentifier, url: url)
        }
    }

    /// Running apps only: if the spoken name matches none of them, it isn't running yet, and the
    /// spoken name is what undo will ask the executor to quit.
    private static func describeApp(named spoken: String, in snapshot: inout RioUndoSnapshot) {
        if let match = AppNameMatcher.bestMatch(for: spoken, in: runningApps()) {
            snapshot.wasRunning = true
            snapshot.resolvedAppName = match.name
        } else {
            snapshot.wasRunning = false
            snapshot.resolvedAppName = spoken
        }
    }

    private static func frontmostOtherApp() -> String? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return front.localizedName
    }

    // MARK: Volume

    /// Fixed AppleScript source, no user text: reads the mute flag.
    private static func isMuted() -> Bool? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: "output muted of (get volume settings)") else { return nil }
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return result.booleanValue
    }
}

/// Reads the built-in display's brightness (0...100) through the private DisplayServices
/// symbol, loaded at run time. Returns nil on any failure, so undo simply isn't offered.
enum RioBrightnessReader {
    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32

    static func current() -> Int? {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY), let symbol = dlsym(handle, "DisplayServicesGetBrightness") else {
            return nil
        }
        let read = unsafeBitCast(symbol, to: GetBrightness.self)
        var value: Float = 0
        guard read(CGMainDisplayID(), &value) == 0, value >= 0, value <= 1 else { return nil }
        return Int((value * 100).rounded())
    }
}
