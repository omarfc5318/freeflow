import Foundation

// Pure scheduling rules for how often the corner bear redraws and how often his housekeeping
// timer wakes the process (M7, idle CPU). No AppKit and no clock, so every tier and every pause
// is unit-tested, including a wakeups-per-second estimate for each situation.

/// How the bear's panel is redrawn.
enum RioRedrawSchedule: Equatable {
    /// Nothing is drawn: the display is asleep, the session is inactive or the panel is covered.
    case paused
    /// A fixed, slow tick (`TimelineView(.periodic)`): asleep, resting with a timer.
    case periodic(TimeInterval)
    /// Display-linked frames, at most one per `minimumInterval` (an action is on screen).
    case animation(minimumInterval: TimeInterval)

    /// Redraws per second the schedule costs (display-linked frames are capped at 60).
    var redrawsPerSecond: Double {
        switch self {
        case .paused: return 0
        case let .periodic(interval): return 1 / interval
        case let .animation(minimumInterval): return min(60, 1 / minimumInterval)
        }
    }
}

/// When drawing must stop altogether. All three flags default to "visible and awake".
struct RioRedrawGate: Equatable {
    var displayAsleep = false
    var sessionActive = true
    var panelVisible = true

    var isPaused: Bool { displayAsleep || !sessionActive || !panelVisible }
}

enum RioRedrawPolicy {
    /// Asleep: two redraws a second is plenty for the breathing and the floating Zs.
    static let sleepyInterval: TimeInterval = 0.5
    /// A timer is counting down and nothing else is happening: the clock text changes once a second.
    static let timerInterval: TimeInterval = 1
    static let restingInterval: TimeInterval = 0.1
    static let actionInterval: TimeInterval = 1.0 / 30
    static let runInterval: TimeInterval = 1.0 / 60
    static let awayInterval: TimeInterval = 0.5

    /// What the panel redraws at. `hasTimer` is a running countdown.
    static func schedule(
        mode: RioCompanionMachine.Mode, hasTimer: Bool, hasErrorCard: Bool, gate: RioRedrawGate
    ) -> RioRedrawSchedule {
        if gate.isPaused { return .paused }
        let interval: TimeInterval
        switch mode {
        case .asleep: interval = sleepyInterval
        case .away: interval = awayInterval
        case .resting: interval = hasTimer ? timerInterval : restingInterval
        case .sprint, .punch, .returning: interval = runInterval
        default: interval = actionInterval
        }
        // A short-lived error card needs smooth frames even when he is otherwise sleepy.
        if hasErrorCard, interval > actionInterval { return .animation(minimumInterval: actionInterval) }
        return interval >= 0.25 ? .periodic(interval) : .animation(minimumInterval: interval)
    }

    /// How often the model's housekeeping timer (expires cards, doses off, re-picks the tier)
    /// needs to fire. Nil: no timer at all (asleep with nothing pending, or paused).
    static func housekeepingInterval(schedule: RioRedrawSchedule, hasPendingExpiry: Bool) -> TimeInterval? {
        switch schedule {
        case .paused: return nil
        case let .periodic(interval):
            if interval >= timerInterval { return timerInterval }
            return hasPendingExpiry ? 0.5 : nil
        case .animation: return 0.2
        }
    }

    /// Wakeups per second for a schedule plus its housekeeping timer.
    static func wakeupsPerSecond(schedule: RioRedrawSchedule, hasPendingExpiry: Bool) -> Double {
        let timer = housekeepingInterval(schedule: schedule, hasPendingExpiry: hasPendingExpiry).map { 1 / $0 } ?? 0
        return schedule.redrawsPerSecond + timer
    }
}

/// The bear's own UserDefaults values. The Hub reacts to the global "some default changed"
/// notification (it carries no key) only when this snapshot differs, so unrelated writes by the
/// rest of the app never re-run style, layout and the Dock walk.
struct RioBearDefaults: Equatable {
    var style: String?
    var showInCaptures: Bool
    var dockRunEnabled: Bool

    static func read(from defaults: UserDefaults, styleKey: String, capturesKey: String, dockRunKey: String) -> RioBearDefaults {
        RioBearDefaults(
            style: defaults.string(forKey: styleKey),
            showInCaptures: defaults.bool(forKey: capturesKey),
            dockRunEnabled: (defaults.object(forKey: dockRunKey) as? Bool) ?? true
        )
    }
}

/// At most one Dock run per `minimumGap`, however fast the owner clicks icons. A refused run
/// does not use up the slot.
struct RioDockRunThrottle: Equatable {
    static let minimumGap: TimeInterval = 0.5

    private var lastRun: TimeInterval = -.infinity

    func allows(at now: TimeInterval) -> Bool {
        now < lastRun || now - lastRun >= Self.minimumGap
    }

    mutating func record(at now: TimeInterval) { lastRun = now }
}
