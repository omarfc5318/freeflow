import Foundation

/// A fixed-size ring of PCM16 mono audio. Pure value type: the meeting copilot keeps its last
/// five minutes here, in memory only. Samples are native-endian Int16.
struct RioAudioRing {
    let sampleRate: Int
    private let capacity: Int
    private var storage: [Int16]
    private var head = 0  // next write position (the oldest sample once full)
    private(set) var sampleCount = 0

    init(capacitySeconds: Int, sampleRate: Int = RioSpeechChunker.sampleRate) {
        self.sampleRate = sampleRate
        capacity = max(1, capacitySeconds * sampleRate)
        storage = [Int16](repeating: 0, count: capacity)
    }

    var seconds: Double { Double(sampleCount) / Double(sampleRate) }

    mutating func append(_ pcm16: Data) {
        let count = pcm16.count / 2
        guard count > 0 else { return }
        let incoming: [Int16] = pcm16.withUnsafeBytes { raw in
            (0..<count).map { raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self) }
        }
        let tail = incoming.count > capacity ? Array(incoming.suffix(capacity)) : incoming
        for sample in tail {
            storage[head] = sample
            head = (head + 1) % capacity
        }
        sampleCount = min(capacity, sampleCount + tail.count)
    }

    /// The most recent `seconds` of audio (less if the ring holds less), oldest first.
    func last(seconds: Double) -> Data {
        let wanted = min(sampleCount, max(0, Int((seconds * Double(sampleRate)).rounded())))
        guard wanted > 0 else { return Data() }
        var out = [Int16]()
        out.reserveCapacity(wanted)
        let start = (head - wanted + capacity * 2) % capacity
        for offset in 0..<wanted { out.append(storage[(start + offset) % capacity]) }
        return RioPCMConvert.data(out)
    }

    mutating func reset() {
        head = 0
        sampleCount = 0
    }
}

/// Mixes two PCM16 mono streams that both end "now": they are aligned at the end.
enum RioAudioMix {
    static func mix(_ a: Data, _ b: Data) -> Data {
        let x = samples(a)
        let y = samples(b)
        let length = max(x.count, y.count)
        var out = [Int16](repeating: 0, count: length)
        for i in 0..<length {
            let xi = i - (length - x.count)
            let yi = i - (length - y.count)
            let sum = (xi >= 0 ? Int(x[xi]) : 0) + (yi >= 0 ? Int(y[yi]) : 0)
            out[i] = Int16(max(Int(Int16.min), min(Int(Int16.max), sum)))
        }
        return RioPCMConvert.data(out)
    }

    private static func samples(_ data: Data) -> [Int16] {
        let count = data.count / 2
        return data.withUnsafeBytes { raw in
            (0..<count).map { raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self) }
        }
    }
}

enum RioAudioLevel {
    /// RMS (0...1) under which a clip is treated as silence; Whisper invents words for silence.
    static let silenceRMS = 0.004

    static func isSilent(_ pcm16: Data) -> Bool {
        let count = pcm16.count / 2
        guard count > 0 else { return true }
        let total: Double = pcm16.withUnsafeBytes { raw in
            var sum = 0.0
            for i in 0..<count {
                let value = Double(raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)) / 32768
                sum += value * value
            }
            return sum
        }
        return (total / Double(count)).squareRoot() < silenceRMS
    }
}

/// Float-sample helpers for turning ScreenCaptureKit and microphone buffers into 16 kHz mono PCM16.
enum RioPCMConvert {
    /// Average of the channels, sample by sample.
    static func downmix(_ channels: [[Float]]) -> [Float] {
        guard let first = channels.first else { return [] }
        guard channels.count > 1 else { return first }
        let length = channels.map(\.count).min() ?? 0
        return (0..<length).map { i in channels.reduce(0) { $0 + $1[i] } / Float(channels.count) }
    }

    /// Linear-interpolation resampling. Fine for speech going to Whisper.
    static func resample(_ input: [Float], from: Int, to: Int) -> [Float] {
        guard from != to, from > 0, to > 0, input.count > 1 else { return input }
        let outCount = Int(Double(input.count) * Double(to) / Double(from))
        guard outCount > 0 else { return [] }
        let step = Double(from) / Double(to)
        return (0..<outCount).map { i in
            let position = Double(i) * step
            let lower = min(input.count - 1, Int(position))
            let upper = min(input.count - 1, lower + 1)
            let fraction = Float(position - Double(lower))
            return input[lower] + (input[upper] - input[lower]) * fraction
        }
    }

    static func int16(_ input: [Float]) -> [Int16] {
        input.map { Int16(max(-1, min(1, $0)) * Float(Int16.max)) }
    }

    static func data(_ samples: [Int16]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
