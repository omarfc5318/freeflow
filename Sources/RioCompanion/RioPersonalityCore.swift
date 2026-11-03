import Foundation

/// Time-of-day moods. Pure: the caller passes the hour (0...23).
enum RioDayMood: Equatable {
    case lateNight
    case morning
    case day

    /// 23:00-05:00 late night, 06:00-10:00 morning, otherwise day (also for bad input).
    static func mood(hour: Int) -> RioDayMood {
        switch hour {
        case 23, 0..<5: return .lateNight
        case 6..<10: return .morning
        default: return .day
        }
    }

    static func current(date: Date = Date(), calendar: Calendar = .current) -> RioDayMood {
        mood(hour: calendar.component(.hour, from: date))
    }

    /// He holds a tiny coffee mug for a few seconds after he is up in the morning.
    static let coffeeSeconds: TimeInterval = 8

    static func holdsCoffee(mood: RioDayMood, restingElapsed: TimeInterval) -> Bool {
        mood == .morning && restingElapsed >= 0 && restingElapsed < coffeeSeconds
    }

    static func wearsNightcap(mood: RioDayMood) -> Bool { mood == .lateNight }
}

/// Grumpy when woken (asked to do something) three or more times within 30 s.
struct RioGrumpyDetector {
    static let window: TimeInterval = 30
    static let threshold = 3

    private var wakes: [TimeInterval] = []

    /// Records a wake; true when this one makes him grumpy.
    mutating func recordWake(at now: TimeInterval) -> Bool {
        wakes = wakes.filter { now - $0 <= Self.window } + [now]
        return wakes.count >= Self.threshold
    }
}

/// Small idle animations while he sits awake, on a fixed rhythm so they cost nothing to schedule.
enum RioFidget {
    enum Kind: Equatable, CaseIterable {
        case yawn
        case scratchEar
        case lookAround
    }

    static let period: TimeInterval = 7
    static let startOffset: TimeInterval = 3.4
    static let length: TimeInterval = 1.8

    /// The fidget in progress `restingElapsed` seconds after he settled, with progress 0...1.
    static func at(restingElapsed: TimeInterval) -> (kind: Kind, progress: Double)? {
        guard restingElapsed >= 0 else { return nil }
        let cycle = Int(restingElapsed / period)
        let local = restingElapsed - Double(cycle) * period - startOffset
        guard local >= 0, local < length else { return nil }
        return (Kind.allCases[cycle % Kind.allCases.count], local / length)
    }
}

enum RioTimerText {
    /// "m:ss", rounded up so it hits 0:00 exactly when it rings; capped at 99:59.
    static func format(_ remaining: TimeInterval) -> String {
        guard remaining.isFinite, remaining > 0 else { return "0:00" }
        let total = min(99 * 60 + 59, Int(remaining.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Notices a counter going up (AppState's `rioCelebrate`).
struct RioCounterWatcher {
    private var last: Int?

    mutating func didIncrement(_ value: Int) -> Bool {
        defer { last = value }
        guard let last else { return false }
        return value > last
    }
}
