import CoreGraphics
import Foundation

/// What the bear wears. Formal-style apps get the three-piece suit and flat cap; everything
/// else gets the purple hoodie, blue jeans and white sneakers.
enum TeddyOutfit: Equatable {
    case hoodie
    case suit

    static func forStyle(_ style: DictationStyle) -> TeddyOutfit {
        style == .formal ? .suit : .hoodie
    }
}

/// A full-body pose as plain numbers, on the 40 x 50 body grid (y grows downward).
/// Angles are radians; a limb angle of 0 hangs straight down and positive swings it
/// towards the viewer's right. "Left" and "right" are the viewer's left and right.
struct TeddyBodyPose: Equatable {
    enum Side: Equatable {
        case front
        case back
    }

    enum PawShape: Equatable {
        case round
        case thumbsUp
    }

    struct Limb: Equatable {
        var angle: Double
        var length: CGFloat
    }

    struct Face: Equatable {
        /// 0 closed ... 1 wide open.
        var mouthOpen: CGFloat = 0
        var isBlinking = false
        /// Closes the viewer's-left eye.
        var winks = false
    }

    var side: Side = .front
    /// Whole-body tilt about the feet, in degrees; positive leans towards the viewer's right.
    var leanDegrees: Double = 0
    /// Lift of the whole body in grid points (positive is up).
    var bob: CGFloat = 0
    /// Sideways shift of the hips and tummy in grid points; with `feetPlanted` the feet stay put.
    var hipShift: CGFloat = 0
    var feetPlanted = false
    /// Head tilt in degrees, positive towards the viewer's right.
    var headTiltDegrees: Double = 0
    var leftArm = Limb(angle: -0.35, length: 6.4)
    var rightArm = Limb(angle: 0.35, length: 6.4)
    var leftLeg = Limb(angle: 0, length: 6.5)
    var rightLeg = Limb(angle: 0, length: 6.5)
    var rightPaw: PawShape = .round
    var face = Face()
    var showsSpeedLines = false
    var showsSparkle = false

    // MARK: Dance detail (all default to "no change", so existing poses look the same)

    /// Elbows: when set, the arm above is the upper arm and this is the forearm. Its `angle`
    /// is the bend RELATIVE to the upper arm (forearm direction = upper arm angle + bend, same
    /// convention: positive turns towards the viewer's right); `length` is the forearm length.
    /// nil draws the arm as one straight piece, as before.
    var leftForearm: Limb?
    var rightForearm: Limb?
    /// Raises (positive) or drops (negative) one shoulder, in grid points, independently of the body.
    var leftShoulderLift: CGFloat = 0
    var rightShoulderLift: CGFloat = 0
    /// Fake torso turn, -1...1: positive turns the chest towards the viewer's right (the body
    /// narrows and the tummy patch, collar and face features slide that way).
    var twist: Double = 0
    /// Moves a foot sideways along the ground (grid points, positive = viewer's right) and lifts
    /// it (positive = up, e.g. a toe tap). Used with `feetPlanted`, where the leg is drawn from
    /// the hip to the foot.
    var leftFootShift: CGFloat = 0
    var rightFootShift: CGFloat = 0
    var leftFootLift: CGFloat = 0
    var rightFootLift: CGFloat = 0

    static let standing = TeddyBodyPose()
}

/// Short moments the pill shows between dictations, each with the bear in a matching pose
/// and a white card of text.
enum TeddyMoment: Equatable {
    /// Words just learned from the user's corrections.
    case learned(String)
    /// A tap of the shortcut or a recording with nothing said.
    case didntCatchThat
    /// Undo Last Dictation removed the text.
    case undone
    /// The "press enter" voice command sent the message.
    case sent
    /// A usage milestone, e.g. "1,000 words".
    case milestone(String)

    var caption: String {
        switch self {
        case .learned: return "Learned"
        case .didntCatchThat: return "Hmm"
        case .undone: return "Oops"
        case .sent: return "Pressed Enter"
        case .milestone: return "Milestone"
        }
    }

    var text: String {
        switch self {
        case let .learned(label): return label
        case .didntCatchThat: return "Didn't catch that"
        case .undone: return "Undone"
        case .sent: return "Sent"
        case let .milestone(label): return label
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .learned: return 2.5
        case .didntCatchThat: return 1.8
        case .undone: return 1.6
        case .sent: return 1.4
        case .milestone: return 3.5
        }
    }
}
