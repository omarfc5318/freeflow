import Foundation

// STUB (lead): builder G replaces this file.
@MainActor final class RioUndoJournal: RioActionObserving {
    static let shared = RioUndoJournal()
    func willExecute(_ action: RioAction) async {}
    func didExecute(_ action: RioAction, result: RioActionResult) {}
}
