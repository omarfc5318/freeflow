import Foundation

// Pure builders for everything the executor hands to a system tool. User text never reaches an
// executable path, a flag or AppleScript source: only clamped integers, enum cases and a
// formatted date do.

enum RioVolume {
    static let step = 10

    static func clamp(_ level: Int) -> Int { min(100, max(0, level)) }

    /// The level to set after `change`, or nil for mute/unmute (those don't change the level).
    static func level(after change: VolumeChange, from current: Int) -> Int? {
        switch change {
        case .up: return clamp(current + step)
        case .down: return clamp(current - step)
        case .set(let level): return clamp(level)
        case .mute, .unmute: return nil
        }
    }

    static let readScript = "output volume of (get volume settings)"
    static let muteScript = "set volume output muted true"
    static let unmuteScript = "set volume output muted false"

    /// AppleScript source built from an Int only.
    static func setScript(level: Int) -> String {
        "set volume output volume \(clamp(level))"
    }
}

enum RioMediaKey {
    // NX_KEYTYPE_* values from IOKit's ev_keymap.h.
    static func keyCode(for command: MediaCommand) -> Int32 {
        switch command {
        // There is no separate play or pause key: both press the toggle, and only when
        // `RioMediaPlan` says it changes something.
        case .playPause, .play, .pause: return 16
        case .next: return 17
        case .previous: return 18
        }
    }

    /// data1 of an NX_SYSDEFINED (subtype 8) event: key code, then 0xA for down or 0xB for up.
    static func eventData(key: Int32, isDown: Bool) -> Int {
        Int((key << 16) | ((isDown ? 0xA : 0xB) << 8))
    }
}

/// Whether something is playing, as far as Rio can tell without asking for a permission:
/// Spotify or Music by their own `player state`, anything else (YouTube in a browser, a
/// podcast app) by CoreAudio's per-process output flag.
enum RioPlaybackState: Equatable {
    case playing
    case notPlaying
    /// Neither app is running, or Rio may not ask them, and nothing else is known to play.
    case unknown

    /// Each running player's `player state` as text ("playing", "paused", "stopped"), or nil
    /// when it could not be read. Any player playing wins. `otherAppPlaying`: another app is
    /// sending audio out right now, so a paused Spotify or Music is not the whole story ("pause"
    /// must still press the media key, a bare "stop" must still pause it).
    static func combine(_ answers: [String?], otherAppPlaying: Bool = false) -> RioPlaybackState {
        let known = answers.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if known.contains("playing") || otherAppPlaying { return .playing }
        return known.isEmpty ? .unknown : .notPlaying
    }

    /// The state `command` acts on (finding 88). The two signals stay apart: "play" (and the undo
    /// snapshot for it) listens only to what Spotify and Music say, so a call or a YouTube tab
    /// never makes a paused Spotify "already playing". Another app's output only turns a quiet
    /// player into a pause key press for "pause" and a bare "stop"; `otherAppPlaying` already
    /// leaves out call apps and is false while another app uses the microphone (`RioOtherAudio`).
    static func forCommand(_ command: MediaCommand, answers: [String?], otherAppPlaying: Bool) -> RioPlaybackState {
        command == .pause ? combine(answers, otherAppPlaying: otherAppPlaying) : combine(answers)
    }
}

/// One process CoreAudio lists (macOS 14+), with whether it is sending audio to an output now.
struct RioAudioOutputProcess: Equatable {
    let pid: Int32
    let bundleID: String?
    let isRunningOutput: Bool
}

enum RioOtherAudio {
    /// Never count as "something else is playing": Rio himself (checked by pid), the players Rio
    /// asks directly, and system voices and sounds (Rio's speech, VoiceOver, alerts).
    private static let ignoredBundlePrefixes = [
        "com.spotify.client", "com.apple.music",
        "com.apple.speech", "com.apple.speechsynthesis", "com.apple.accessibility", "com.apple.voiceover",
        "com.apple.systemsoundserver", "com.apple.coreaudio", "com.apple.audio", "com.apple.corespeech",
    ]

    /// Call apps keep their output running for the whole call (finding 88): their sound is never
    /// "music to pause", and pressing the media key then would resume a paused Spotify out loud.
    private static let callBundlePrefixes = [
        "us.zoom.", "com.microsoft.teams", "com.apple.facetime", "com.apple.avconferenced",
        "com.hnc.discord", "com.tinyspeck.slackmacgap", "com.cisco.webex", "com.webex.", "com.skype.",
        "com.microsoft.skype", "net.whatsapp.", "com.apple.telephonyutilities",
    ]

