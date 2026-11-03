import Foundation

struct RioMemoryFact: Codable, Equatable, Identifiable {
    let id: UUID
    var text: String
    let created: Date
}

enum RioMemoryAdd: Equatable {
    case added
    case updated(previous: String)
    case alreadyKnown
    case rejected
}

enum RioMemoryRecall: Equatable {
    case none
    case facts([String])
}

enum RioMemoryForget: Equatable {
    case removed(String)
    case ambiguous([String])
    case notFound
}

/// Rio's memory: short facts the user asked it to keep. Personal data: stored only on this Mac,
/// in one JSON file (owner read/write only), never logged, never sent anywhere. The matched fact
/// is the only thing that ever leaves this file, and only to be shown and spoken.
final class RioMemoryStore: @unchecked Sendable {
    static let maxFacts = 500
    static let maxFactLength = 500
    static let recallLimit = 3
    private static let fileName = "memory.json"

    private struct FileContents: Codable {
        var version = 1
        var facts: [RioMemoryFact] = []
    }

    private let fileURL: URL
    private let directory: URL
    private let now: () -> Date
    private let lock = NSLock()
    private var stored: [RioMemoryFact] = []
    private(set) var lastSaveFailed = false

    static let shared = RioMemoryStore(directory: defaultDirectory())

    static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("\(AppName.displayName)/RioMemory", isDirectory: true)
    }

    init(directory: URL, now: @escaping () -> Date = { Date() }) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(Self.fileName)
        self.now = now
        stored = load()
    }

    var facts: [RioMemoryFact] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    // MARK: Changing memory

    func add(_ raw: String) -> RioMemoryAdd {
        let text = RioText.collapseWhitespace(raw)
        guard !text.isEmpty, text.count <= Self.maxFactLength else { return .rejected }
        lock.lock(); defer { lock.unlock() }
        if stored.contains(where: { $0.text.lowercased() == text.lowercased() }) { return .alreadyKnown }
        if let subject = RioMemoryMatcher.subject(of: text),
           let index = stored.firstIndex(where: { RioMemoryMatcher.subject(of: $0.text) == subject }) {
            let previous = stored[index].text
            stored[index].text = text
            save()
            return .updated(previous: previous)
        }
        stored.append(RioMemoryFact(id: UUID(), text: text, created: now()))
        if stored.count > Self.maxFacts { stored.removeFirst(stored.count - Self.maxFacts) }
        save()
        return .added
    }

    func recall(_ query: String) -> RioMemoryRecall {
        lock.lock(); defer { lock.unlock() }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return stored.isEmpty ? .none : .facts(stored.map(\.text)) }
        let matches = RioMemoryMatcher.best(query: trimmed, facts: stored.map(\.text), limit: Self.recallLimit)
        return matches.isEmpty ? .none : .facts(matches.map { stored[$0].text })
    }

    func forget(_ query: String) -> RioMemoryForget {
        lock.lock(); defer { lock.unlock() }
        let matches = RioMemoryMatcher.best(query: query, facts: stored.map(\.text), limit: Self.recallLimit)
        guard let first = matches.first else { return .notFound }
        guard matches.count == 1 else { return .ambiguous(matches.map { stored[$0].text }) }
        let removed = stored.remove(at: first).text
        save()
        return .removed(removed)
    }

    func remove(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        stored.removeAll { $0.id == id }
        save()
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        stored = []
        save()
    }

    // MARK: Disk

    private func load() -> [RioMemoryFact] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A damaged file loads as empty; the next change writes a fresh one.
        return (try? decoder.decode(FileContents.self, from: data))?.facts ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            let data = try encoder.encode(FileContents(facts: stored))
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            lastSaveFailed = false
        } catch {
            lastSaveFailed = true
        }
    }
}
