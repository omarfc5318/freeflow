import Foundation

/// Beat detection for the song Rio dances the Dougie to. Pure and dependency-free: it takes mono
/// samples, finds the tempo (70-110 BPM), the beat phase and the downbeat, and snaps a requested
/// start time to the nearest downbeat so the dance's count 1 lands on a strong beat.
enum TeddySongSync {
    static let minBPM = 70.0
    static let maxBPM = 110.0
    static let beatsPerBar = 4
    /// Envelope hop. 5 ms keeps the beat phase well inside +-20 ms.
    static let hopSeconds = 0.005
    static let minimumSeconds = 8.0

    struct Analysis: Equatable {
        /// Detected tempo, to 0.1 BPM.
        let bpm: Double
        /// Seconds from the start of the analysed window to a downbeat (0 ..< barSeconds).
        let downbeatOffset: TimeInterval

        var beatSeconds: TimeInterval { 60.0 / bpm }
        var barSeconds: TimeInterval { beatSeconds * Double(TeddySongSync.beatsPerBar) }

        /// The downbeat nearest `requested`, where the analysed window began at `windowOrigin`
        /// seconds into the song. Never negative.
        func alignedStart(near requested: TimeInterval, windowOrigin: TimeInterval) -> TimeInterval {
            let anchor = windowOrigin + downbeatOffset
            let bars = ((requested - anchor) / barSeconds).rounded()
            var start = anchor + bars * barSeconds
            while start < 0 { start += barSeconds }
            return start
        }
    }

    /// Analyses mono samples; nil when they are too short or silent to find a beat.
    static func analyze(samples: [Float], sampleRate: Double) -> Analysis? {
        guard sampleRate > 0, Double(samples.count) / sampleRate >= minimumSeconds else { return nil }
        let bands = onsetBands(samples: samples, sampleRate: sampleRate)
        guard bands.combined.count > 0, bands.combined.max() ?? 0 > 1e-6 else { return nil }
        let env = smoothed(bands.combined)
        guard let beat = bestBeatGrid(env: env) else { return nil }
        let downbeatIndex = strongestBeatOfBar(low: bands.low, firstBeat: beat.phase, period: beat.period)
        let hop = hopSeconds
        // A block's onset lands somewhere inside the block, so shift by half a hop.
        let firstBeatSeconds = (beat.phase + 0.5) * hop
        let beatSeconds = beat.period * hop
        var offset = firstBeatSeconds + Double(downbeatIndex) * beatSeconds
        let bar = beatSeconds * Double(beatsPerBar)
        offset = offset.truncatingRemainder(dividingBy: bar)
        let bpm = (60.0 / beatSeconds * 10).rounded() / 10
        return Analysis(bpm: bpm, downbeatOffset: offset)
    }

    /// Convenience: analyse and snap in one call. Falls back to the requested start and `fallbackBPM`.
    static func alignedStart(
        near requestedStart: TimeInterval,
        samples: [Float],
        sampleRate: Double,
        windowOrigin: TimeInterval,
        fallbackBPM: Double = 85
    ) -> (start: TimeInterval, bpm: Double) {
        guard let analysis = analyze(samples: samples, sampleRate: sampleRate) else {
            return (requestedStart, fallbackBPM)
        }
        return (analysis.alignedStart(near: requestedStart, windowOrigin: windowOrigin), analysis.bpm)
    }

    // MARK: - Onset envelope

    /// Per-hop onset strength: a log-compressed rise in low-band (kick) and high-band (snare, hat)
    /// energy, each normalised so neither dominates.
    private static func onsetBands(samples: [Float], sampleRate: Double) -> (low: [Double], combined: [Double]) {
        let hop = max(1, Int(sampleRate * hopSeconds))
        let blocks = samples.count / hop
        guard blocks > 2 else { return ([], []) }
        let lowCoefficient = 1 - exp(-2 * Double.pi * 150 / sampleRate)
        let highCoefficient = 1 - exp(-2 * Double.pi * 1500 / sampleRate)
        var low = [Double](repeating: 0, count: blocks)
        var high = [Double](repeating: 0, count: blocks)
        var lowState = 0.0
        var highState = 0.0
        samples.withUnsafeBufferPointer { buffer in
            for block in 0..<blocks {
                var lowSum = 0.0
                var highSum = 0.0
                for i in (block * hop)..<((block + 1) * hop) {
                    let x = Double(buffer[i])
                    lowState += lowCoefficient * (x - lowState)
                    highState += highCoefficient * (x - highState)
                    let highPassed = x - highState
                    lowSum += lowState * lowState
                    highSum += highPassed * highPassed
                }
                low[block] = (lowSum / Double(hop)).squareRoot()
                high[block] = (highSum / Double(hop)).squareRoot()
            }
        }
        let lowFlux = flux(of: low)
        let highFlux = flux(of: high)
        let combined = zip(lowFlux, highFlux).map { $0 + $1 }
        return (lowFlux, combined)
    }

