import AppKit
import Foundation

/// Spotlight search over the home folder through NSMetadataQuery. The index is Spotlight's own:
/// Rio never walks the disk or reads file contents itself, and results only ever pass through
/// `RioFileRanker`, which drops hidden items, ~/Library and app bundles.
@MainActor
final class RioFileSearch {
    static let shared = RioFileSearch()

    private static let maxResults = 600
    private var running: Run?

    static var homePath: String { NSHomeDirectory() }

    /// Searches the home folder and iCloud Drive. Returns at most `maxResults` newest-used
    /// results, or whatever was gathered when `timeout` passes.
    func search(_ predicate: NSPredicate, timeout: TimeInterval = 4) async -> [RioFileCandidate] {
        running?.cancel()
        let run = Run(predicate: predicate, scopes: Self.scopes(), maxResults: Self.maxResults)
        running = run
        let results = await run.start(timeout: timeout)
        if running === run { running = nil }
        return results
    }

    private static func scopes() -> [String] {
        [homePath, RioWellKnownFolder.iCloudDrive.path(home: homePath)]
    }

    /// One query and its single answer.
    @MainActor
    private final class Run {
        private let query = NSMetadataQuery()
        private let maxResults: Int
        private var continuation: CheckedContinuation<[RioFileCandidate], Never>?
        private var observer: NSObjectProtocol?

        init(predicate: NSPredicate, scopes: [String], maxResults: Int) {
            self.maxResults = maxResults
            query.predicate = predicate
            query.searchScopes = scopes
            query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)]
        }

        func start(timeout: TimeInterval) async -> [RioFileCandidate] {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                observer = NotificationCenter.default.addObserver(
                    forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.finish() }
                }
                if !query.start() {
                    finish()
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    MainActor.assumeIsolated { self?.finish() }
                }
            }
        }

        func cancel() { finish() }

        private func finish() {
            guard let continuation else { return }
            self.continuation = nil
            query.disableUpdates()
            let count = min(query.resultCount, maxResults)
            var candidates: [RioFileCandidate] = []
            candidates.reserveCapacity(count)
            for index in 0..<count {
                guard let item = query.result(at: index) as? NSMetadataItem,
                      let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                let tree = item.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String] ?? []
                candidates.append(RioFileCandidate(
                    path: path,
                    lastUsed: item.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date,
                    modified: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
                    isDirectory: tree.contains("public.folder")
                ))
            }
            query.stop()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            continuation.resume(returning: candidates)
        }
    }
}
