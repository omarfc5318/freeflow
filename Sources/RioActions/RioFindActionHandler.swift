import AppKit
import Foundation

/// Runs `.findThing`, `.organizeDownloads` and `.copyTextFromScreen` (builder Q).
///
/// Privacy: files, Messages attachments and screen text are the user's own and sensitive. They
/// are read for one command, held in memory, and never logged or stored. Screen text goes to the
/// clipboard only; Vision runs on this Mac.
@MainActor final class RioFindActionHandler: RioActionHandling {
    static let shared = RioFindActionHandler()

    /// With no time window, look back this far in Messages, Downloads and Mail.
    private static let defaultLookbackDays = 60
    private static let panelRows = 6

    private let organizer: RioDownloadsOrganizer
    private let panel = RioFindResultsPanel.shared

    init(organizer: RioDownloadsOrganizer? = nil) {
        self.organizer = organizer ?? RioDownloadsOrganizer.shared
    }

    func handle(_ action: RioAction, executor: RioActionExecuting) async -> RioActionResult? {
        switch action {
        case .findThing(let query): return await find(query)
        case .organizeDownloads: return organizer.organize()
        case .copyTextFromScreen: return await copyTextFromScreen()
        default: return nil
        }
    }

    // MARK: Find that thing

    private func find(_ spoken: String) async -> RioActionResult {
        let now = Date()
        let query = RioFindQuery.parse(spoken, now: now)
        guard query.isSearchable else {
            return .failed(message: "Tell me who sent it, when, or what kind of file")
        }

        var notes: [String] = []
        var handles: [String] = []
        if let person = query.person {
            if let found = await RioFindSources.handles(for: person) { handles = found } else { notes.append(RioFindSpeech.contactsNote) }
        }

        let since = query.interval?.start
            ?? Calendar.current.date(byAdding: .day, value: -Self.defaultLookbackDays, to: now) ?? now
        var found: [RioFindResult] = []
        switch RioFindSources.messagesAccess() {
        case .granted: found += await RioFindSources.messageAttachments(since: since)
        case .needsFullDiskAccess: notes.append(RioFindSpeech.fullDiskAccessNote)
        case .absent: break
        }
        found += await RioFindSources.downloadFolders(since: since)
        found += await RioFindSources.spotlight(for: query)

        let home = RioFindSources.home
        let ranked = RioFindRanker.rank(found, query: query, personHandles: handles, home: home, now: now)
        if query.wantsLink { notes.append(RioFindSpeech.linkNote) }
        guard !ranked.isEmpty else {
            return .failed(message: (["I couldn't find that"] + notes).joined(separator: ". "))
        }

        let calendar = Calendar.current
        let rows = ranked.prefix(Self.panelRows).map { result in
            RioFindResultsPanel.Row(id: result.path, name: result.name, detail: Self.detail(of: result, now: now, calendar: calendar))
        }
        panel.show(rows: Array(rows)) { [weak self] path in self?.present(path: path) }

        let spoken = ([RioFindSpeech.summary(ranked, now: now, calendar: calendar)] + notes).joined(separator: ". ")
        RioPersonality.registerVerbatim(spoken)
        return .done(summary: spoken)
    }

    private static func detail(of result: RioFindResult, now: Date, calendar: Calendar) -> String {
        var parts: [String] = []
        if let date = result.date { parts.append(RioFindSpeech.dayPhrase(date, now: now, calendar: calendar)) }
        parts.append(result.sources.sorted().first(where: { $0 != .spotlight })?.phrase ?? RioFindSource.spotlight.phrase)
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Opens a document, or shows anything else in Finder: H's allowlist (`isRiskyToOpen`), plus
    /// the presentable check so only found paths are ever touched.
    private func present(path: String) {
        guard RioFindRanker.isPresentable(path: path, home: RioFindSources.home) else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return }
        let url = URL(fileURLWithPath: path, isDirectory: isDirectory.boolValue)
        let risky = RioFileRanker.isRiskyToOpen(
            path: path, isDirectory: isDirectory.boolValue, isExecutable: FileManager.default.isExecutableFile(atPath: path)
        )
        if risky {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Copy text from the screen

    private enum Text {
        static let needsScreenRecording = "I need Screen Recording permission to read your screen. You can allow it in System Settings, Privacy and Security."
        static let noWindow = "I couldn't find a window to read."
        static let sensitive = "I won't read that window."
        static let captureFailed = "I couldn't capture your screen just now."
        static let readFailed = "I couldn't read the text on your screen."
        static let noText = "I couldn't find any text on the screen."
    }

    private func copyTextFromScreen() async -> RioActionResult {
        let image: Data
        do {
            image = try RioScreenCapture.capture(maxDimension: 3200, quality: 0.85)
        } catch RioScreenCapture.Failure.noPermission {
            return .failed(message: Text.needsScreenRecording)
        } catch RioScreenCapture.Failure.noWindow {
            return .failed(message: Text.noWindow)
        } catch RioScreenCapture.Failure.sensitiveWindow {
            return .failed(message: Text.sensitive)
        } catch {
            return .failed(message: Text.captureFailed)
        }
        let lines: [RioOCRLine]
        do {
            lines = try await Task.detached(priority: .userInitiated) { try RioScreenOCR.recognize(imageData: image) }.value
        } catch {
            return .failed(message: Text.readFailed)
        }
        let joined = RioOCRText.join(lines)
        guard joined.lineCount > 0 else { return .failed(message: Text.noText) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(joined.text, forType: .string) else { return .failed(message: Text.readFailed) }
        return .done(summary: RioOCRText.summary(lineCount: joined.lineCount))
    }
}
