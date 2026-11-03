import AppKit
import Foundation

enum RioMemorySettings {
    static let enabledKey = "rioMemoryEnabled"

    /// On unless the user turned it off in Settings.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
}

/// Runs builder L's actions: memory (remember, recall, forget), Apple Notes, email drafts and the
/// instant calculator. Returns nil for every other action so the next handler gets its turn.
///
/// Privacy: memories live in `RioMemoryStore` (local file, owner-only) and are never logged or
/// sent anywhere. Email text and note text are passed to Mail and Notes as AppleScript
/// parameters or URL-encoded values, and are not stored by Rio.
@MainActor
final class RioMemoryActionHandler: RioActionHandling {
    static let shared = RioMemoryActionHandler()

    private let store: RioMemoryStore

    init(store: RioMemoryStore = .shared) {
        self.store = store
    }

    func handle(_ action: RioAction, executor: RioActionExecuting) async -> RioActionResult? {
        switch action {
        case .remember(let fact): return remember(fact)
        case .recall(let query): return recall(query)
        case .forget(let query): return forget(query)
        case .addNote(let text): return RioNotesWriter.append(text)
        case .draftEmail(let to, let subject, let body): return await RioEmailDrafter.draft(to: to, subject: subject, body: body)
        case .calculate(let expression): return calculate(expression)
        default: return nil
        }
    }

    // MARK: Memory

    private static let memoryOff = "Memory is turned off in Settings."

    private func remember(_ fact: String) -> RioActionResult {
        guard RioMemorySettings.isEnabled else { return .failed(message: Self.memoryOff) }
        let outcome = store.add(fact)
        if outcome != .rejected, outcome != .alreadyKnown, store.lastSaveFailed {
            return .failed(message: "I couldn't save that to this Mac's disk.")
        }
        switch outcome {
        case .added: return .done(summary: "Got it, I'll remember that")
        case .updated: return .done(summary: "Updated, I'll remember the new one")
        case .alreadyKnown: return .done(summary: "I already know that")
        case .rejected: return .failed(message: "I couldn't remember that. Keep it to one short sentence.")
        }
    }

    private func recall(_ query: String) -> RioActionResult {
        guard RioMemorySettings.isEnabled else { return .failed(message: Self.memoryOff) }
        let wantsEverything = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch store.recall(query) {
        case .facts(let facts):
            if wantsEverything {
                return .done(summary: RioMemoryVoice.overview(facts.map(RioMemoryVoice.secondPerson)))
            }
            return .done(summary: RioMemoryVoice.recallSentence(facts))
        case .none:
            if wantsEverything { return .done(summary: "I don't remember anything yet. Say remember, then what you want me to keep.") }
            return .done(summary: "I don't have anything saved about \(query). Say remember, then the fact, to teach me.")
        }
    }

    private func forget(_ query: String) -> RioActionResult {
        guard RioMemorySettings.isEnabled else { return .failed(message: Self.memoryOff) }
        switch store.forget(query) {
        case .removed:
            return store.lastSaveFailed
                ? .failed(message: "I couldn't update this Mac's disk, so that memory may still be there.")
                : .done(summary: "Okay, I've forgotten that")
        case .ambiguous(let facts):
            let shown = facts.prefix(3).map(RioMemoryVoice.secondPerson).joined(separator: "; ")
            return .failed(message: "I know a few things about that: \(shown). Say which one to forget.")
        case .notFound:
            return .failed(message: "I don't have anything saved about \(query).")
        }
    }

    // MARK: Maths

    private func calculate(_ expression: String) -> RioActionResult {
        guard let answer = RioCalculator.evaluate(expression) else {
            return .failed(message: "I couldn't work that out")
        }
        return .done(summary: answer.sentence)
    }
}
