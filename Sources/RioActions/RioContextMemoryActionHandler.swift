import Foundation

/// Runs `.searchHistory`: a local search over the owner's own dictations, answered as "On Monday
/// you said: ...". Follow-ups need no handler (they are rewritten into ordinary actions at parse
/// time). Privacy: the search runs entirely in memory over the history the app already holds; the
/// text is never logged or sent anywhere. Returns nil for every other action.
@MainActor
final class RioContextMemoryActionHandler: RioActionHandling {
    static let shared = RioContextMemoryActionHandler()

    /// The owner's dictation history, newest first. The app sets this at launch, for example
    /// `{ appState.pipelineHistory }`. Until it is set, search says it has nothing to look at.
    var historyProvider: (@MainActor () -> [PipelineHistoryItem])?

    func handle(_ action: RioAction, executor: RioActionExecuting) async -> RioActionResult? {
        guard case .searchHistory(let query) = action else { return nil }
        guard let historyProvider else { return .failed(message: "I can't look through your dictations yet.") }
        let entries = Self.entries(from: historyProvider())
        guard let hit = RioHistorySearch.rank(query: query, entries: entries, limit: 1).first else {
            return .failed(message: "I couldn't find anything you said about \(query).")
        }
        return .done(summary: RioHistorySearch.answer(for: hit))
    }

    /// Dictations only (never Rio commands or edit commands), cleaned text first.
    static func entries(from items: [PipelineHistoryItem]) -> [RioHistoryEntry] {
        items.compactMap { item in
            guard item.intent == .dictation else { return nil }
            let cleaned = item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = cleaned.isEmpty ? item.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines) : cleaned
            return text.isEmpty ? nil : RioHistoryEntry(id: item.id, date: item.timestamp, text: text)
        }
    }

    /// Hands the style profile the owner's dictations (call after each dictation and at launch).
    func refreshStyleProfile(from items: [PipelineHistoryItem]) {
        RioStyleProfileProvider.shared.refresh(entries: Self.entries(from: items))
    }
}
