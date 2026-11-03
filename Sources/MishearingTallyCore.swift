import Foundation

/// Counts how often the user fixes the same mishearing ("super base" → "Supabase"). Adding the
/// corrected word to the vocabulary cannot help when it is already there, so a repeated
/// mishearing graduates into a fixed "when I hear X, write Y" replacement instead.
/// Only the word pairs are kept (never surrounding text), capped and persisted as small JSON.
struct MishearingTally: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let original: String
        let corrected: String
        var count: Int
    }

    /// Times the same mishearing must be fixed before it becomes a replacement rule.
    static let threshold = 2
    static let maxEntries = 200

    /// Oldest first; a repeated pair moves to the end.
    private(set) var entries: [Entry] = []

    /// Whether a correction describes a mishearing worth counting.
    static func isCountable(_ correction: LearnedCorrection) -> Bool {
        let original = correction.original.trimmingCharacters(in: .whitespacesAndNewlines)
        let corrected = correction.corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        return !original.isEmpty && !corrected.isEmpty && original.lowercased() != corrected.lowercased()
    }

    /// Counts one fix. Returns the replacement rule to add once the pair reached the threshold
    /// and no rule for the same heard phrase exists yet (a rule the user wrote always wins).
    mutating func record(_ correction: LearnedCorrection, existingRules: [WordReplacement]) -> WordReplacement? {
        guard Self.isCountable(correction) else { return nil }
        let original = correction.original.trimmingCharacters(in: .whitespacesAndNewlines)
        let corrected = correction.corrected.trimmingCharacters(in: .whitespacesAndNewlines)

        let hasRule = existingRules.contains {
            $0.heard.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == original.lowercased()
        }
        let index = entries.firstIndex {
            $0.original.lowercased() == original.lowercased() && $0.corrected.lowercased() == corrected.lowercased()
        }
        var entry = index.map { entries.remove(at: $0) } ?? Entry(original: original, corrected: corrected, count: 0)
        entry.count += 1

        if hasRule || entry.count >= Self.threshold {
            // Done with this pair either way: promoted, or the user already has a rule.
            return hasRule ? nil : WordReplacement(heard: original, replacement: corrected)
        }
        entries.append(entry)
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
        return nil
    }
}
