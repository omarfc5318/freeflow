import Foundation

/// Whisper mode: raises very quiet recordings to a normal speaking level before
/// transcription. Speech models are trained mostly on normal-volume audio, so
/// whispered dictation that peaks far below full scale is often transcribed as
/// silence or as stock "Thank you." hallucinations. Gain is only ever added, never
/// removed, and is capped so a silent room is not blown up into loud noise.
enum WhisperBoostCore {
    /// Loud speech peaks are brought to this level (about -1 dBFS).
    static let targetPeak: Double = 0.89
    /// Never amplify by more than this (+30 dB), so near-silence stays quiet.
    static let maxGain: Double = 31.6
    /// Below this the boost is not worth the extra noise.
    static let minimumUsefulGain: Double = 1.12
    /// Ignores the loudest 0.1% of samples (clicks, pops) when measuring the peak.
    static let peakPercentile: Double = 0.999
    /// Samples pushed above this knee are softly compressed instead of clipped.
    static let limiterKnee: Double = 0.8
    /// The limiter's output never exceeds this, so even a boosted click cannot clip.
    static let limiterCeiling: Double = 0.98

    struct Result: Equatable {
        let samples: [Int16]
        /// Gain actually applied, in decibels (0 when the audio was left unchanged).
        let gainDecibels: Double
    }

    static func boost(_ samples: [Int16]) -> Result {
        guard !samples.isEmpty else { return Result(samples: samples, gainDecibels: 0) }
        let offset = Int((Double(samples.reduce(0) { $0 + Int($1) }) / Double(samples.count)).rounded())
        let peak = percentilePeak(samples, offset: offset)
        guard peak > 0 else { return Result(samples: samples, gainDecibels: 0) }

        let gain = min(maxGain, targetPeak / peak)
        guard gain >= minimumUsefulGain else { return Result(samples: samples, gainDecibels: 0) }

        let boosted = samples.map { sample -> Int16 in
            let limited = softLimit(Double(Int(sample) - offset) / 32768.0 * gain)
            return Int16((limited * 32767.0).rounded())
        }
        return Result(samples: boosted, gainDecibels: 20 * log10(gain))
    }

    /// The level (0...1) that all but the loudest `peakPercentile` of samples stay under,
    /// measured after removing `offset`. A histogram keeps this linear in time and memory,
    /// so a long recording is not copied and sorted.
    static func percentilePeak(_ samples: [Int16], offset: Int = 0) -> Double {
        guard !samples.isEmpty else { return 0 }
        var histogram = [Int](repeating: 0, count: 65_537)
        for sample in samples {
            histogram[min(65_536, abs(Int(sample) - offset))] += 1
        }
        let rank = Int(Double(samples.count - 1) * peakPercentile)
        var seen = 0
        for (magnitude, count) in histogram.enumerated() {
            seen += count
            if seen > rank { return Double(magnitude) / 32768.0 }
        }
        return 0
    }

    /// Linear below the knee, then a smooth curve that approaches but never passes the ceiling.
    static func softLimit(_ value: Double) -> Double {
        let magnitude = abs(value)
        guard magnitude > limiterKnee else { return value }
        let headroom = limiterCeiling - limiterKnee
        let compressed = limiterKnee + headroom * tanh((magnitude - limiterKnee) / headroom)
        return value < 0 ? -compressed : compressed
    }
}
