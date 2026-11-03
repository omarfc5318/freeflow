import Combine
import Foundation

/// Shared state the corner bear observes (through AppState's `bindRioCompanionState`): the clock
/// he holds, whether it is ringing, a counter that makes him celebrate, and the help sign.
/// RioTimerCenter, RioHelpPanelController and RioUndoJournal write it; nothing here decides.
@MainActor final class RioCompanionCenter: ObservableObject {
    static let shared = RioCompanionCenter()
    /// Seconds left on the running timer. While ringing it stays non-nil (0), or the bear hides the clock.
    @Published var timerRemaining: TimeInterval?
    @Published var timerRinging = false
    /// Incremented to make the bear celebrate.
    @Published var celebrateCount = 0
    @Published var isHelpVisible = false

    func celebrate() { celebrateCount += 1 }
}
