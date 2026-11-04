import Foundation

/// The owner's automations on disk: one JSON file in Application Support, mode 0600, in a 0700
/// folder. Commands and macro text can be personal, so nothing here is logged or sent anywhere.
final class RioAutomationStore {
    static let fileName = "automations.json"
    static let changedNotification = Notification.Name("RioAutomationStoreChanged")
    static let maxItems = 50

    enum RemoveOutcome: Equatable {
        case removed(String)
        case notFound
        case ambiguous([String])
    }

    static let shared = RioAutomationStore(directory: defaultDirectory())

    static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("\(AppName.displayName)/RioAutomation", isDirectory: true)
    }

    private(set) var data = RioAutomationData()
    private(set) var lastSaveFailed = false
    private(set) var recoveredCorruptFile: URL?
    private let directory: URL
    private let fileURL: URL

    init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(Self.fileName)
        data = load()
    }

    // MARK: Changes

    /// False when the list is full.
    @discardableResult
    func add(_ schedule: RioScheduledCommand) -> Bool {
        guard data.schedules.count < Self.maxItems else { return false }
        data.schedules.append(schedule)
        commit()
        return true
    }

    @discardableResult
    func add(_ rule: RioTriggerRule) -> Bool {
        guard data.triggers.count < Self.maxItems else { return false }
        data.triggers.append(rule)
        commit()
        return true
    }

    /// A macro with the same name (ignoring case) is replaced.
    func save(_ macro: RioMacro) {
        data.macros.removeAll { $0.name.lowercased() == macro.name.lowercased() }
        data.macros.append(macro)
        commit()
    }

    func replaceSchedules(_ schedules: [RioScheduledCommand]) {
        guard schedules != data.schedules else { return }
        data.schedules = schedules
        commit()
    }

    func markFired(triggerID: UUID, at date: Date) {
        guard let index = data.triggers.firstIndex(where: { $0.id == triggerID }) else { return }
        data.triggers[index].lastFired = date
        commit()
    }

    func addNote(_ note: String) {
        data.notes.append(note)
        data.notes = Array(data.notes.suffix(10))
        commit()
    }

    func clearNotes() {
        guard !data.notes.isEmpty else { return }
        data.notes = []
        commit()
    }

    func removeSchedule(id: UUID) { data.schedules.removeAll { $0.id == id }; commit() }
    func removeTrigger(id: UUID) { data.triggers.removeAll { $0.id == id }; commit() }
    func removeMacro(id: UUID) { data.macros.removeAll { $0.id == id }; commit() }

    func macro(named name: String) -> RioMacro? {
        let wanted = RioText.compact(name)
        guard !wanted.isEmpty else { return nil }
        if let exact = data.macros.first(where: { RioText.compact($0.name) == wanted }) { return exact }
        let partial = data.macros.filter { RioText.compact($0.name).contains(wanted) }
        return partial.count == 1 ? partial.first : nil
    }

    // MARK: Removing by spoken name

    private struct Candidate {
        let label: String
        let searchable: String
        let remove: () -> Void
    }

    /// "remove the Slack automation": an exact name wins, then a single partial match. Two partial
    /// matches remove nothing and are reported, so a vague name never deletes the wrong thing.
    func remove(matching name: String) -> RemoveOutcome {
        let wanted = RioText.compact(name)
        guard !wanted.isEmpty else { return .notFound }
        var candidates: [Candidate] = []
        for item in data.schedules {
            candidates.append(Candidate(label: RioAutomationText.label(item), searchable: item.command) { [self] in removeSchedule(id: item.id) })
        }
        for rule in data.triggers {
            let kindText: String
            switch rule.kind {
            case .displayConnected: kindText = "display monitor screen"
            case .audioOutput(let device): kindText = device
            case .wifi(let ssid): kindText = ssid
            }
            candidates.append(Candidate(label: RioAutomationText.label(rule), searchable: "\(rule.command) \(kindText)") { [self] in removeTrigger(id: rule.id) })
        }
        for macro in data.macros {
            candidates.append(Candidate(label: RioAutomationText.label(macro), searchable: macro.name) { [self] in removeMacro(id: macro.id) })
        }
        let exact = candidates.filter { RioText.compact($0.searchable) == wanted }
        let matches = exact.isEmpty ? candidates.filter { RioText.compact($0.searchable).contains(wanted) } : exact
        switch matches.count {
        case 0: return .notFound
        case 1:
            matches[0].remove()
            return .removed(matches[0].label)
        default: return .ambiguous(matches.map(\.label))
        }
    }

    // MARK: Disk

    private func commit() {
        save()
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    private func load() -> RioAutomationData {
        guard let raw = try? Data(contentsOf: fileURL) else { return RioAutomationData() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let loaded = try? decoder.decode(RioAutomationData.self, from: raw) { return loaded }
        // A damaged file is renamed, never overwritten, so it can be recovered by hand.
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let aside = directory.appendingPathComponent("automations.corrupt-\(stamp).json")
        if (try? FileManager.default.moveItem(at: fileURL, to: aside)) != nil { recoveredCorruptFile = aside }
        return RioAutomationData()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try encoder.encode(data).write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            lastSaveFailed = false
        } catch {
            lastSaveFailed = true
        }
    }
}
