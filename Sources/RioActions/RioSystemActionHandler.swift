import Foundation

// STUB (lead): builder I replaces this file.
@MainActor final class RioSystemActionHandler: RioActionHandling {
    static let shared = RioSystemActionHandler()
    func handle(_ action: RioAction, executor: RioActionExecuting) async -> RioActionResult? { nil }
}