    /// `isOtherAppUsingMicrophone`: someone is on a call (a browser Meet tab, any app): nothing
    /// else counts as playing then, so "pause" or "stop" never presses the media key into it.
    static func isOtherAppPlaying(
        _ processes: [RioAudioOutputProcess], ownPID: Int32, isOtherAppUsingMicrophone: Bool = false
    ) -> Bool {
        guard !isOtherAppUsingMicrophone else { return false }
        return processes.contains { process in
            guard process.isRunningOutput, process.pid != ownPID else { return false }
            guard let bundleID = process.bundleID?.lowercased(), !bundleID.isEmpty else { return false }
            return !(ignoredBundlePrefixes + callBundlePrefixes).contains { bundleID.hasPrefix($0) }
        }
    }
}

/// What a media command does given the playback state: press the key or not, and what Rio says.
enum RioMediaPlan {
    struct Decision: Equatable {
        let pressesKey: Bool
        let summary: String
    }

    /// Players Rio can ask, by bundle identifier. Fixed strings only.
    static let players = ["com.spotify.client", "com.apple.Music"]

    /// Fixed AppleScript per player (never user text), with a short timeout so a hung player
    /// can't stall Rio.
    static func stateScript(bundleIdentifier: String) -> String? {
        guard players.contains(bundleIdentifier) else { return nil }
        return "with timeout of 2 seconds\n tell application id \"\(bundleIdentifier)\" to return (player state as text)\nend timeout"
    }

    static func decide(_ command: MediaCommand, state: RioPlaybackState) -> Decision {
        switch command {
        case .playPause: return Decision(pressesKey: true, summary: "Toggled play and pause")
        case .next: return Decision(pressesKey: true, summary: "Skipped to the next track")
        case .previous: return Decision(pressesKey: true, summary: "Went back a track")
        case .pause:
            switch state {
            case .playing: return Decision(pressesKey: true, summary: "Paused")
            case .notPlaying: return Decision(pressesKey: false, summary: "Nothing is playing")
            case .unknown: return Decision(pressesKey: true, summary: "Pressed pause")
            }
        case .play:
            switch state {
            case .playing: return Decision(pressesKey: false, summary: "It's already playing")
            case .notPlaying: return Decision(pressesKey: true, summary: "Playing")
            case .unknown: return Decision(pressesKey: true, summary: "Pressed play")
            }
        }
    }

    /// Whether the command needs the playback state at all (so next/previous never pay for it).
    static func needsState(_ command: MediaCommand) -> Bool {
        command == .play || command == .pause
    }
}

enum RioScreenshot {
    /// `~/Desktop/Rio Screenshot 2026-11-03 at 14.05.09.png`
    static func outputPath(now: Date, desktop: URL, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let stamp = String(
            format: "%04d-%02d-%02d at %02d.%02d.%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
        return desktop.appendingPathComponent("Rio Screenshot \(stamp).png").path
    }

    /// Fixed flags only. `-x` mutes the shutter sound, `-i` is interactive, `-W` starts in window
    /// pick mode, `-o` leaves out the window shadow, `-l<id>` captures one window by id.
    static func arguments(kind: ScreenshotKind, outputPath: String, windowID: Int?) -> [String] {
        switch kind {
        case .fullScreen:
            return ["-x", outputPath]
        case .selection:
            return ["-i", "-x", outputPath]
        case .window:
            if let windowID, windowID > 0 {
                return ["-x", "-o", "-l\(windowID)", outputPath]
            }
            return ["-i", "-W", "-x", outputPath]
        }
    }
}

enum RioShortcuts {
    /// The only two Shortcut names Rio will ever run. The user creates them once in Shortcuts.
    static let focusOnName = "Rio Focus On"
    static let focusOffName = "Rio Focus Off"

    static func name(isOn: Bool) -> String { isOn ? focusOnName : focusOffName }

    static func runArguments(isOn: Bool) -> [String] { ["run", name(isOn: isOn)] }

    static let listArguments = ["list"]

    static func listContains(_ output: String, isOn: Bool) -> Bool {
        let wanted = name(isOn: isOn)
        return output.split(whereSeparator: { $0.isNewline })
            .contains { $0.trimmingCharacters(in: .whitespaces) == wanted }
    }
}
