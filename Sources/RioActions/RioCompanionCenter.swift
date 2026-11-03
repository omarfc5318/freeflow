import Combine
import Foundation

// STUB (lead): builder G replaces this file. Shared state the corner bear (builder F) observes.
@MainActor final class RioCompanionCenter: ObservableObject {
    static let shared = RioCompanionCenter()
    @Published var timerRemaining: TimeInterval?
    @Published var timerRinging = false
    /// Incremented to make the bear celebrate.
    @Published var celebrateCount = 0
    @Published var isHelpVisible = false
}
