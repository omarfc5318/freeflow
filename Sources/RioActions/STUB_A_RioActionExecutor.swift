import Foundation

// Throwaway stand-in for Builder B's RioActionExecutor. The lead deletes this file at merge.
@MainActor final class RioActionExecutor: RioActionExecuting {
    init() {}
    func execute(_ action: RioAction) async -> RioActionResult {
        .failed(message: "Rio Actions aren't available in this build yet")
    }
}
