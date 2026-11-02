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

// MARK: - Moment card (pill)

/// The pill bear peeking in with one paw on a white card that shows a short message:
/// words just learned, "Didn't catch that", "Undone", "Sent" or a milestone.
struct TeddyMomentView: View {
    let moment: TeddyMoment
    var outfit: TeddyOutfit = .hoodie

    var body: some View {
        HStack(spacing: -7) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                Canvas { graphics, size in
                    let scale = size.height / 32
                    graphics.scaleBy(x: scale, y: scale)
                    TeddyArt.drawMomentBear(
                        in: &graphics,
                        time: context.date.timeIntervalSinceReferenceDate,
                        moment: moment,
                        outfit: outfit
                    )
                }
            }
            .frame(width: 30 * 36 / 32, height: 30)
            .zIndex(1)

            VStack(alignment: .leading, spacing: 0) {
                Text(moment.caption)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.55))
                Text(moment.text)
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
        .accessibilityLabel("\(moment.caption): \(moment.text)")
    }
}

// MARK: - Full-body teddy (voice tricks)

/// The same bear, full body: a chubby teddy on two feet with fat arms. It is drawn at
/// `height * scale` (so a grown bear stays sharp instead of being scaled up as a bitmap) inside
/// a layout frame of `height`, and the canvas overflows that frame so raised arms and sparkles
/// are never clipped.
struct TeddyFigureView: View {
    let time: TimeInterval
    var action: TeddyPose.Action = .running
    var height: CGFloat = TeddyTripController.bearHeight
    var scale: CGFloat = 1
    var outfit: TeddyOutfit = .hoodie

    static let gridSize = CGSize(width: 40, height: 50)
    /// Grid points of room around the figure on every side.
    static let overflow: CGFloat = 16

    var body: some View {
        let drawHeight = height * scale
        let unit = drawHeight / Self.gridSize.height
        let room = Self.overflow * unit
        let drawWidth = drawHeight * Self.gridSize.width / Self.gridSize.height
        Color.clear
            .frame(width: height * Self.gridSize.width / Self.gridSize.height, height: height)
            .overlay {
                Canvas { graphics, _ in
                    graphics.translateBy(x: room, y: room)
                    graphics.scaleBy(x: unit, y: unit)
                    TeddyArt.drawTeddy(in: &graphics, time: time, action: action, outfit: outfit)
                }
                .frame(width: drawWidth + room * 2, height: drawHeight + room * 2)
                .shadow(color: .black.opacity(0.3), radius: 3 * max(1, scale), y: 1)
                .allowsHitTesting(false)
            }
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
            // Drawn at its real size and only mirrored for facing, so a grown bear stays sharp.
            TeddyFigureView(time: elapsed, action: pose.action, scale: pose.scale, outfit: outfit)
                .scaleEffect(x: pose.facesRight ? 1 : -1, y: 1)
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
