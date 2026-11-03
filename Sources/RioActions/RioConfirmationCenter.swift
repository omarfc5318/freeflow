import Foundation

// STUB (lead): builder E replaces this file with the confirmation panel.
@MainActor final class RioConfirmationCenter: RioConfirming {
    static let shared = RioConfirmationCenter()
    func confirm(_ action: RioAction) async -> Bool { false }
}
