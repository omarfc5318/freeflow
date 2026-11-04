import Foundation

/// Carries out "organize my Downloads" and its undo. The plan, the names and the safety rules are
/// in `RioDownloadsPlan` (pure, tested); this reads the folder, moves files with the file
/// manager's own move (which refuses to overwrite) and keeps the move log "Rio, undo" reads.
///
/// The log lives in memory only: it names the user's files, so it is never written to disk or
/// logged, and it goes away when Rio quits (undo expires after 15 minutes anyway).
@MainActor final class RioDownloadsOrganizer {
    static let shared = RioDownloadsOrganizer()

    /// A plan the user confirmed is carried out as shown, as long as it is this fresh.
    private static let pendingLifetime: TimeInterval = 120

    private struct Run {
        var moves: [RioDownloadMove]
        var createdFolders: [String]
    }

    private let downloadsPath: String
    private let fileManager = FileManager.default
    private var runs: [Run] = []
    private var pending: (plan: RioDownloadsPlan, date: Date)?

    init(downloadsPath: String = NSHomeDirectory() + "/Downloads") {
        self.downloadsPath = downloadsPath
    }

    // MARK: Plan

    /// Reads the folder and plans the tidy-up. Touches nothing.
    func currentPlan(now: Date = Date()) -> RioDownloadsPlan {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey]
        let urls = (try? fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: downloadsPath, isDirectory: true), includingPropertiesForKeys: keys, options: []
        )) ?? []
        let entries = urls.compactMap { url -> RioDownloadEntry? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            // Links and aliases are left alone, the same as folders.
            let isFolderLike = values.isDirectory == true || values.isSymbolicLink == true || values.isAliasFile == true
            return RioDownloadEntry(name: url.lastPathComponent, isDirectory: isFolderLike, modified: values.contentModificationDate ?? now)
        }
        var existing: [String: Set<String>] = [:]
        for category in RioDownloadCategory.allCases {
            let names = (try? fileManager.contentsOfDirectory(atPath: downloadsPath + "/" + category.rawValue)) ?? []
            if !names.isEmpty { existing[category.rawValue] = Set(names.map { $0.lowercased() }) }
        }
        return RioDownloadsPlan.build(entries: entries, downloadsPath: downloadsPath, existing: existing, now: now)
    }

    /// What the confirmation panel shows: the whole plan. Remembered so "Tidy up" does exactly this.
    func confirmationContent(now: Date = Date()) -> RioConfirmationContent {
        let plan = currentPlan(now: now)
        pending = (plan, now)
        return plan.confirmationContent
    }

    // MARK: Organize

    func organize(now: Date = Date()) -> RioActionResult {
        var plan = currentPlan(now: now)
        if let pending, now.timeIntervalSince(pending.date) < Self.pendingLifetime { plan = pending.plan }
        pending = nil
        guard !plan.isEmpty else { return .done(summary: "Your Downloads are already tidy") }

        var run = Run(moves: [], createdFolders: [])
        var failed = 0
        for move in plan.moves {
            switch perform(move, now: now, createdFolders: &run.createdFolders) {
            case .moved(let done): run.moves.append(done)
            case .skipped: continue
            case .failed: failed += 1
            }
        }
        guard !run.moves.isEmpty else {
            return failed > 0 ? .failed(message: "I couldn't move your files") : .done(summary: "Your Downloads are already tidy")
        }
        runs.append(run)
        if runs.count > RioUndoPlan.stackLimit { runs.removeFirst() }
        RioUndoJournal.shared.noteCreated(.downloadsMoved(count: run.moves.count))
        var summary = RioDownloadsPlan(moves: run.moves).summary
        if failed > 0 { summary += ", \(failed) couldn't be moved" }
        return .done(summary: summary)
    }

    private enum Outcome {
        case moved(RioDownloadMove)
        case skipped
        case failed
    }

    /// Re-checks the move against the folder as it is now: the file is still a loose, settled file
    /// in Downloads, and its new name is free. Never overwrites.
    private func perform(_ move: RioDownloadMove, now: Date, createdFolders: inout [String]) -> Outcome {
        guard (move.from as NSString).deletingLastPathComponent == downloadsPath,
              let attributes = try? fileManager.attributesOfItem(atPath: move.from),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let modified = attributes[.modificationDate] as? Date,
              now.timeIntervalSince(modified) >= RioDownloadsPlan.recentWindow else { return .skipped }

        let folder = downloadsPath + "/" + move.category.rawValue
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: folder, isDirectory: &isDirectory) {
            guard (try? fileManager.createDirectory(atPath: folder, withIntermediateDirectories: false)) != nil else { return .failed }
            createdFolders.append(folder)
        } else if !isDirectory.boolValue {
            return .failed
        }
        let taken = Set(((try? fileManager.contentsOfDirectory(atPath: folder)) ?? []).map { $0.lowercased() })
        let target = folder + "/" + RioDownloadsPlan.uniqueName(move.newName, taken: taken)
        do {
            try fileManager.moveItem(atPath: move.from, toPath: target)
        } catch {
            return .failed
        }
        return .moved(RioDownloadMove(from: move.from, to: target, category: move.category))
    }

    // MARK: Undo

    /// Puts the most recent tidy-up back, newest move first, and removes the category folders Rio
    /// created if they are empty again.
    func undo() -> RioActionResult {
        guard let run = runs.popLast() else { return .failed(message: "There's nothing to put back") }
        let plan = RioDownloadsUndoPlan.inverse(of: run.moves, exists: { fileManager.fileExists(atPath: $0) })
        var restored = 0
        var failed = 0
        for move in plan.restores {
            do {
                try fileManager.moveItem(atPath: move.from, toPath: move.to)
                restored += 1
            } catch {
                failed += 1
            }
        }
        for folder in run.createdFolders where ((try? fileManager.contentsOfDirectory(atPath: folder)) ?? ["x"]).isEmpty {
            try? fileManager.removeItem(atPath: folder)
        }
        if restored == 0 && failed > 0 { return .failed(message: "I couldn't put your files back") }
        var summary = "Put \(restored) file\(restored == 1 ? "" : "s") back"
        if plan.missing > 0 { summary += ", \(plan.missing) had already moved" }
        return .done(summary: summary)
    }
}
