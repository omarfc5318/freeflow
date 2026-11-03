import Foundation

/// The one place AppState gets its Rio action pipeline from. The lead rewrites this at merge
/// to build the real parser (with `InstalledAppCatalog.scan()`), executor and window controller.
enum RioActionsWiring {
    @MainActor static func makeCoordinator() -> RioActionCoordinator {
        RioActionCoordinator(
            parser: RioActionParser(installedApps: []),
            executor: RioActionExecutor(),
            smartResolver: nil
        )
    }
}
