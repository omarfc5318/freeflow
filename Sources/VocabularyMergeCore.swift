import Foundation

/// Merges the Settings vocabulary editor's buffer with words learned while it was open.
enum VocabularyMergeCore {
    /// Splits vocabulary text on the separators the settings field documents.
    static func entries(in text: String) -> [String] {
        text
            .split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The text to store when the editor commits.
    /// - `buffer`: what the editor holds now.
    /// - `base`: the vocabulary the buffer was last synced from.
    /// - `current`: the vocabulary stored right now.
    /// An untouched buffer changes nothing; an edited one keeps the user's edit and also keeps
    /// every entry added to `current` since `base` (words learned while the field was focused).
    static func commit(buffer: String, base: String, current: String) -> String {
        let trimmedBuffer = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBuffer == base.trimmingCharacters(in: .whitespacesAndNewlines) { return current }

        let baseKeys = Set(entries(in: base).map { $0.lowercased() })
        var seen = Set(entries(in: buffer).map { $0.lowercased() })
        let added = entries(in: current).filter { entry in
            let key = entry.lowercased()
            return !baseKeys.contains(key) && seen.insert(key).inserted
        }
        guard !added.isEmpty else { return trimmedBuffer }
        guard !trimmedBuffer.isEmpty else { return added.joined(separator: ", ") }
        let separator = trimmedBuffer.hasSuffix(",") ? "\n" : ",\n"
        return trimmedBuffer + separator + added.joined(separator: ", ")
    }
}
