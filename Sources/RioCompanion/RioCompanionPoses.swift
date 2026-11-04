import CoreGraphics
import Foundation

/// One frame of the corner bear: a body pose plus the little effects around it. All numbers
/// are on the 40 x 50 body grid; angles in radians (0 hangs down, positive swings right).
struct RioCompanionFigure: Equatable {
    enum Effect: Equatable {
        case sleepZees
        case thoughtDots
        case micWaves(CGFloat)
        case listenWaves
        case exclaim(CGFloat)
        case question
        case sweat
        case sparkle
        case confetti
    }

    var pose: TeddyBodyPose
    var effects: [Effect] = []
    var facesRight = true
}

/// Turns the machine's mode into a pose. Pure: same inputs, same figure.
enum RioCompanionPoseBuilder {
    /// Where the body grid's floor is (soles of the shoes).
    static let groundY: CGFloat = 50
    /// Longer legs than the trick bear's, so the jeans and their turn-ups read clearly.
    static let legExtra: CGFloat = 2.1

    /// `elapsed` is seconds since the mode began (for the stretch and the "!" pop); `level` is
    /// the microphone level 0...1; `run` carries the seconds into a Dock run and its plan.
    static func figure(
        mode: RioCompanionMachine.Mode,
        time: TimeInterval,
        elapsed: TimeInterval,
        level: CGFloat,
        moment: TeddyMoment? = nil,
        run: (elapsed: TimeInterval, plan: RioDockRunPlan)? = nil,
        mood: RioDayMood = .day,
        grumpy: Bool = false,
        timerText: String? = nil
    ) -> RioCompanionFigure {
        var built = build(
            mode: mode, time: time, elapsed: elapsed, level: level, moment: moment, run: run,
            mood: mood, timerText: timerText
        )
        if grumpy, mode != .asleep, mode != .sprint, mode != .punch {
            built.pose.face.grumpy = true
            built.pose.face.eyes = .normal
            built.pose.face.raisedBrows = false
            built.pose.face.mouth = .natural
        }
        if mode != .asleep && mode != .waking {
            built.pose.leftLeg.length += legExtra
            built.pose.rightLeg.length += legExtra
        }
        return built
    }

    private static func build(
        mode: RioCompanionMachine.Mode,
        time: TimeInterval,
        elapsed: TimeInterval,
        level: CGFloat,
        moment: TeddyMoment?,
        run: (elapsed: TimeInterval, plan: RioDockRunPlan)?,
        mood: RioDayMood,
        timerText: String?
    ) -> RioCompanionFigure {
        let blinking = TeddyArt.isBlinking(at: time)
        switch mode {
        case .asleep:
            var figure = asleep(time: time)
            if RioDayMood.wearsNightcap(mood: mood) { figure.pose.headProp = .nightcap }
            return figure
        case .waking:
            var figure = waking(progress: min(1, elapsed / RioCompanionMachine.wakeDuration), time: time)
            if mood == .lateNight { figure.pose.headProp = .nightcap }
            return figure
        case .resting:
            return restingFigure(time: time, elapsed: elapsed, blinking: blinking, mood: mood, timerText: timerText)
        case .celebrate: return momentFigure(.milestone(""), time: time, blinking: blinking)
        case .help: return help(time: time, blinking: blinking)
        case .ringing: return ringing(time: time, text: timerText ?? "0:00")
        case .talking: return talking(time: time, level: level, blinking: blinking)
        case .thinking: return thinking(time: time, blinking: blinking)
        case .alert: return alert(time: time, elapsed: elapsed)
        case .happy: return happy(time: time)
        case .shrug: return shrug(time: time, blinking: blinking)
        case .moment: return momentFigure(moment, time: time, blinking: blinking)
        case .sprint: return sprint(time: time, speedLines: true)
        case .punch: return punch(run: run)
        case .returning: return jog(time: time)
        case .away: return RioCompanionFigure(pose: .standing)
        }
    }

    // MARK: Sleep and wake

