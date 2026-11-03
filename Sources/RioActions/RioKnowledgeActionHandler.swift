import AppKit
import Foundation

/// Runs Builder H's actions: find and open files (Spotlight), calendar (EventKit), clipboard
/// history. Returns nil for anything else so the executor offers it to the next handler.
///
/// Privacy: file names, event titles and clipboard text are shown and spoken but never logged
/// or stored; the clipboard history is in memory only (`RioClipboardHistory`).
@MainActor
final class RioKnowledgeActionHandler: RioActionHandling {
    static let shared = RioKnowledgeActionHandler()

    let search: RioFileSearch
    let calendarService: RioCalendarService
    let clipboard: RioClipboardHistory

    init(search: RioFileSearch? = nil, calendarService: RioCalendarService? = nil, clipboard: RioClipboardHistory? = nil) {
        self.search = search ?? .shared
        self.calendarService = calendarService ?? .shared
        self.clipboard = clipboard ?? .shared
    }

    func handle(_ action: RioAction, executor: RioActionExecuting) async -> RioActionResult? {
        switch action {
        case .openFile(let query): return await findFile(query, reveal: false)
        case .revealFile(let query): return await findFile(query, reveal: true)
        case .calendarAgenda(let range): return await agenda(range)
        case .joinNextMeeting: return await joinNextMeeting()
        case .createEvent(let title, let start, let duration): return await createEvent(title: title, start: start, durationMinutes: duration)
        case .clipboard(let command): return await run(command)
        default: return nil
        }
    }

    // MARK: Files

    private func findFile(_ spoken: String, reveal: Bool) async -> RioActionResult {
        let home = NSHomeDirectory()
        if let folder = RioWellKnownFolder.match(spoken: spoken) {
            return openFolder(folder, home: home)
        }
        let query = RioFileQuery.parse(spoken)
        guard !query.isEmpty else { return .failed(message: "I didn't catch which file you meant") }

        var ranked: [RioFileCandidate] = []
        if let predicate = RioSpotlightPredicates.name(for: query) {
            let found = await search.search(predicate)
            ranked = RioFileRanker.rank(found, query: query, home: home, now: Date())
        }
        if ranked.isEmpty, let predicate = RioSpotlightPredicates.content(for: query) {
            let found = await search.search(predicate, timeout: 5)
            ranked = RioFileRanker.rankContentMatches(found, query: query, home: home, now: Date())
        }
        guard let best = ranked.first else {
            return .failed(message: "I couldn't find \(spoken) on this Mac")
        }
        return present(best, reveal: reveal)
    }

    private func openFolder(_ folder: RioWellKnownFolder, home: String) -> RioActionResult {
        let path = folder.path(home: home)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failed(message: "I couldn't find \(folder.displayName)")
        }
        guard NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true)) else {
            return .failed(message: "I couldn't open \(folder.displayName)")
        }
        return .done(summary: "Opened \(folder.displayName)")
    }

    private func present(_ file: RioFileCandidate, reveal: Bool) -> RioActionResult {
        let url = URL(fileURLWithPath: file.path, isDirectory: file.isDirectory)
        let name = url.lastPathComponent
        let executable = FileManager.default.isExecutableFile(atPath: file.path)
        let risky = RioFileRanker.isRiskyToOpen(path: file.path, isDirectory: file.isDirectory, isExecutable: executable)
        if reveal || risky {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return .done(summary: risky && !reveal ? "That looks like a program, so I showed \(name) in Finder" : "Showing \(name) in Finder")
        }
        guard NSWorkspace.shared.open(url) else { return .failed(message: "I couldn't open \(name)") }
        return .done(summary: "Opened \(name)")
    }

    // MARK: Clipboard

    private func run(_ command: ClipboardCommand) async -> RioActionResult {
        clipboard.start()
        switch command {
        case .readCurrent:
            let snapshot = clipboard.readCurrent()
            let text = snapshot?.text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            let item = text.map { RioClipboardItem(text: $0, date: Date()) }
            return .done(summary: RioClipboardSpeech.current(
                item, hasConcealed: snapshot?.isConcealed ?? false, hasNonText: snapshot?.hasNonText ?? false
            ))
        case .showHistory:
            return .done(summary: RioClipboardSpeech.history(clipboard.buffer))
        case .pasteRecent(let hint):
            guard let item = RioClipboardMatcher.match(hint: hint, in: clipboard.buffer) else {
                return .failed(message: Self.notFoundMessage(hint: hint))
            }
            do {
                try await clipboard.paste(item.text)
            } catch RioClipboardHistory.PasteError.needsAccessibility {
                return .failed(message: "I need Accessibility permission to paste. You can allow it in System Settings.")
            } catch {
                return .failed(message: "I couldn't press paste")
            }
            return .done(summary: Self.pastedSummary(item.kind))
        }
    }

    private static func notFoundMessage(hint: String?) -> String {
        switch hint?.lowercased() {
        case "link": return "I don't see a link in your recent copies"
        case "email": return "I don't see an email address in your recent copies"
        case "phone": return "I don't see a phone number in your recent copies"
        case "address": return "I don't see an address in your recent copies"
        case "number": return "I don't see a number in your recent copies"
        case nil, "": return "Your clipboard history is empty"
        default: return "I couldn't find that in your recent copies"
        }
    }

    private static func pastedSummary(_ kind: RioClipboardKind) -> String {
        switch kind {
        case .link: return "Pasted the link"
        case .email: return "Pasted the email address"
        case .phone: return "Pasted the phone number"
        case .address: return "Pasted the address"
        case .number: return "Pasted the number"
        case .text: return "Pasted your earlier copy"
        }
    }
}
