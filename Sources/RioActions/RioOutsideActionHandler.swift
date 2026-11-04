import Foundation

// STUB (lead): builder S replaces this file.
@MainActor final class RioOutsideActionHandler: RioActionHandling {
    static let shared = RioOutsideActionHandler()
    func handle(_ action: RioAction, executor: RioActionExecuting) async -> RioActionResult? { nil }
}