    /// Slumped on the floor against the corner, legs splayed, head drooped, breathing slowly.
    static func asleep(time: TimeInterval) -> RioCompanionFigure {
        let breath = CGFloat(sin(time * 2.0 * .pi * 0.3))
        var pose = TeddyBodyPose.standing
        pose.bob = -6.4 + breath * 0.35
        pose.leanDegrees = -4
        pose.headTiltDegrees = -15 + Double(breath) * 1.2
        pose.leftLeg = .init(angle: -1.18, length: 6.0)
        pose.rightLeg = .init(angle: 1.18, length: 6.0)
        pose.leftArm = .init(angle: -0.55, length: 5.6)
        pose.rightArm = .init(angle: 0.5, length: 5.6)
        pose.face.eyesClosed = true
        pose.face.mouthOpen = max(0, breath) * 0.25
        return RioCompanionFigure(pose: pose, effects: [.sleepZees])
    }

    /// The ~0.3 s wake: sits up and stretches, arms high, mouth in a yawn, eyes blinking open.
    static func waking(progress: Double, time: TimeInterval) -> RioCompanionFigure {
        let p = CGFloat(min(max(progress, 0), 1))
        let ease = p * p * (3 - 2 * p)
        var pose = TeddyBodyPose.standing
        pose.bob = -6.4 * (1 - ease) + sin(p * .pi) * 1.2
        pose.leanDegrees = -4 * Double(1 - ease)
        pose.headTiltDegrees = -15 * Double(1 - ease)
        pose.leftLeg = .init(angle: -1.18 * Double(1 - ease), length: 6.0 + (0.5 + legExtra) * ease)
        pose.rightLeg = .init(angle: 1.18 * Double(1 - ease), length: 6.0 + (0.5 + legExtra) * ease)
        let lift = Double(sin(p * .pi))
        pose.leftArm = .init(angle: -0.55 - 2.2 * lift, length: 6.2)
        pose.rightArm = .init(angle: 0.5 + 2.2 * lift, length: 6.2)
        pose.face.eyesClosed = p < 0.4
        pose.face.mouth = p < 0.8 ? .oh : .natural
        pose.face.mouthOpen = 0
        return RioCompanionFigure(pose: pose)
    }

    /// Awake and idle: a clock if a timer runs, the morning mug, an occasional fidget.
    static func restingFigure(
        time: TimeInterval, elapsed: TimeInterval, blinking: Bool, mood: RioDayMood, timerText: String?
    ) -> RioCompanionFigure {
        var figure = resting(time: time, blinking: blinking)
        if let timerText {
            raiseRightPaw(&figure.pose, up: true)
            figure.pose.heldProp = .alarmClock(text: timerText, shaking: false)
        } else if RioDayMood.holdsCoffee(mood: mood, restingElapsed: elapsed) {
            raiseRightPaw(&figure.pose, up: true)
            figure.pose.heldProp = .coffeeMug
            figure.pose.face.mouth = .natural
        } else if let fidget = RioFidget.at(restingElapsed: elapsed) {
            applyFidget(&figure.pose, fidget.kind, progress: fidget.progress)
        }
        return figure
    }

    private static func applyFidget(_ pose: inout TeddyBodyPose, _ kind: RioFidget.Kind, progress p: Double) {
        let arc = sin(p * .pi)
        switch kind {
        case .yawn:
            pose.leftArm = .init(angle: -0.35 - 1.0 * arc, length: 6.4)
            pose.rightArm = .init(angle: 0.35 + 1.0 * arc, length: 6.4)
            pose.face.eyesClosed = arc > 0.3
            pose.face.mouth = arc > 0.2 ? .oh : .natural
            pose.headTiltDegrees = -4 * arc
        case .scratchEar:
            pose.rightArm = .init(angle: 2.2, length: 4.5)
            pose.rightForearm = .init(angle: 1.4 + sin(p * 40) * 0.18, length: 7)
            pose.headTiltDegrees = 5 * arc
            pose.face.eyes = .happy
        case .lookAround:
            pose.headTiltDegrees = sin(p * 2 * .pi * 1.5) * 8
            pose.face.eyes = .wide
        }
    }

    private static func raiseRightPaw(_ pose: inout TeddyBodyPose, up: Bool) {
        pose.rightArm = .init(angle: 1.45, length: 5.0)
        pose.rightForearm = .init(angle: 1.69, length: 5.0)
    }

