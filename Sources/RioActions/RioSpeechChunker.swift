import Foundation

/// One stretch of speech ready to send to Whisper: PCM16 mono at `RioSpeechChunker.sampleRate`.
struct RioSpeechChunk: Equatable {
    let pcm16: Data
    /// Length including a little padding either side.
    let seconds: Double
    /// Length of the parts that were actually speech.
    let voicedSeconds: Double
}

/// Cuts a live PCM16 stream into utterances on pauses (a simple energy VAD). Pure value type:
/// feed it audio of any slice size, collect finished chunks, `flush()` at the end.
///
/// Rules: a chunk starts at the first loud frame (with 0.2 s before it), ends after a 0.6 s
/// pause (1.2 s if the speech so far is under 0.6 s, so a one-word reply isn't cut early), and is
/// never longer than 6 s (a longer run is cut at its quietest moment). Under 0.3 s of speech
/// (a cough, a click) is dropped. Silence is never produced, because Whisper invents text for it.
struct RioSpeechChunker {
    static let sampleRate = 16_000
    static let frameSamples = 320
    static let frameSeconds = Double(frameSamples) / Double(sampleRate)
    /// RMS (0...1) at or above which a frame counts as speech (about -36 dBFS).
    static let speechRMS: Float = 0.015
    static let pauseSeconds = 0.6
    static let shortPauseSeconds = 1.2
    static let shortUtteranceSeconds = 0.6
    static let minVoicedSeconds = 0.3
    static let maxSeconds = 6.0
    static let paddingSeconds = 0.2
    /// How far back from the 6 s limit a forced cut may look for the quietest frame.
    static let cutSearchSeconds = 1.0

    private struct Frame {
        let data: Data
        let isVoiced: Bool
        let rms: Float
    }

    private var leftover = Data()
    private var preRoll: [Frame] = []
    private var frames: [Frame] = []
    private var silentRun = 0
    private var isActive = false

    private static var paddingFrames: Int { Int((paddingSeconds / frameSeconds).rounded()) }

    init() {}

    mutating func feed(_ pcm16: Data) -> [RioSpeechChunk] {
        leftover.append(pcm16)
        let frameBytes = Self.frameSamples * 2
        var out: [RioSpeechChunk] = []
        var offset = leftover.startIndex
        while leftover.endIndex - offset >= frameBytes {
            let slice = Data(leftover[offset..<(offset + frameBytes)])
            offset += frameBytes
            if let chunk = consume(Frame(data: slice, isVoiced: false, rms: Self.rms(of: slice))) { out.append(chunk) }
        }
        leftover = Data(leftover[offset...])
        return out
    }

    /// The speech still being collected, if there is enough of it. Call when the stream ends.
    mutating func flush() -> RioSpeechChunk? {
        let chunk = isActive ? finish() : nil
        reset()
        leftover = Data()
        return chunk
    }

    // MARK: Frames

    private mutating func consume(_ raw: Frame) -> RioSpeechChunk? {
        let frame = Frame(data: raw.data, isVoiced: raw.rms >= Self.speechRMS, rms: raw.rms)
        guard isActive else {
            if frame.isVoiced {
                isActive = true
                frames = preRoll + [frame]
                preRoll = []
                silentRun = 0
            } else {
                preRoll.append(frame)
                if preRoll.count > Self.paddingFrames { preRoll.removeFirst() }
            }
            return nil
        }
        frames.append(frame)
        silentRun = frame.isVoiced ? 0 : silentRun + 1

        let silentSeconds = Double(silentRun) * Self.frameSeconds
        let pause = spokenSeconds < Self.shortUtteranceSeconds ? Self.shortPauseSeconds : Self.pauseSeconds
        if silentSeconds >= pause {
            let chunk = finish()
            reset()
            return chunk
        }
        if Double(frames.count) * Self.frameSeconds >= Self.maxSeconds { return forcedCut() }
        return nil
    }

    /// Voiced time so far, in seconds.
    private var voicedSeconds: Double { Double(frames.filter(\.isVoiced).count) * Self.frameSeconds }

    /// Length of the utterance without its trailing silence.
    private var spokenSeconds: Double { Double(frames.count - silentRun) * Self.frameSeconds }

    private func finish() -> RioSpeechChunk? {
        guard voicedSeconds >= Self.minVoicedSeconds else { return nil }
        let trim = max(0, silentRun - Self.paddingFrames)
        return Self.chunk(from: Array(frames.dropLast(trim)))
    }

    /// Cuts at the quietest frame of the last second; the rest carries on as the next chunk.
    private mutating func forcedCut() -> RioSpeechChunk? {
        let window = Int(Self.cutSearchSeconds / Self.frameSeconds)
        let start = max(1, frames.count - window)
        var cut = frames.count - 1
        var quietest = Float.greatestFiniteMagnitude
        for index in start..<frames.count where frames[index].rms <= quietest {
            quietest = frames[index].rms
            cut = index
        }
        let head = Array(frames[0...cut])
        frames = Array(frames[(cut + 1)...])
        silentRun = frames.reversed().prefix(while: { !$0.isVoiced }).count
        let chunk = Self.chunk(from: head)
        return chunk.voicedSeconds >= Self.minVoicedSeconds ? chunk : nil
    }

    private mutating func reset() {
        frames = []
        preRoll = []
        silentRun = 0
        isActive = false
    }

    private static func chunk(from frames: [Frame]) -> RioSpeechChunk {
        var data = Data(capacity: frames.count * frameSamples * 2)
        for frame in frames { data.append(frame.data) }
        return RioSpeechChunk(
            pcm16: data,
            seconds: Double(frames.count) * frameSeconds,
            voicedSeconds: Double(frames.filter(\.isVoiced).count) * frameSeconds
        )
    }

    /// Root-mean-square level of little-endian PCM16, 0...1.
    private static func rms(of pcm16: Data) -> Float {
        let count = pcm16.count / 2
        guard count > 0 else { return 0 }
        let sum = pcm16.withUnsafeBytes { raw -> Double in
            var total = 0.0
            for index in 0..<count {
                let sample = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)))
                total += sample * sample
            }
            return total
        }
        return Float((sum / Double(count)).squareRoot() / Double(Int16.max))
    }
}
