import CoreGraphics
import Foundation

/// Voice tricks for the bear. Only a dictation that is nothing but a trick phrase counts,
/// so a sentence that happens to contain one is still typed normally.
enum TeddyTrick: Equatable {
    /// "Teddy go crazy": one lap around the screen.
    case goCrazy
    /// "Teddy show me ur shi jelly": run to the middle, wiggle, thumbs up, run back.
    case wiggle
}

enum TeddyCommand {
    static func trick(in transcript: String) -> TeddyTrick? {
        // Apostrophes are dropped first so "you're" stays one word.
        let words = transcript.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        guard let name = words.first, ["teddy", "teddie", "tedi"].contains(name) else { return nil }
        let rest = Array(words.dropFirst())
        if rest.count == 2, ["go", "goes"].contains(rest[0]), rest[1] == "crazy" {
            return .goCrazy
        }
        return isShowMeJelly(rest) ? .wiggle : nil
    }

    /// "show me ur shi jelly". Speech-to-text spells it many ways ("your shy jelly",
    /// "you're she jelly", "your shit jelly"), so any spelling of "ur" counts and the word
    /// before "jelly" can be anything, or missing.
    private static func isShowMeJelly(_ words: [String]) -> Bool {
        let yours = ["ur", "your", "youre", "you", "yo", "ya", "yer"]
        guard (4...5).contains(words.count),
              words[0] == "show", words[1] == "me",
              yours.contains(words[2]),
              let last = words.last, ["jelly", "jellies"].contains(last) else { return false }
        return true
    }

    static func isGoCrazy(_ transcript: String) -> Bool {
        trick(in: transcript) == .goCrazy
    }
}

// MARK: - Poses and routines

/// What the bear is doing at one moment of a trick. Coordinates have their origin at the
/// top left of the screen.
struct TeddyPose: Equatable {
    enum Action: Equatable {
        case standing
        case jumping
        case running
        /// Turning on the spot; `progress` 0...1. Halfway through, the view switches sides.
        case turning(towardBack: Bool, progress: Double)
        /// Seen from behind, hips swaying; `phase` counts wiggles (1.0 = one full sway).
        case wiggling(phase: Double)
        case thumbsUp
    }

    let center: CGPoint
    var facesRight = true
    var action: Action
    /// The bear is drawn at half size in the pill and grows to full size as it jumps out.
    var scale: CGFloat = 1

    var isJumping: Bool { action == .jumping }
}

/// A trick as a timeline of steps, each mapping its own 0...1 progress to a pose.
struct TeddyRoutine {
    struct Step {
        let duration: TimeInterval
        let pose: (Double) -> TeddyPose
    }

    let steps: [Step]

    var duration: TimeInterval { steps.reduce(0) { $0 + $1.duration } }

    func pose(at elapsed: TimeInterval) -> TeddyPose {
        var remaining = max(0, elapsed)
        for step in steps {
            if remaining < step.duration {
                return step.pose(step.duration > 0 ? remaining / step.duration : 1)
            }
            remaining -= step.duration
        }
        return steps.last?.pose(1) ?? TeddyPose(center: .zero, action: .standing)
    }

    // MARK: Building blocks

    static let runPointsPerSecond: CGFloat = 850
    static let jumpSeconds: TimeInterval = 0.55
    static let jumpHeight: CGFloat = 70
    static let homeScale: CGFloat = 0.5
    /// How far below the bear's spot in the pill it lands.
    static let landingDrop: CGFloat = 110

    static func jump(from start: CGPoint, to end: CGPoint, leavingHome: Bool) -> Step {
        Step(duration: jumpSeconds) { fraction in
            let f = CGFloat(min(max(fraction, 0), 1))
            let arc = jumpHeight * 4 * f * (1 - f)
            let growth = leavingHome ? f : 1 - f
            return TeddyPose(
                center: CGPoint(x: start.x + (end.x - start.x) * f, y: start.y + (end.y - start.y) * f - arc),
                action: f < 1 ? .jumping : .standing,
                scale: homeScale + (1 - homeScale) * growth
            )
        }
    }

    /// Facing follows the horizontal direction unless given (straight up or down keeps right).
    static func run(from start: CGPoint, to end: CGPoint, facesRight: Bool? = nil) -> Step {
        let length = hypot(end.x - start.x, end.y - start.y)
        let facing = facesRight ?? (end.x >= start.x)
        return Step(duration: TimeInterval(length / runPointsPerSecond)) { fraction in
            let f = CGFloat(min(max(fraction, 0), 1))
            return TeddyPose(
                center: CGPoint(x: start.x + (end.x - start.x) * f, y: start.y + (end.y - start.y) * f),
                facesRight: facing,
                action: .running
            )
        }
    }