    /// The timer is ringing: the clock shakes, he bounces and looks startled.
    static func ringing(time: TimeInterval, text: String) -> RioCompanionFigure {
        var pose = TeddyBodyPose.standing
        raiseRightPaw(&pose, up: true)
        pose.bob = CGFloat(abs(sin(time * 14))) * 2.6
        pose.leftArm = .init(angle: -0.9 - sin(time * 14) * 0.3, length: 6.2)
        pose.face.eyes = .wide
        pose.face.raisedBrows = true
        pose.face.mouth = .oh
        pose.heldProp = .alarmClock(text: text, shaking: true)
        return RioCompanionFigure(pose: pose)
    }

    /// Standing proud, holding the help sign up on a stick.
    static func help(time: TimeInterval, blinking: Bool) -> RioCompanionFigure {
        var pose = TeddyBodyPose.standing
        pose.rightArm = .init(angle: 2.3, length: 6.4)
        pose.bob = CGFloat(sin(time * 2)) * 0.25
        pose.face.eyes = .happy
        pose.face.mouth = .grin
        pose.heldProp = .helpSign
        return RioCompanionFigure(pose: pose)
    }

    static func resting(time: TimeInterval, blinking: Bool) -> RioCompanionFigure {
        var pose = TeddyBodyPose.standing
        pose.bob = CGFloat(sin(time * 2)) * 0.25
        pose.face.isBlinking = blinking
        return RioCompanionFigure(pose: pose)
    }

    // MARK: Talking and thinking

    /// Standing with the microphone at his mouth; the mouth follows the audio level.
    static func talking(time: TimeInterval, level: CGFloat, blinking: Bool) -> RioCompanionFigure {
        let clamped = min(max(level, 0), 1)
        let flutter = 0.7 + 0.3 * CGFloat(abs(sin(time * 11)))
        let open = clamped > 0.04 ? min(1, clamped * 1.6) * flutter : 0
        var pose = TeddyBodyPose.standing
        pose.bob = open * 0.7
        pose.leftArm = .init(angle: -0.45 - Double(open) * 0.25 * sin(time * 7), length: 6.4)
        raiseRightPawToFace(&pose)
        pose.heldProp = .microphone
        pose.face.mouthOpen = open
        pose.face.isBlinking = blinking
        return RioCompanionFigure(pose: pose, effects: [.micWaves(open)])
    }

    /// Looks up and away, paw at his cheek, thought dots.
    static func thinking(time: TimeInterval, blinking: Bool) -> RioCompanionFigure {
        var pose = TeddyBodyPose.standing
        pose.headTiltDegrees = 7
        raiseRightPawToFace(&pose)
        pose.face.isThinking = true
        pose.face.isBlinking = blinking
        return RioCompanionFigure(pose: pose, effects: [.thoughtDots])
    }

    /// Right arm bent up so the paw reaches his cheek (the microphone sits in it).
    private static func raiseRightPawToFace(_ pose: inout TeddyBodyPose) {
        pose.rightArm = .init(angle: 1.5, length: 4.5)
        pose.rightForearm = .init(angle: 2.14, length: 6.4)
    }

    // MARK: Action key and results

    /// Action key: ears pricked, eyes wide, brows up, a "!" pops, arms ready. Instant.
    static func alert(time: TimeInterval, elapsed: TimeInterval) -> RioCompanionFigure {
        var pose = TeddyBodyPose.standing
        pose.bob = 1.2 + CGFloat(abs(sin(time * 9))) * 0.4
        pose.leftArm = .init(angle: -0.95, length: 6.2)
        pose.rightArm = .init(angle: 0.95, length: 6.2)
        pose.face.eyes = .wide
        pose.face.raisedBrows = true
        pose.face.mouth = .oh
        pose.face.earLift = 2.0
        let pop = CGFloat(min(1, 0.4 + elapsed * 9))
        return RioCompanionFigure(pose: pose, effects: [.exclaim(pop), .listenWaves])
    }

    static func happy(time: TimeInterval) -> RioCompanionFigure {
        var pose = TeddyArt.thumbsUpPose()
        pose.face.mouth = .grin
        pose.face.eyes = .happy
        pose.face.winks = false
        pose.bob = CGFloat(abs(sin(time * 5))) * 0.8
        return RioCompanionFigure(pose: pose, effects: [.sparkle])
    }

