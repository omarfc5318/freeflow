import Foundation

// STUB (lead): builder M replaces this file.
/// Turns a non-English spoken command (Arabic first) into English before Rio parses it.
@MainActor final class RioCommandTranslator {
    static let shared = RioCommandTranslator()
    /// Returns `transcript` unchanged when it's already English or can't be translated.
    func englishCommand(from transcript: String) async -> String { transcript }
}
