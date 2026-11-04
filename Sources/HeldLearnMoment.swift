import Foundation

/// The "Learned" bear sign held back while a dictation is starting or running, shown right after
/// that dictation closes. It belongs to that dictation only: if the dictation ends any way other
/// than a plain paste (a tap, silence, an error, a cancel, an action, Enter-to-send), the sign is
/// dropped soon after instead of popping up after some later dictation. The latest sign wins.
struct HeldLearnMoment {
    /// How long after its dictation closed (or after it was held, when no dictation followed)
    /// the sign may still be shown.
    static let expirySeconds: TimeInterval = 10

    private enum Stage: Equatable {
        case held(at: TimeInterval)
        case running
        case ended(at: TimeInterval)
    }

    private var moment: TeddyMoment?
    private var stage: Stage = .running

    var isHolding: Bool { moment != nil }

    mutating func hold(_ newMoment: TeddyMoment, now: TimeInterval) {
        moment = newMoment
        stage = .held(at: now)
    }

    /// A sign held just before a dictation starts belongs to it only if the dictation starts
    /// this soon (it is held while the microphone opens).
    static let heldBeforeStartSeconds: TimeInterval = 2

    /// A dictation started (the microphone or the transcription is busy). A sign held long
    /// before it (a start that never happened) is dropped rather than carried into this one.
    mutating func sessionStarted(now: TimeInterval) {
        guard case .held(let at) = stage else { return }
        if now - at <= Self.heldBeforeStartSeconds {
            stage = .running
        } else {
            moment = nil
        }
    }

    /// The dictation closed. Only the first close after the sign was held counts.
    mutating func sessionEnded(now: TimeInterval) {
        guard moment != nil else { return }
        switch stage {
        case .running, .held: stage = .ended(at: now)
        case .ended: break
        }
    }

    /// The sign to show now, or nil (none, or too old). Always empties the hold.
    mutating func take(now: TimeInterval) -> TeddyMoment? {
        defer { moment = nil }
        guard let moment else { return nil }
        switch stage {
        case .running: return moment
        case .held(let at), .ended(let at): return now - at <= Self.expirySeconds ? moment : nil
        }
    }

    /// Drops the sign if its dictation has already closed without showing it.
    mutating func dropIfSessionEnded() {
        if case .ended = stage { moment = nil }
    }
}
