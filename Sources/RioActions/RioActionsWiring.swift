import AppKit
import Foundation

extension RioActionParser: RioActionParsing {}
extension RioActionExecutor: RioActionExecuting {}

/// The installed-app list Rio matches spoken names against. It is scanned once up front, then
/// again in the background after a failed match and whenever an app launches (throttled), so an
/// app installed while Rio runs is found without a restart and without blocking the main thread.
final class RioInstalledApps: @unchecked Sendable {
    static let shared = RioInstalledApps()
    /// The shortest gap between two background rescans.
    static let minimumRescanInterval: TimeInterval = 60

    private let lock = NSLock()
    private var cached: [InstalledApp]?
    private var isRescanning = false
    private var lastScanAt = Date.distantPast
    private var observer: NSObjectProtocol?

    private init() {}

    var apps: [InstalledApp] {
        lock.lock()
        if let cached { lock.unlock(); return cached }
        lock.unlock()
        let scanned = InstalledAppCatalog.scan()
        lock.lock()
        defer { lock.unlock() }
        cached = scanned
        lastScanAt = Date()
        return scanned
    }

    /// The list if it has been scanned already; never scans (safe on the main thread).
    var cachedApps: [InstalledApp]? {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    /// Scans in the background if nothing has been scanned yet.
    func prime() {
        lock.lock()
        let needsScan = cached == nil
        lock.unlock()
        if needsScan { rescanInBackground(now: .distantFuture) }
    }

    /// Starts watching for launches. Safe to call more than once.
    func startObserving() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.rescanInBackground() }
    }

    func rescanInBackground(now: Date = Date()) {
        lock.lock()
        guard !isRescanning, now.timeIntervalSince(lastScanAt) >= Self.minimumRescanInterval else {
            lock.unlock()
            return
        }
        isRescanning = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let scanned = InstalledAppCatalog.scan()
            guard let self else { return }
            self.lock.lock()
            self.cached = scanned
            self.lastScanAt = Date()
            self.isRescanning = false
            self.lock.unlock()
        }
    }
}

/// Parses with the current app list; a failed match asks for a background rescan so the next
/// command sees a newly installed app.
final class RioCatalogParser: RioActionParsing, @unchecked Sendable {
    private let apps: RioInstalledApps
    private let lock = NSLock()
    private var parser: RioActionParser?
    private var parsedAppNames: [String] = []

    init(apps: RioInstalledApps = .shared) { self.apps = apps }

    func parse(_ transcript: String) -> RioActionParse {
        let current = currentParser()
        let result = current.parse(transcript)
        if case .unknown = result { apps.rescanInBackground() }
        return result
    }

    private func currentParser() -> RioActionParser {
        let installed = apps.apps
        let names = installed.map(\.name)
        lock.lock()
        defer { lock.unlock() }
        if let parser, names == parsedAppNames { return parser }
        let fresh = RioActionParser(installedApps: installed)
        parser = fresh
        parsedAppNames = names
        return fresh
    }
}

/// The one place AppState gets its Rio action pipeline from: the real parser over the apps
/// installed on this Mac, the executor, and the Accessibility window controller.
enum RioActionsWiring {
    @MainActor static func makeCoordinator(
        companion: RioCompanionDirecting?,
        typeText: @escaping @MainActor (String) async -> Bool
    ) -> RioActionCoordinator {
        RioInstalledApps.shared.startObserving()
        return RioActionCoordinator(
            parser: RioCatalogParser(),
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
                    RioContextMemoryActionHandler.shared,
                    RioWritingActionHandler.shared,
                    RioAutomationActionHandler.shared,
                    RioFindActionHandler.shared,
                    RioOutsideActionHandler.shared,
                    RioMeetingActionHandler.shared,
                    RioSmartActionHandler.shared,
                ]
            ),
            smartResolver: RioSmartResolverFactory.make(),
            observer: RioUndoJournal.shared,
            confirmer: RioConfirmationCenter.shared
        )
    }
}
