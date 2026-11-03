import SwiftUI

/// Live state behind the corner bear's panel. Main actor only. The machine decides what he is
/// doing; this turns that into a drawable snapshot each frame.
@MainActor
final class RioCompanionModel: ObservableObject {
    /// How often the panel redraws: slow while asleep, smooth while he acts.
    @Published private(set) var frameInterval: TimeInterval = RioCompanionModel.sleepyInterval
    @Published var showsStop = false

    static let sleepyInterval: TimeInterval = 0.25

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
    var homeX: CGFloat = 28
    var groundY: CGFloat = RioCompanionMetrics.cornerPanelSize.height - RioCompanionLayout.groundInset
    var run: Run?
    var errorText: (text: String, until: TimeInterval)?
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
        if let errorText, now < errorText.until, [.resting, .asleep, .thinking, .moment].contains(mode) {
            figure = RioCompanionPoseBuilder.figure(mode: .shrug, time: time, elapsed: elapsed, level: 0)
            bubble = .init(caption: nil, text: errorText.text)
        }
        return RioCompanionSnapshot(
            figure: figure, time: time, center: CGPoint(x: x, y: groundY),
            outfit: outfit, look: look, bubble: bubble, impact: impact, isHidden: mode == .away
        )
    }

    /// Picks the redraw rate for the current mode (called on events and by a light timer).
    func refreshTier(at now: TimeInterval) {
        if now - lastMoodCheck > 30 {
            lastMoodCheck = now
            mood = RioDayMood.current()
        }
        let mode = machine.mode(at: now)
        let interval: TimeInterval
        switch mode {
        case .asleep: interval = Self.sleepyInterval
        case .away: interval = 0.5
        case .resting: interval = 0.1
        case .sprint, .punch, .returning: interval = 1.0 / 60
        default: interval = 1.0 / 30
        }
        if let errorText, now < errorText.until, interval > 1.0 / 30 { frameInterval = 1.0 / 30; return }
        if abs(interval - frameInterval) > 0.0001 { frameInterval = interval }
    }

    var needsTimer: Bool { frameInterval < Self.sleepyInterval - 0.001 || run != nil || errorText != nil }
}

struct RioCompanionRootView: View {
    @ObservedObject var model: RioCompanionModel

    var body: some View {
        TimelineView(.animation(minimumInterval: model.frameInterval)) { _ in
            RioCompanionSceneView(
                snapshot: model.snapshot(at: RioCompanionClock.now),
                showsStop: model.showsStop,
                onStop: model.onStop
            )
        }
    }
}
