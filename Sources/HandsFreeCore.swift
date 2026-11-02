import Foundation

/// Hands-free dictation: ends a tap-to-toggle recording once the speaker has been quiet
/// for a while. Works on the raw level of each audio buffer, relative to a running
/// estimate of the room's noise floor, so it adapts to quiet rooms and to whisper mode.
struct SilenceAutoStop {
    /// Choices offered in Settings, in seconds; 0 means off.
    /// Measured on real dictations: natural pauses reached 2.7 s, so 2 s cut some short.
    static let delayChoices: [TimeInterval] = [0, 3, 5, 8]
    static let defaultDelay: TimeInterval = 5

    /// A buffer counts as speech when it is this far above the noise floor.
    static let speechMarginDB: Float = 12
    /// Speech must add up to this much before silence can end the recording, so a
    /// cough or a click right after tapping does not arm it.
    static let minimumSpeechSeconds: TimeInterval = 0.4
    /// Exact or near-exact zeros come from the device warming up, not from the room.
    static let digitalSilenceDB: Float = -90
    /// The first moments of real audio ramp up from far below the room's level (measured:
    /// 20–60 ms); learning the floor from them would make room noise look like speech.
    static let warmUpSeconds: TimeInterval = 0.1
    /// How fast the floor follows a room that gets slightly louder. It only rises toward
    /// sound within `floorRiseWindowDB` of it, never toward speech or the gaps between
    /// syllables, so fast continuous talking can't lift it until speech reads as silence.
    /// A room that gets much louder mid-recording is treated as speech: the recording then
    /// waits for a tap rather than stopping early.
    static let floorRiseDBPerSecond: Float = 1.5
    static let floorRiseWindowDB: Float = 10
    /// How fast the floor follows a quieter room. Limited so one unusually quiet buffer
    /// cannot drag the floor down and make ordinary room noise look like speech.
    static let floorFallDBPerSecond: Float = 20
    /// Sound must stay above the threshold this long to count as speech: room noise
    /// flickers past it for a buffer or two, while a spoken syllable lasts longer.
    static let speechBurstSeconds: TimeInterval = 0.1

    let delay: TimeInterval
    private var noiseFloorDB: Float?
    private var speechSeconds: TimeInterval = 0
    private var silentSeconds: TimeInterval = 0
    private var burstSeconds: TimeInterval = 0
    private var audibleSeconds: TimeInterval = 0

    init(delay: TimeInterval) {
        self.delay = delay
    }

    var isEnabled: Bool { delay > 0 }

    /// Seconds of the recording that sounded like speech so far.
    var heardSpeechSeconds: TimeInterval { speechSeconds }
    /// Loudest buffer so far, in dBFS.
    private(set) var peakDB: Float = -120

    /// Feeds one buffer's RMS level (0...1) and length; returns true once the recording
    /// should stop. Speech and peak level are tracked even when auto-stop is off.
    mutating func shouldStop(afterBufferWithRMS rms: Float, duration: TimeInterval) -> Bool {
        guard duration > 0 else { return false }
        let levelDB = 20 * log10f(max(rms, 1e-6))
        peakDB = max(peakDB, levelDB)
        if levelDB > Self.digitalSilenceDB {
            audibleSeconds += duration
            if audibleSeconds > Self.warmUpSeconds { updateNoiseFloor(levelDB, duration: duration) }
        }
        if let floor = noiseFloorDB, levelDB > floor + Self.speechMarginDB {
            burstSeconds += duration
        } else {
            burstSeconds = 0
        }
        if burstSeconds >= Self.speechBurstSeconds {
            speechSeconds += duration
            silentSeconds = 0
        } else {
            silentSeconds += duration
        }
        return isEnabled && speechSeconds >= Self.minimumSpeechSeconds && silentSeconds >= delay
    }

    private mutating func updateNoiseFloor(_ levelDB: Float, duration: TimeInterval) {
        guard let floor = noiseFloorDB else {
            noiseFloorDB = levelDB
            return
        }
        let seconds = Float(duration)
        if levelDB < floor {
            noiseFloorDB = max(levelDB, floor - Self.floorFallDBPerSecond * seconds)
        } else if levelDB <= floor + Self.floorRiseWindowDB {
            noiseFloorDB = min(levelDB, floor + Self.floorRiseDBPerSecond * seconds)
        }
    }
}

/// Whether a finished recording is worth sending for transcription. A tap of the shortcut
/// or a recording with nothing said is skipped, so the provider never rejects it and the
/// bear shrugs instead. Anything that sounded like speech, or got loud at all, is sent.
enum SpeechPresence {
    /// Shorter recordings are rejected by providers and hold no words.
    static let minimumRecordingSeconds: TimeInterval = 0.3
    /// Below this the microphone heard nothing louder than a quiet room.
    static let quietPeakDB: Float = -50

    static func isWorthTranscribing(recordedSeconds: TimeInterval, heardSpeechSeconds: TimeInterval, peakDB: Float) -> Bool {
        guard recordedSeconds >= minimumRecordingSeconds else { return false }
        return heardSpeechSeconds > 0 || peakDB > quietPeakDB
    }
}
