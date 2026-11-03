import AVFoundation
import Foundation

/// An original hip-hop loop at 85 BPM, synthesized from scratch (kick, clap, closed hats and a
/// bass line). No audio files, no network, and nothing taken from any existing song.
enum TeddyBeatPattern {
    static let bpm = 85.0
    static let stepsPerBeat = 4
    static let beatsPerBar = 4
    static let bars = 2
    static let stepsPerBar = stepsPerBeat * beatsPerBar
    static let sampleRate = 44_100.0
    static let volume: Float = 0.35

    struct BassNote: Equatable {
        let step: Int
        /// Semitones above A1 (55 Hz).
        let semitone: Int
        let steps: Int
    }

    /// 16th-note steps within one bar.
    static let kickSteps: [Int] = [0, 3, 8, 10]
    static let clapSteps: [Int] = [4, 12]
    static let hatSteps: [Int] = [0, 2, 4, 6, 8, 10, 12, 14]
    /// Bar 1 and bar 2 of the bass line.
    static let bassBars: [[BassNote]] = [
        [.init(step: 0, semitone: 0, steps: 3), .init(step: 3, semitone: 0, steps: 1),
         .init(step: 6, semitone: 3, steps: 2), .init(step: 10, semitone: 7, steps: 2),
         .init(step: 12, semitone: 5, steps: 3)],
        [.init(step: 0, semitone: 0, steps: 3), .init(step: 4, semitone: 12, steps: 1),
         .init(step: 6, semitone: 10, steps: 2), .init(step: 10, semitone: 7, steps: 2),
         .init(step: 12, semitone: 3, steps: 3)],
    ]

    static var stepSeconds: Double { 60 / bpm / Double(stepsPerBeat) }
    static var loopSeconds: Double { stepSeconds * Double(stepsPerBar * bars) }

    static func frameCount(sampleRate: Double = sampleRate) -> Int {
        Int((loopSeconds * sampleRate).rounded())
    }

    /// Frame at which a step of the whole loop starts.
    static func startFrame(ofStep step: Int, sampleRate: Double = sampleRate) -> Int {
        Int((Double(step) * stepSeconds * sampleRate).rounded())
    }

    /// Every step index (over the whole loop) where a given per-bar pattern fires.
    static func loopSteps(_ pattern: [Int]) -> [Int] {
        (0..<bars).flatMap { bar in pattern.map { bar * stepsPerBar + $0 } }
    }

    /// Mono samples for the whole loop, in -1...1.
    static func render(sampleRate: Double = sampleRate) -> [Float] {
        var out = [Float](repeating: 0, count: frameCount(sampleRate: sampleRate))
        var noise = NoiseSource()

        for step in loopSteps(kickSteps) {
            addKick(to: &out, at: startFrame(ofStep: step, sampleRate: sampleRate), sampleRate: sampleRate)
        }
        for step in loopSteps(clapSteps) {
            addClap(to: &out, at: startFrame(ofStep: step, sampleRate: sampleRate), sampleRate: sampleRate, noise: &noise)
        }
        for step in loopSteps(hatSteps) {
            addHat(to: &out, at: startFrame(ofStep: step, sampleRate: sampleRate), sampleRate: sampleRate, noise: &noise)
        }
        for (bar, notes) in bassBars.enumerated() {
            for note in notes {
                let step = bar * stepsPerBar + note.step
                addBass(to: &out, note: note, at: startFrame(ofStep: step, sampleRate: sampleRate), sampleRate: sampleRate)
            }
        }

        // Soft clip, then a short fade at the very end so the loop seam never clicks.
        let fade = min(out.count, Int(0.004 * sampleRate))
        for i in out.indices {
            var s = tanhf(out[i])
            if i >= out.count - fade { s *= Float(out.count - 1 - i) / Float(max(1, fade)) }
            out[i] = s
        }
        return out
    }

    // MARK: Voices

