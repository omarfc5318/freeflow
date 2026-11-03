import Foundation

/// One process that has an audio-input client, as CoreAudio reports it.
struct AudioInputProcess: Equatable {
    let pid: Int32
    let bundleID: String?
    let isRunningInput: Bool
}

/// Where the list of audio processes comes from; CoreAudio in the app, a fake in tests.
protocol AudioInputProcessSource {
    func inputProcesses() -> [AudioInputProcess]
}

enum MicUsageDecision {
    /// Always-on voice-trigger services hold an input stream all day. They are not a call, so
    /// they must never pause conversation mode.
    private static let ignoredBundlePrefixes = [
        "com.apple.corespeech",
        "com.apple.assistant",
        "com.apple.siri",
        "com.apple.speech",
        "com.apple.voicebankingd",
    ]

    static func isOtherAppUsingMicrophone(_ processes: [AudioInputProcess], ownPID: Int32) -> Bool {
        processes.contains { process in
            guard process.isRunningInput, process.pid != ownPID else { return false }
            if let bundleID = process.bundleID?.lowercased(),
               ignoredBundlePrefixes.contains(where: { bundleID.hasPrefix($0) }) {
                return false
            }
            return true
        }
    }

    static func isOtherAppUsingMicrophone(_ source: AudioInputProcessSource, ownPID: Int32) -> Bool {
        isOtherAppUsingMicrophone(source.inputProcesses(), ownPID: ownPID)
    }
}

/// Smooths the poll results: a call is over only after a few consecutive clear polls, so a
/// momentary gap (an app restarting its stream) does not make Rio start listening mid-call.
struct MicUsageDebounce {
    static let pollsToClear = 2
    private var clearPolls = Self.pollsToClear
    private var busy = false

    /// Feed one raw poll; returns the smoothed "another app is using the mic".
    mutating func update(otherAppUsing: Bool) -> Bool {
        if otherAppUsing {
            busy = true
            clearPolls = 0
        } else if busy {
            clearPolls += 1
            if clearPolls >= Self.pollsToClear { busy = false }
        }
        return busy
    }
}
