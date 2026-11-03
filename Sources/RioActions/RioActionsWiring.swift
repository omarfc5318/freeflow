import Foundation

extension RioActionParser: RioActionParsing {}
extension RioActionExecutor: RioActionExecuting {}

/// The one place AppState gets its Rio action pipeline from: the real parser over the apps
/// installed on this Mac, the executor, and the Accessibility window controller.
enum RioActionsWiring {
    @MainActor static func makeCoordinator(
        companion: RioCompanionDirecting?,
        typeText: @escaping @MainActor (String) async -> Bool
    ) -> RioActionCoordinator {
        RioActionCoordinator(
            parser: RioActionParser(installedApps: InstalledAppCatalog.scan()),
            executor: RioActionExecutor(
                windowController: WindowController(),
                companion: companion,
                typeText: typeText,
                handlers: [
                    RioVoiceActionHandler.shared,
                    RioKnowledgeActionHandler.shared,
                    RioSystemActionHandler.shared,
                    RioScreenActionHandler.shared,
                    RioTaskActionHandler.shared,
                    RioMemoryActionHandler.shared,
                    RioTranslatorActionHandler.shared,
                    RioSmartActionHandler.shared,
                ]
            ),
            smartResolver: RioSmartResolverFactory.make(),
            observer: RioUndoJournal.shared,
            confirmer: RioConfirmationCenter.shared
        )
    }
}
