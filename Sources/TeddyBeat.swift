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

    func start() {
        guard !isPlaying, prepare() else { return }
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
        player.stop()
        engine.stop()
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