    private static func flux(of energy: [Double]) -> [Double] {
        let peak = energy.max() ?? 0
        guard peak > 1e-9 else { return [Double](repeating: 0, count: energy.count) }
        let compressed = energy.map { log(1 + 30 * $0 / peak) }
        var out = [Double](repeating: 0, count: compressed.count)
        for i in 1..<compressed.count { out[i] = max(0, compressed[i] - compressed[i - 1]) }
        let top = out.max() ?? 0
        return top > 0 ? out.map { $0 / top } : out
    }

    private static func smoothed(_ x: [Double]) -> [Double] {
        guard x.count > 2 else { return x }
        var out = x
        for i in 1..<(x.count - 1) { out[i] = 0.25 * x[i - 1] + 0.5 * x[i] + 0.25 * x[i + 1] }
        return out
    }

    // MARK: - Tempo and phase

    /// Comb-filters the envelope: for each candidate period and phase, the mean envelope under a
    /// train of beats. A coarse search over tempo, then a fine one around the winner.
    private static func bestBeatGrid(env: [Double]) -> (period: Double, phase: Double)? {
        let mean = env.reduce(0, +) / Double(env.count)
        let centred = env.map { $0 - mean }
        func period(bpm: Double) -> Double { 60.0 / bpm / hopSeconds }
        var best: (score: Double, bpm: Double, phase: Double)?
        func consider(bpm: Double) {
            let p = period(bpm: bpm)
            let phaseSteps = Int(p * 2)
            for step in 0..<phaseSteps {
                let phase = Double(step) * 0.5
                let score = combScore(centred, period: p, phase: phase)
                if best == nil || score > best!.score { best = (score, bpm, phase) }
            }
        }
        var bpm = minBPM
        while bpm <= maxBPM { consider(bpm: bpm); bpm += 0.25 }
        guard let coarse = best else { return nil }
        let centre = coarse.bpm
        bpm = max(minBPM, centre - 0.4)
        while bpm <= min(maxBPM, centre + 0.4) { consider(bpm: bpm); bpm += 0.05 }
        guard let final = best else { return nil }
        return (period(bpm: final.bpm), final.phase)
    }

    private static func combScore(_ x: [Double], period: Double, phase: Double) -> Double {
        var sum = 0.0
        var count = 0
        var position = phase
        let last = Double(x.count - 2)
        while position < last {
            let i = Int(position)
            let f = position - Double(i)
            sum += x[i] * (1 - f) + x[i + 1] * f
            count += 1
            position += period
        }
        return count > 0 ? sum / Double(count) : 0
    }

    // MARK: - Downbeat

    /// Which beat (0-3, counted from the first beat in the window) starts the bar: the one whose
    /// beats carry the most low-frequency (kick) onset energy across the window.
    private static func strongestBeatOfBar(low: [Double], firstBeat: Double, period: Double) -> Int {
        var sums = [Double](repeating: 0, count: beatsPerBar)
        var k = 0
        while true {
            let centre = Int((firstBeat + Double(k) * period).rounded())
            if centre + 2 >= low.count { break }
            var peak = 0.0
            for i in max(0, centre - 2)...(centre + 2) { peak = max(peak, low[i]) }
            sums[k % beatsPerBar] += peak
            k += 1
        }
        var bestIndex = 0
        for i in 1..<beatsPerBar where sums[i] > sums[bestIndex] { bestIndex = i }
        return bestIndex
    }
}
