import Foundation

/// Beat detection on synthetic click tracks with a known tempo and downbeat.
enum TeddySongSyncTests {
    static func run() {
        testDetectsTempoAndDownbeat()
        testSnapsStartToNearestDownbeat()
        testRejectsSilenceAndShortClips()
    }

    private static let sampleRate = 32_000.0

    /// Kick on every beat (louder on each bar's first), a hat on the off-beats, and noise.
    private static func track(bpm: Double, firstDownbeat: Double, seconds: Double, seed: UInt64) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(seconds * sampleRate))
        var rng = seed
        let beat = 60.0 / bpm
        var k = -8
        while firstDownbeat + Double(k) * beat < seconds {
            let time = firstDownbeat + Double(k) * beat
            let isDownbeat = ((k % 4) + 4) % 4 == 0
            addKick(&samples, at: time, gain: isDownbeat ? 0.9 : 0.5)
            addHat(&samples, at: time + beat / 2, rng: &rng)
            k += 1
        }
        for i in samples.indices { samples[i] += 0.03 * nextNoise(&rng) }
        return samples
    }

    private static func nextNoise(_ rng: inout UInt64) -> Float {
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: rng >> 11) % 2_001 - 1_000) / 1_000
    }

    private static func addKick(_ samples: inout [Float], at time: Double, gain: Float) {
        let start = Int(time * sampleRate)
        for n in 0..<Int(0.12 * sampleRate) where start + n >= 0 && start + n < samples.count {
            let t = Double(n) / sampleRate
            samples[start + n] += gain * Float(sin(2 * .pi * 60 * t) * exp(-t * 35))
        }
    }

    private static func addHat(_ samples: inout [Float], at time: Double, rng: inout UInt64) {
        let start = Int(time * sampleRate)
        for n in 0..<Int(0.02 * sampleRate) where start + n >= 0 && start + n < samples.count {
            samples[start + n] += 0.15 * nextNoise(&rng) * Float(exp(-Double(n) / (0.004 * sampleRate)))
        }
    }

    private static func testDetectsTempoAndDownbeat() {
        let cases: [(bpm: Double, downbeat: Double)] = [(85, 1.37), (85.2, 0.2), (72, 0.9), (104.5, 2.1), (91, 0.55)]
        for (index, c) in cases.enumerated() {
            let samples = track(bpm: c.bpm, firstDownbeat: c.downbeat, seconds: 30, seed: UInt64(index + 1))
            guard let analysis = TeddySongSync.analyze(samples: samples, sampleRate: sampleRate) else {
                TestSupport.expect(false, "Beat found for \(c.bpm) BPM")
                continue
            }
            TestSupport.expect(abs(analysis.bpm - c.bpm) <= 0.5, "Tempo \(analysis.bpm) vs \(c.bpm)")
            let snapped = analysis.alignedStart(near: c.downbeat + 0.3, windowOrigin: 0)
            TestSupport.expect(abs(snapped - c.downbeat) <= 0.02, "Downbeat \(snapped) vs \(c.downbeat) at \(c.bpm) BPM")
        }
    }

    private static func testSnapsStartToNearestDownbeat() {
        let bpm = 85.0
        let bar = 60.0 / bpm * 4
        // The window begins 51 s into the song; downbeats are at 52.1 + n bars.
        let samples = track(bpm: bpm, firstDownbeat: 1.1, seconds: 30, seed: 9)
        let result = TeddySongSync.alignedStart(
            near: 52.1 + 2 * bar + 0.4, samples: samples, sampleRate: sampleRate, windowOrigin: 51
        )
        TestSupport.expect(abs(result.start - (52.1 + 2 * bar)) <= 0.02, "Snaps to the closest downbeat, got \(result.start)")
        TestSupport.expect(abs(result.bpm - bpm) <= 0.5, "Reports the tempo")
    }

    private static func testRejectsSilenceAndShortClips() {
        TestSupport.expect(
            TeddySongSync.analyze(samples: [Float](repeating: 0, count: 32_000 * 20), sampleRate: sampleRate) == nil,
            "Silence has no beat"
        )
        TestSupport.expect(
            TeddySongSync.analyze(samples: [Float](repeating: 0.1, count: 32_000 * 2), sampleRate: sampleRate) == nil,
            "Too-short clips have no beat"
        )
        let fallback = TeddySongSync.alignedStart(near: 56.75, samples: [], sampleRate: sampleRate, windowOrigin: 51.75)
        TestSupport.expectEqual(fallback.start, 56.75)
        TestSupport.expectEqual(fallback.bpm, 85)
    }
}