    static func hold(at point: CGPoint, seconds: TimeInterval, action: @escaping (Double) -> TeddyPose.Action) -> Step {
        Step(duration: seconds) { fraction in
            TeddyPose(center: point, action: action(min(max(fraction, 0), 1)))
        }
    }

    /// Where the bear lands below the pill, kept inside the screen.
    static func landing(for home: CGPoint, screenSize: CGSize, margin: CGFloat) -> CGPoint {
        let bottom = max(margin, screenSize.height - margin)
        return CGPoint(
            x: min(max(home.x, margin), max(margin, screenSize.width - margin)),
            y: min(max(home.y + landingDrop, margin), bottom)
        )
    }

    static func make(_ trick: TeddyTrick, screenSize: CGSize, home: CGPoint, margin: CGFloat) -> TeddyRoutine {
        switch trick {
        case .goCrazy:
            return TeddyLap.routine(on: TeddyLap.track(screenSize: screenSize, home: home, margin: margin))
        case .wiggle:
            return TeddyWiggle.routine(screenSize: screenSize, home: home, margin: margin)
        }
    }
}

// MARK: - Go crazy

/// The bear jumps out of the pill, lands below it, runs one loop around the screen
/// (right, down, left, up, then right again back to where it landed) and jumps back in.
enum TeddyLap {
    struct Track: Equatable {
        let home: CGPoint
        let landing: CGPoint
        let left: CGFloat
        let right: CGFloat
        let top: CGFloat
        let bottom: CGFloat
    }

    /// `home` is the bear's centre in the pill; `margin` keeps the running bear's centre
    /// that far from the screen edges.
    static func track(screenSize: CGSize, home: CGPoint, margin: CGFloat) -> Track {
        let landing = TeddyRoutine.landing(for: home, screenSize: screenSize, margin: margin)
        return Track(
            home: home,
            landing: landing,
            left: margin,
            right: max(margin, screenSize.width - margin),
            top: landing.y,
            bottom: max(margin, screenSize.height - margin)
        )
    }

    static func routine(on track: Track) -> TeddyRoutine {
        let topRight = CGPoint(x: track.right, y: track.top)
        let bottomRight = CGPoint(x: track.right, y: track.bottom)
        let bottomLeft = CGPoint(x: track.left, y: track.bottom)
        let topLeft = CGPoint(x: track.left, y: track.top)
        return TeddyRoutine(steps: [
            TeddyRoutine.jump(from: track.home, to: track.landing, leavingHome: true),
            TeddyRoutine.run(from: track.landing, to: topRight, facesRight: true),
            TeddyRoutine.run(from: topRight, to: bottomRight, facesRight: true),
            TeddyRoutine.run(from: bottomRight, to: bottomLeft, facesRight: false),
            TeddyRoutine.run(from: bottomLeft, to: topLeft, facesRight: false),
            TeddyRoutine.run(from: topLeft, to: track.landing, facesRight: true),
            TeddyRoutine.jump(from: track.landing, to: track.home, leavingHome: false),
        ])
    }

    static func duration(of track: Track) -> TimeInterval {
        routine(on: track).duration
    }

    static func pose(at elapsed: TimeInterval, on track: Track) -> TeddyPose {
        routine(on: track).pose(at: elapsed)
    }
}

// MARK: - Wiggle

/// Out of the pill, run to the middle of the screen, turn around, wiggle, turn back,
/// thumbs up, run back and jump into the pill.
enum TeddyWiggle {
    static let turnSeconds: TimeInterval = 0.3
    static let wiggleCount = 4
    static let secondsPerWiggle: TimeInterval = 0.5
    static let thumbsUpSeconds: TimeInterval = 1.3

    static func routine(screenSize: CGSize, home: CGPoint, margin: CGFloat) -> TeddyRoutine {
        let landing = TeddyRoutine.landing(for: home, screenSize: screenSize, margin: margin)
        let middle = CGPoint(x: screenSize.width / 2, y: max(landing.y, screenSize.height / 2))
        let wiggles = Double(wiggleCount)
        return TeddyRoutine(steps: [
            TeddyRoutine.jump(from: home, to: landing, leavingHome: true),
            TeddyRoutine.run(from: landing, to: middle),
            TeddyRoutine.hold(at: middle, seconds: turnSeconds) { .turning(towardBack: true, progress: $0) },
            TeddyRoutine.hold(at: middle, seconds: secondsPerWiggle * wiggles) { .wiggling(phase: $0 * wiggles) },
            TeddyRoutine.hold(at: middle, seconds: turnSeconds) { .turning(towardBack: false, progress: $0) },
            TeddyRoutine.hold(at: middle, seconds: thumbsUpSeconds) { _ in .thumbsUp },
            TeddyRoutine.run(from: middle, to: landing),
            TeddyRoutine.jump(from: landing, to: home, leavingHome: false),
        ])
    }
}
