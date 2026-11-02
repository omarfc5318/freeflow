import AppKit
import SwiftUI

// MARK: - Talking bear (recording pill)

/// A black-and-white cutout bear speaking into a microphone. Its mouth opens with the
/// microphone level and sound arcs ripple out of the mic; while the dictation is being
/// turned into text it looks up and "thinks".
struct TalkingBearView: View {
    enum Mood {
        case idle
        case talking
        case thinking
    }

    let mood: Mood
    var audioLevel: Float = 0
    var height: CGFloat = 28
    var isEditing = false
    var outfit: TeddyOutfit = .hoodie

    /// Drawing space; the art is laid out on a 44 x 32 grid and scaled to `height`.
    static let gridSize = CGSize(width: 44, height: 32)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { graphics, size in
                let scale = size.height / Self.gridSize.height
                graphics.scaleBy(x: scale, y: scale)
                TeddyArt.drawTalkingBear(
                    in: &graphics,
                    time: time,
                    level: mood == .talking ? CGFloat(min(max(audioLevel, 0), 1)) : 0,
                    mood: mood,
                    isEditing: isEditing,
                    outfit: outfit
                )
            }
        }
        .frame(width: height * Self.gridSize.width / Self.gridSize.height, height: height)
        .accessibilityLabel(mood == .thinking ? "Transcribing" : "Recording")
    }
}

// MARK: - Learned-word card (pill)

/// The pill bear peeking in with one paw on a white card that shows the words it just
/// learned from the user's corrections.
struct LearnedWordView: View {
    let label: String

    var body: some View {
        HStack(spacing: -7) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                Canvas { graphics, size in
                    let scale = size.height / 32
                    graphics.scaleBy(x: scale, y: scale)
                    TeddyArt.drawBearHoldingCard(in: &graphics, time: context.date.timeIntervalSinceReferenceDate)
                }
            }
            .frame(width: 30 * 36 / 32, height: 30)
            .zIndex(1)

            VStack(alignment: .leading, spacing: 0) {
                Text("Learned")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.55))
                Text(label)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black)
                    .lineLimit(1)
            }
            .padding(.leading, 11)
            .padding(.trailing, 8)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(.white))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Learned \(label)")
    }
}

// MARK: - Full-body teddy (voice tricks)

/// The same bear, full body: a chubby teddy on two feet with fat arms.
struct TeddyFigureView: View {
    let time: TimeInterval
    var action: TeddyPose.Action = .running
    var height: CGFloat = TeddyTripController.bearHeight
    var outfit: TeddyOutfit = .hoodie

    static let gridSize = CGSize(width: 40, height: 50)

    var body: some View {
        Canvas { graphics, size in
            let scale = size.height / Self.gridSize.height
            graphics.scaleBy(x: scale, y: scale)
            TeddyArt.drawTeddy(in: &graphics, time: time, action: action, outfit: outfit)
        }
        .frame(width: height * Self.gridSize.width / Self.gridSize.height, height: height)
        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
    }
}

/// A whole trick, driven by wall-clock time.
struct TeddyTripView: View {
    let start: Date
    let routine: TeddyRoutine
    var outfit: TeddyOutfit = .hoodie

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
            let elapsed = context.date.timeIntervalSince(start)
            let pose = routine.pose(at: elapsed)
            TeddyFigureView(time: elapsed, action: pose.action, outfit: outfit)
                .scaleEffect(x: pose.facesRight ? pose.scale : -pose.scale, y: pose.scale)
                .position(pose.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
    }
}

/// Shows a trick in a click-through window above everything. `stop()` removes it at once
/// (for example when a new dictation starts) without calling `onFinished`.
/// Main thread only.
final class TeddyTripController {
    static let bearHeight: CGFloat = 64
    static var margin: CGFloat { bearHeight / 2 + 8 }

    private var panel: NSPanel?
    private var finishWorkItem: DispatchWorkItem?
    private let beat = TeddyBeat()
    private var beatWorkItems: [DispatchWorkItem] = []

    var isRunning: Bool { panel != nil }

    /// `home` is the bear's centre in the pill, measured from the top left of `screen`.
    func start(
        _ trick: TeddyTrick,
        on screen: NSScreen,
        home: CGPoint,
        outfit: TeddyOutfit = .hoodie,
        onFinished: @escaping () -> Void
    ) {
        stop()
        let frame = screen.frame
        let routine = TeddyRoutine.make(trick, screenSize: frame.size, home: home, margin: Self.margin)

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.setFrame(frame, display: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: TeddyTripView(start: Date(), routine: routine, outfit: outfit))
        panel.orderFrontRegardless()
        self.panel = panel

        let finish = DispatchWorkItem { [weak self] in
            self?.stop()
            onFinished()
        }
        finishWorkItem = finish
        DispatchQueue.main.asyncAfter(deadline: .now() + routine.duration, execute: finish)

        if let window = routine.beatWindow {
            let begin = DispatchWorkItem { [weak self] in self?.beat.start() }
            let end = DispatchWorkItem { [weak self] in self?.beat.stop() }
            beatWorkItems = [begin, end]
            DispatchQueue.main.asyncAfter(deadline: .now() + window.lowerBound, execute: begin)
            DispatchQueue.main.asyncAfter(deadline: .now() + window.upperBound, execute: end)
        }
    }

    func stop() {
        beatWorkItems.forEach { $0.cancel() }
        beatWorkItems = []
        beat.stop()
        finishWorkItem?.cancel()
        finishWorkItem = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