    private struct NoiseSource {
        private var state: UInt32 = 0x1234_5678
        mutating func next() -> Float {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: state)) / Float(Int32.max)
        }
    }

    private static func add(_ value: Float, to out: inout [Float], at index: Int) {
        guard index >= 0, index < out.count else { return }
        out[index] += value
    }

    private static func addKick(to out: inout [Float], at start: Int, sampleRate: Double) {
        let length = Int(0.32 * sampleRate)
        var phase = 0.0
        for n in 0..<length {
            let t = Double(n) / sampleRate
            let frequency = 45 + 85 * exp(-t * 28)
            phase += 2 * Double.pi * frequency / sampleRate
            let envelope = exp(-t * 9)
            add(Float(sin(phase) * envelope) * 0.9, to: &out, at: start + n)
        }
    }

    private static func addClap(to out: inout [Float], at start: Int, sampleRate: Double, noise: inout NoiseSource) {
        let length = Int(0.22 * sampleRate)
        var low: Float = 0
        for n in 0..<length {
            let t = Double(n) / sampleRate
            // A few quick bursts, then a tail.
            let burst = (t < 0.03 ? 1.0 : 0) * (0.5 + 0.5 * sin(t * 2 * Double.pi * 100))
            let envelope = Float(max(exp(-t * 18), burst * 0.8))
            let raw = noise.next()
            low += 0.35 * (raw - low)
            let band = low - 0.35 * raw
            add(band * envelope * 0.55, to: &out, at: start + n)
        }
    }

    private static func addHat(to out: inout [Float], at start: Int, sampleRate: Double, noise: inout NoiseSource) {
        let length = Int(0.05 * sampleRate)
        var previous: Float = 0
        for n in 0..<length {
            let t = Double(n) / sampleRate
            let raw = noise.next()
            let high = raw - previous
            previous = raw
            add(high * Float(exp(-t * 90)) * 0.16, to: &out, at: start + n)
        }
    }

    private static func addBass(to out: inout [Float], note: BassNote, at start: Int, sampleRate: Double) {
        let frequency = 55 * pow(2, Double(note.semitone) / 12)
        let length = Int(Double(note.steps) * stepSeconds * sampleRate)
        for n in 0..<length {
            let t = Double(n) / sampleRate
            let attack = min(1, t / 0.008)
            let release = min(1, Double(length - n) / (0.03 * sampleRate))
            let tone = sin(2 * Double.pi * frequency * t) + 0.25 * sin(4 * Double.pi * frequency * t)
            add(Float(tone * attack * release * exp(-t * 2.2)) * 0.42, to: &out, at: start + n)
        }
    }
}

/// Plays the loop quietly in the background through its own output-only audio engine.
/// It never touches the microphone or the app's recorder. Main thread only; `start()` and
/// `stop()` can be called repeatedly, and any failure to start is silent.
final class TeddyBeat {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?
    private var isPrepared = false

    private(set) var isPlaying = false
    /// The user's own song file, when one is chosen in Settings.
    private var songPlayer: AVAudioPlayer?

    func start() {
        guard !isPlaying else { return }
        if startSong() { return }
        guard prepare() else { return }
        do {
            try engine.start()
        } catch {
            return
        }
        player.volume = TeddyBeatPattern.volume
        if let buffer {
            player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        }
        player.play()
        isPlaying = true
    }

    func stop() {
        guard isPlaying else { return }
        isPlaying = false
        if let song = songPlayer {
            songPlayer = nil
            // A short fade so the song doesn't cut off mid-word.
            song.setVolume(0, fadeDuration: TeddyDougieSong.fadeSeconds)
            DispatchQueue.main.asyncAfter(deadline: .now() + TeddyDougieSong.fadeSeconds) { song.stop() }
            return
        }
        player.stop()
        engine.stop()
    }

    /// Plays the song file chosen in Settings from its start time; false when none is set
    /// or it can't be played, so the built-in beat plays instead.
    private func startSong() -> Bool {
        guard let url = TeddyDougieSong.fileURL(),
              let song = try? AVAudioPlayer(contentsOf: url) else { return false }
        song.currentTime = TeddyDougieSong.playbackStart(clampedTo: song.duration)
        song.volume = TeddyDougieSong.volume
        guard song.play() else { return false }
        songPlayer = song
        isPlaying = true
        return true
    }

    private func prepare() -> Bool {
        if isPrepared { return buffer != nil }
        isPrepared = true
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: TeddyBeatPattern.sampleRate,
            channels: 1,
            interleaved: false
        ) else { return false }
        let samples = TeddyBeatPattern.render()
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = pcm.floatChannelData?[0] else { return false }
        for (i, sample) in samples.enumerated() { channel[i] = sample }
        pcm.frameLength = AVAudioFrameCount(samples.count)
        buffer = pcm

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        return true
    }
}

