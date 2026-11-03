import Foundation

/// One finger on the trackpad. x and y are normalized 0...1 across the pad.
struct TouchPoint: Equatable {
    let id: Int
    let x: Float
    let y: Float
    /// Contact size as the driver reports it; palms are much larger than fingertips.
    let size: Float
}

/// Every contact present at one instant. An empty `touches` means the pad is clear.
struct TouchFrame: Equatable {
    let timestamp: TimeInterval
    let touches: [TouchPoint]
}

/// Decides whether a stream of touch frames from ONE trackpad was a three-finger tap.
/// Pure and deterministic: no clock, no device. A tap is exactly three fingers that land
/// together, barely move, and all lift within a short time; swipes, rests, drags, other
/// finger counts and palms are never taps. It fires when the last finger lifts.
struct TapGestureDetector {
    struct Configuration {
        var requiredFingers = 3
        /// First finger down to third finger down.
        var maxLandingSpread: TimeInterval = 0.12
        /// First finger down to last finger up.
        var maxContactDuration: TimeInterval = 0.30
        /// How far any finger may wander, as a fraction of the pad. A swipe goes far beyond.
        var maxMovement: Float = 0.035
        /// Contacts bigger than this are palms. A generous cap: fingertips never reach it.
        var maxTouchSize: Float = 3.0
        /// Minimum time between two taps.
        var debounce: TimeInterval = 0.6

        static let standard = Configuration()
    }

    private struct Gesture {
        let start: TimeInterval
        var origins: [Int: (x: Float, y: Float)] = [:]
        var threeFingersAt: TimeInterval?
        var isValid = true
    }

    private let configuration: Configuration
    private var gesture: Gesture?
    private var lastTap: TimeInterval?

    init(configuration: Configuration = .standard) {
        self.configuration = configuration
    }

    /// Forgets any gesture in flight (device went away, monitor stopped).
    mutating func reset() {
        gesture = nil
        lastTap = nil
    }

    /// Feeds the next frame; true exactly once per detected tap, on the frame that clears the pad.
    mutating func process(_ frame: TouchFrame) -> Bool {
        if frame.touches.isEmpty {
            return finish(at: frame.timestamp)
        }
        var current = gesture ?? Gesture(start: frame.timestamp)
        if frame.timestamp < current.start { current = Gesture(start: frame.timestamp) }
        absorb(frame, into: &current)
        gesture = current
        return false
    }

    private mutating func finish(at time: TimeInterval) -> Bool {
        defer { gesture = nil }
        guard let finished = gesture, finished.isValid,
              finished.origins.count == configuration.requiredFingers,
              let landed = finished.threeFingersAt,
              landed - finished.start <= configuration.maxLandingSpread,
              time - finished.start <= configuration.maxContactDuration
        else { return false }
        if let lastTap, time - lastTap < configuration.debounce { return false }
        lastTap = time
        return true
    }

    private func absorb(_ frame: TouchFrame, into gesture: inout Gesture) {
        guard gesture.isValid else { return }
        if frame.timestamp - gesture.start > configuration.maxContactDuration
            || frame.touches.count > configuration.requiredFingers {
            gesture.isValid = false
            return
        }
        for touch in frame.touches {
            if touch.size > configuration.maxTouchSize { gesture.isValid = false; return }
            guard let origin = gesture.origins[touch.id] else {
                gesture.origins[touch.id] = (touch.x, touch.y)
                if gesture.origins.count > configuration.requiredFingers { gesture.isValid = false; return }
                continue
            }
            let dx = touch.x - origin.x, dy = touch.y - origin.y
            if (dx * dx + dy * dy).squareRoot() > configuration.maxMovement { gesture.isValid = false; return }
        }
        if frame.touches.count == configuration.requiredFingers, gesture.threeFingersAt == nil {
            gesture.threeFingersAt = frame.timestamp
        }
    }
}