    /// Both paws up, palms open, brows raised: "I couldn't do that".
    static func shrug(time: TimeInterval, blinking: Bool) -> RioCompanionFigure {
        let hover = CGFloat(sin(time * 5)) * 0.3
        var pose = TeddyBodyPose.standing
        pose.leftArm = .init(angle: -1.25, length: 4.4)
        pose.leftForearm = .init(angle: -1.6, length: 4.2)
        pose.rightArm = .init(angle: 1.25, length: 4.4)
        pose.rightForearm = .init(angle: 1.6, length: 4.2)
        pose.leftShoulderLift = 1 + hover
        pose.rightShoulderLift = 1 + hover
        pose.face.raisedBrows = true
        pose.face.mouth = .flat
        pose.face.isBlinking = blinking
        pose.headTiltDegrees = -5
        return RioCompanionFigure(pose: pose, effects: [.question])
    }

    // MARK: Moments

    static func momentFigure(_ moment: TeddyMoment?, time: TimeInterval, blinking: Bool) -> RioCompanionFigure {
        switch moment {
        case .didntCatchThat:
            return shrug(time: time, blinking: blinking)
        case .undone:
            var figure = thinking(time: time, blinking: blinking)
            figure.pose.face.isThinking = false
            figure.pose.face.eyes = .wide
            figure.pose.face.mouth = .oh
            figure.effects = [.sweat]
            return figure
        case .sent:
            return happy(time: time)
        case .milestone:
            var pose = TeddyArt.jumpingPose(time: time)
            pose.bob = CGFloat(abs(sin(time * 7))) * 3.2
            pose.face.eyes = .happy
            pose.face.mouth = .grin
            return RioCompanionFigure(pose: pose, effects: [.confetti, .sparkle])
        case .learned, .alreadyKnown, .none:
            var figure = happy(time: time)
            figure.pose.rightArm = .init(angle: 2.0, length: 6.2)
            figure.pose.rightPaw = .round
            figure.pose.showsSparkle = false
            figure.effects = []
            return figure
        }
    }

    // MARK: Dock run

    /// All-out sprint: leaning into it, arms pumping, speed lines. Faces right (the view mirrors).
    static func sprint(time: TimeInterval, speedLines: Bool) -> RioCompanionFigure {
        let stride = time * 30
        let swing = sin(stride) * 0.95
        var pose = TeddyBodyPose.standing
        pose.leanDegrees = 13
        pose.bob = CGFloat(abs(sin(stride))) * 2.6
        pose.leftLeg = .init(angle: swing * 0.8, length: 6.5 - CGFloat(max(0, swing)) * 3.4)
        pose.rightLeg = .init(angle: -swing * 0.8, length: 6.5 - CGFloat(max(0, -swing)) * 3.4)
        pose.leftArm = .init(angle: -swing - 0.5, length: 6.4)
        pose.rightArm = .init(angle: swing + 0.5, length: 6.4)
        pose.face.mouth = .grin
        pose.face.eyes = .wide
        pose.face.raisedBrows = true
        pose.showsSpeedLines = speedLines
        return RioCompanionFigure(pose: pose)
    }

    /// The leap and the fist: airborne, right arm straight out, left arm cocked back.
    static func punch(run: (elapsed: TimeInterval, plan: RioDockRunPlan)?) -> RioCompanionFigure {
        var pose = TeddyBodyPose.standing
        pose.leanDegrees = 12
        pose.bob = run.map { $0.plan.leapHeight(at: $0.elapsed) } ?? 8
        pose.leftLeg = .init(angle: -0.55, length: 4.6)
        pose.rightLeg = .init(angle: 0.7, length: 5.4)
        pose.leftArm = .init(angle: -2.5, length: 6.2)
        pose.rightArm = .init(angle: 1.5, length: 7.0)
        pose.rightPaw = .fist
        pose.face.mouth = .grin
        pose.face.eyes = .wide
        pose.face.raisedBrows = true
        pose.showsSpeedLines = true
        return RioCompanionFigure(pose: pose)
    }

    /// The easy jog back to the corner (faces left).
    static func jog(time: TimeInterval) -> RioCompanionFigure {
        var figure = sprint(time: time * 0.55, speedLines: false)
        figure.pose.leanDegrees = 6
        figure.pose.face.eyes = .normal
        figure.pose.face.raisedBrows = false
        figure.pose.face.mouth = .natural
        figure.pose.face.mouthOpen = 0.3
        figure.facesRight = false
        return figure
    }
}
