import AppKit
import Combine
import Foundation
import os.log

private let scratchpadLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "Scratchpad")

struct ScratchpadNote: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var createdAt: Date
    var updatedAt: Date

    /// First non-empty line, for the notes list.
    var title: String {
        let firstLine = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return firstLine.map { String($0.prefix(60)) } ?? "New note"
    }
}

/// Voice notes the user dictates into the Scratchpad. Kept only on this Mac, in
/// `~/Library/Application Support/<app>/scratchpad.json`; never sent anywhere.
@MainActor
final class ScratchpadStore: ObservableObject {
    static let shared = ScratchpadStore()
    static let saveDelay: TimeInterval = 0.5

    @Published private(set) var notes: [ScratchpadNote] = []
    /// Set when the notes file exists but can't be read. Saving is then blocked so the
    /// unreadable file is never overwritten.
    @Published private(set) var loadError: String?
    private let fileURL: URL
    private var pendingSave: DispatchWorkItem?
    private var terminationObserver: NSObjectProtocol?

    init(fileURL: URL = ScratchpadStore.defaultFileURL()) {
        self.fileURL = fileURL
        loadNotes()
        // The debounced save would otherwise lose the last edit when the app quits.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    nonisolated static func defaultFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("\(AppName.displayName)/scratchpad.json")
    }

    @discardableResult
    func createNote() -> ScratchpadNote {
        let now = Date()
        let note = ScratchpadNote(text: "", createdAt: now, updatedAt: now)
        notes.insert(note, at: 0)
        scheduleSave()
        return note
    }

    func updateText(_ text: String, for id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].text != text else { return }
        notes[index].text = text
        notes[index].updatedAt = Date()
        scheduleSave()
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        scheduleSave()
    }

    /// Writes immediately, for example when the Scratchpad closes.
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard loadError == nil else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(notes).write(to: fileURL, options: .atomic)
        } catch {
            os_log(.error, log: scratchpadLog, "Saving scratchpad failed: %{public}@", error.localizedDescription)
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    /// A missing file means no notes yet. A file that exists but can't be read blocks saving;
    /// one that reads but doesn't decode is moved aside, so notes are never overwritten.
    private func loadNotes() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            os_log(.error, log: scratchpadLog, "Reading scratchpad failed: %{public}@", error.localizedDescription)
            loadError = "Your saved notes couldn't be opened, so new notes won't be saved until \(AppName.displayName) restarts. The notes file has not been changed."
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            notes = try decoder.decode([ScratchpadNote].self, from: data)
        } catch {
            os_log(.error, log: scratchpadLog, "Decoding scratchpad failed: %{public}@", error.localizedDescription)
            let backup = fileURL.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            do {
                try FileManager.default.moveItem(at: fileURL, to: backup)
            } catch {
                loadError = "Your saved notes couldn't be opened, so new notes won't be saved until \(AppName.displayName) restarts. The notes file has not been changed."
            }
        }
    }
}
