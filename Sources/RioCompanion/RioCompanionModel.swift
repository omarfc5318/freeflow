import SwiftUI

/// Live state behind the corner bear's panel. Main actor only. The machine decides what he is
/// doing; this turns that into a drawable snapshot each frame.
@MainActor
final class RioCompanionModel: ObservableObject {
    /// How the panel redraws: paused when nothing can be seen, slow while asleep or counting a
    /// timer, smooth while he acts (pure rules in RioRedrawPolicyCore.swift).
    @Published private(set) var schedule: RioRedrawSchedule = .periodic(RioRedrawPolicy.sleepyInterval)
    @Published var showsStop = false
    /// Display asleep, session inactive or panel covered: draw nothing.
    var gate = RioRedrawGate()

    struct Run {
        let plan: RioDockRunPlan
        let start: TimeInterval
        let startX: CGFloat
        let finalX: CGFloat
        let iconCenter: CGPoint
    }

    var machine = RioCompanionMachine()
    var mood: RioDayMood = .day
    private var lastMoodCheck: TimeInterval = -.infinity
    var level: CGFloat = 0
    var outfit: TeddyOutfit = .hoodie
    var look: SpokenLook = .none
    /// Over-ear headphones while Rio is translating.
    var wearsHeadphones = false
    var homeX: CGFloat = 28
    var groundY: CGFloat = RioCompanionMetrics.cornerPanelSize.height - RioCompanionLayout.groundInset
    var run: Run?
    var errorText: (text: String, until: TimeInterval)?
    /// A plain speech card shown whatever he is doing (except mid run or trick), e.g. the crash apology.
    var noticeText: (text: String, until: TimeInterval)?
    var onStop: () -> Void = {}

    private var lastMode: RioCompanionMachine.Mode = .asleep
    private var modeStart: TimeInterval = 0

    func snapshot(at now: TimeInterval) -> RioCompanionSnapshot {
        let mode = machine.mode(at: now)
        if mode != lastMode { lastMode = mode; modeStart = now }
        let elapsed = now - modeStart
        let time = now
        var x = homeX
        var runInfo: (elapsed: TimeInterval, plan: RioDockRunPlan)?
        var impact: RioCompanionSnapshot.Impact?
        if let run {
            let t = now - run.start
            runInfo = (t, run.plan)
            switch mode {
            case .sprint, .punch:
                x = run.startX + (run.finalX - run.startX) * run.plan.runFraction(at: t)
            case .returning:
                let q = min(1, max(0, CGFloat((t - run.plan.totalDuration) / RioDockRunPlan.returnDuration)))
                x = run.finalX + (run.startX - run.finalX) * q * q * (3 - 2 * q)
            default: break
            }
            if t >= run.plan.impactTime, t < run.plan.impactTime + 0.3 {
                impact = .init(center: run.iconCenter, progress: (t - run.plan.impactTime) / 0.3)
            }
        }

        var figure = RioCompanionPoseBuilder.figure(
            mode: mode, time: time, elapsed: elapsed, level: level,
            moment: machine.activeMoment(at: now), run: runInfo,
            mood: mood, grumpy: machine.isGrumpy(at: now), timerText: machine.timerText()
        )
        if wearsHeadphones, mode != .away { figure.pose.headProp = .headphones }
        var bubble: RioCompanionSnapshot.Bubble?
        if let moment = machine.activeMoment(at: now), mode == .moment {
            bubble = .init(caption: moment.caption, text: moment.text)
        } else if let text = machine.bubbleText(at: now), [.alert, .thinking, .happy, .shrug].contains(mode) {
            bubble = .init(caption: nil, text: text)
        } else if mode == .resting, let timer = machine.timerText() {
            bubble = .init(caption: "Timer", text: timer)
        } else if mode == .help {
            bubble = nil
        }
        if let errorText, now < errorText.until, [.resting, .asleep, .thinking, .moment, .conversing, .conversingPaused].contains(mode) {
            figure = RioCompanionPoseBuilder.figure(mode: .shrug, time: time, elapsed: elapsed, level: 0)
            bubble = .init(caption: nil, text: errorText.text)
        }
        if let noticeText, now < noticeText.until, ![.away, .sprint, .punch, .returning].contains(mode) {
            bubble = .init(caption: nil, text: noticeText.text)
        }
        return RioCompanionSnapshot(
            figure: figure, time: time, center: CGPoint(x: x, y: groundY),
            outfit: outfit, look: look, bubble: bubble, impact: impact, isHidden: mode == .away,
            showsRecordingBadge: machine.showsRecordingBadge(at: now)
        )
    }

    /// Picks the redraw rate for the current mode (called on events and by a light timer).
    func refreshTier(at now: TimeInterval) {
        if now - lastMoodCheck > 30 {
            lastMoodCheck = now
            mood = RioDayMood.current()
        }
        let mode = machine.mode(at: now)
        let next = RioRedrawPolicy.schedule(
            mode: mode,
            hasTimer: machine.timerText() != nil,
            hasErrorCard: errorText.map { now < $0.until } ?? false,
            gate: gate
        )
        if next != schedule { schedule = next }
    }

    /// The housekeeping timer period for the current schedule; nil means no timer is needed.
    func housekeepingInterval() -> TimeInterval? {
        if let interval = RioRedrawPolicy.housekeepingInterval(schedule: schedule, hasPendingExpiry: errorText != nil || noticeText != nil) {
            return interval
        }
        // A Dock run is moving the panel: keep the timer that restores it.
        return run != nil && !gate.isPaused ? 0.2 : nil
    }
}

struct RioCompanionRootView: View {
    @ObservedObject var model: RioCompanionModel

    var body: some View {
        switch model.schedule {
        case .paused:
            // One frame, then nothing: no timeline ticks while the bear cannot be seen.
            TimelineView(.explicit([Date()])) { _ in scene }
        case let .periodic(interval):
            TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: interval)) { _ in scene }
        case let .animation(minimumInterval):
            TimelineView(.animation(minimumInterval: minimumInterval)) { _ in scene }
        }
    }

    private var scene: some View {
        RioCompanionSceneView(
            snapshot: model.snapshot(at: RioCompanionClock.now),
            showsStop: model.showsStop,
            onStop: model.onStop
        )
    }
}
