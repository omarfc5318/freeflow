import Foundation

// STUB (lead): builder L replaces this file.
@MainActor final class RioMemoryActionHandler: RioActionHandling {
    static let shared = RioMemoryActionHandler()
    func handle(_ action: RioAction, executor: RioActionExecuting) async -> RioActionResult? { nil }
}
