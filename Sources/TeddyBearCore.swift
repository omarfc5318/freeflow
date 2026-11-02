import CoreGraphics
import Foundation

/// The "Teddy go crazy" voice trigger. Only a dictation that is nothing but the phrase
/// counts, so a sentence that happens to contain it is still typed normally.
enum TeddyCommand {
    static func isGoCrazy(_ transcript: String) -> Bool {
        let words = transcript.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        guard words.count == 3 else { return false }
        return ["teddy", "teddie", "tedi"].contains(words[0])
            && ["go", "goes"].contains(words[1])
            && words[2] == "crazy"
    }
}

/// The bear's trip: it jumps out of the recording pill, lands below it, runs one loop
/// around the screen (right, down, left, up, then right again back to where it landed)
/// and jumps back into the pill. It stays upright and faces the way it is running.
/// Coordinates have their origin at the top left of the screen.
enum TeddyLap {
    static let runPointsPerSecond: CGFloat = 850
    static let jumpSeconds: TimeInterval = 0.55
    static let jumpHeight: CGFloat = 70
    /// How far below the bear's spot in the pill it lands.
    static let landingDrop: CGFloat = 110

    struct Track: Equatable {
        let home: CGPoint
        let landing: CGPoint
        let left: CGFloat
        let right: CGFloat
        let top: CGFloat
        let bottom: CGFloat
    }

    struct Pose: Equatable {
        let center: CGPoint
        let facesRight: Bool
        let isJumping: Bool
        /// The bear is drawn at half size in the pill and grows to full size as it jumps out.
        var scale: CGFloat = 1
    }

    static let homeScale: CGFloat = 0.5

    /// `home` is the bear's centre in the pill; `margin` keeps the running bear's centre
    /// that far from the screen edges.
    static func track(screenSize: CGSize, home: CGPoint, margin: CGFloat) -> Track {
        let left = margin
        let right = max(left, screenSize.width - margin)
        let bottom = max(margin, screenSize.height - margin)
        let top = min(max(home.y + landingDrop, margin), bottom)
        return Track(
            home: home,
            landing: CGPoint(x: min(max(home.x, left), right), y: top),
            left: left, right: right, top: top, bottom: bottom
        )
    }

    static func duration(of track: Track) -> TimeInterval {
        jumpSeconds * 2 + TimeInterval(loopLength(track) / runPointsPerSecond)
    }

    static func pose(at elapsed: TimeInterval, on track: Track) -> Pose {
        let runSeconds = TimeInterval(loopLength(track) / runPointsPerSecond)
        if elapsed < jumpSeconds {
            return jump(from: track.home, to: track.landing, fraction: max(0, elapsed) / jumpSeconds, leavingHome: true)
        }
        let running = elapsed - jumpSeconds
        if running < runSeconds {
            return run(distance: CGFloat(running) * runPointsPerSecond, on: track)
        }
        let back = min(1, (running - runSeconds) / jumpSeconds)
        return jump(from: track.landing, to: track.home, fraction: back, leavingHome: false)
    }

    private static func jump(from start: CGPoint, to end: CGPoint, fraction: Double, leavingHome: Bool) -> Pose {
        let f = CGFloat(min(max(fraction, 0), 1))
        let arc = jumpHeight * 4 * f * (1 - f)
        let growth = leavingHome ? f : 1 - f
        return Pose(
            center: CGPoint(x: start.x + (end.x - start.x) * f, y: start.y + (end.y - start.y) * f - arc),
            facesRight: true,
            isJumping: f < 1,
            scale: homeScale + (1 - homeScale) * growth
        )
    }

    private struct Leg {
        let start: CGPoint
        let end: CGPoint
        let facesRight: Bool
        var length: CGFloat { hypot(end.x - start.x, end.y - start.y) }
    }

    private static func legs(_ track: Track) -> [Leg] {
        let topRight = CGPoint(x: track.right, y: track.top)
        let bottomRight = CGPoint(x: track.right, y: track.bottom)
        let bottomLeft = CGPoint(x: track.left, y: track.bottom)
        let topLeft = CGPoint(x: track.left, y: track.top)
        return [
            Leg(start: track.landing, end: topRight, facesRight: true),
            Leg(start: topRight, end: bottomRight, facesRight: true),
            Leg(start: bottomRight, end: bottomLeft, facesRight: false),
            Leg(start: bottomLeft, end: topLeft, facesRight: false),
            Leg(start: topLeft, end: track.landing, facesRight: true),
        ]
    }

    private static func loopLength(_ track: Track) -> CGFloat {
        legs(track).reduce(0) { $0 + $1.length }
    }

    private static func run(distance: CGFloat, on track: Track) -> Pose {
        var remaining = distance
        for leg in legs(track) {
            guard remaining > leg.length else {
                let f = leg.length > 0 ? remaining / leg.length : 0
                return Pose(
                    center: CGPoint(x: leg.start.x + (leg.end.x - leg.start.x) * f, y: leg.start.y + (leg.end.y - leg.start.y) * f),
                    facesRight: leg.facesRight,
                    isJumping: false
                )
            }
            remaining -= leg.length
        }
        return Pose(center: track.landing, facesRight: true, isJumping: false)
    }
}