/// The user's own song for Rio's Dougie: a local audio file they chose, and where in it to
/// start. Nothing is downloaded or bundled; the file is only read from the user's Mac.
enum TeddyDougieSong {
    static let pathKey = "dougie_song_path"
    static let startSecondsKey = "dougie_song_start_seconds"
    static let volume: Float = 0.6
    static let fadeSeconds: TimeInterval = 0.4

    static func fileURL(defaults: UserDefaults = .standard) -> URL? {
        guard let path = defaults.string(forKey: pathKey), !path.isEmpty,
              FileManager.default.isReadableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func startSeconds(defaults: UserDefaults = .standard) -> TimeInterval {
        max(0, defaults.double(forKey: startSecondsKey))
    }

    /// The chosen start, kept inside the song so playback always has something left to play.
    static func startTime(clampedTo duration: TimeInterval, defaults: UserDefaults = .standard) -> TimeInterval {
        let start = startSeconds(defaults: defaults)
        guard duration > 0 else { return 0 }
        return start < duration - 1 ? start : 0
    }

    // MARK: - Beat sync

    static let bpmKey = "dougie_song_bpm"
    static let syncedStartSecondsKey = "dougie_song_synced_start_seconds"
    static let defaultBPM = 85.0
    /// How much of the song is analysed around the requested start.
    static let analysisLeadSeconds: TimeInterval = 5
    static let analysisSpanSeconds: TimeInterval = 30

    /// The song's detected tempo, or the dance's default 85 BPM when none has been detected.
    static func bpm(defaults: UserDefaults = .standard) -> Double {
        let value = defaults.double(forKey: bpmKey)
        return value > 0 ? value : defaultBPM
    }

    /// The beat-aligned start, or the raw chosen start when no sync result is stored.
    static func syncedStartSeconds(defaults: UserDefaults = .standard) -> TimeInterval {
        guard defaults.object(forKey: syncedStartSecondsKey) != nil else { return startSeconds(defaults: defaults) }
        return max(0, defaults.double(forKey: syncedStartSecondsKey))
    }

    static func hasSync(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: syncedStartSecondsKey) != nil && defaults.double(forKey: bpmKey) > 0
    }

    /// Where playback begins: the beat-aligned start when present, else the chosen start.
    static func playbackStart(clampedTo duration: TimeInterval, defaults: UserDefaults = .standard) -> TimeInterval {
        let start = syncedStartSeconds(defaults: defaults)
        guard duration > 0 else { return 0 }
        return start < duration - 1 ? start : startTime(clampedTo: duration, defaults: defaults)
    }

    static func storeSync(bpm: Double, syncedStart: TimeInterval, defaults: UserDefaults = .standard) {
        defaults.set(bpm, forKey: bpmKey)
        defaults.set(syncedStart, forKey: syncedStartSecondsKey)
    }

    static func clearSync(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: bpmKey)
        defaults.removeObject(forKey: syncedStartSecondsKey)
    }

    /// Reads a window of the file around `requestedStart`, downmixed to mono, and finds the beat.
    /// Blocking: call off the main thread. Nil when the file can't be read or has no clear beat.
    static func analyzeBeat(at url: URL, requestedStart: TimeInterval) -> (bpm: Double, syncedStart: TimeInterval)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        let total = file.length
        guard rate > 0, total > 0 else { return nil }
        let origin = max(0, requestedStart - analysisLeadSeconds)
        let first = AVAudioFramePosition(origin * rate)
        guard first < total else { return nil }
        let wanted = AVAudioFrameCount(min(AVAudioFramePosition(analysisSpanSeconds * rate), total - first))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: wanted) else { return nil }
        file.framePosition = first
        do { try file.read(into: buffer, frameCount: wanted) } catch { return nil }
        guard let channels = buffer.floatChannelData else { return nil }
        let count = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard count > 0, channelCount > 0 else { return nil }
        var mono = [Float](repeating: 0, count: count)
        for channel in 0..<channelCount {
            let data = channels[channel]
            for i in 0..<count { mono[i] += data[i] }
        }
        if channelCount > 1 {
            let scale = 1 / Float(channelCount)
            for i in 0..<count { mono[i] *= scale }
        }
        guard let analysis = TeddySongSync.analyze(samples: mono, sampleRate: rate) else { return nil }
        let start = analysis.alignedStart(near: requestedStart, windowOrigin: origin)
        return (analysis.bpm, start)
    }
}
