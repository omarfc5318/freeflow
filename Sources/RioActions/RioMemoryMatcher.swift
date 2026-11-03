import Foundation

/// Fuzzy matching of a spoken question against remembered facts. Pure and local.
enum RioMemoryMatcher {
    private static let stopwords: Set<String> = [
        "what", "whats", "is", "are", "was", "were", "my", "mine", "your", "the", "a", "an", "do", "does", "did", "you", "i",
        "im", "ive", "me", "about", "tell", "told", "say", "said", "remember", "know", "of", "for", "to", "on", "in", "at",
        "and", "or", "it", "its", "that", "this", "have", "has", "had", "got", "am", "be", "there", "any", "anything",
        "something", "which", "who", "where", "when", "how", "can", "could", "would", "will", "please", "rio",
    ]

    static func tokens(_ text: String) -> [String] {
        var cleaned = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        cleaned = cleaned.replacingOccurrences(of: "'s", with: "").replacingOccurrences(of: "'", with: "")
        let words = cleaned.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        return words.filter { !stopwords.contains($0) }.map { word in
            word.count > 3 && word.hasSuffix("s") && !word.hasSuffix("ss") ? String(word.dropLast()) : word
        }
    }

    /// 0 for no match, up to 1 for every word of the question found in the fact.
    static func score(query: [String], fact: [String]) -> Double {
        guard !query.isEmpty else { return 0 }
        var total = 0.0
        var strong = false
        for word in query {
            var best = 0.0
            for candidate in fact { best = max(best, similarity(word, candidate)) }
            if best >= 0.85 { strong = true }
            total += best
        }
        let score = total / Double(query.count)
        return strong && score >= 0.6 ? score : 0
    }

    private static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        if a.count >= 4, b.count >= 4, a.hasPrefix(b) || b.hasPrefix(a) { return 0.85 }
        guard a.count >= 4, b.count >= 4 else { return 0 }
        let distance = RioText.editDistance(a, b)
        if distance <= 1 { return 0.85 }
        if distance <= 2, min(a.count, b.count) >= 7 { return 0.75 }
        return 0
    }

    /// Indexes of the facts that match best, ties kept, in storage order.
    static func best(query: String, facts: [String], limit: Int) -> [Int] {
        let wanted = tokens(query)
        let scored = facts.enumerated().map { ($0.offset, score(query: wanted, fact: tokens($0.element))) }.filter { $0.1 > 0 }
        guard let top = scored.map(\.1).max() else { return [] }
        return Array(scored.filter { $0.1 >= top - 0.01 }.map(\.0).prefix(limit))
    }

    /// "my locker code is 4321" -> "locker code"; nil when the fact isn't a "my X is Y" statement.
    static func subject(of fact: String) -> String? {
        guard let groups = RioText.firstMatch(#"^(?:my|our)\s+(.+?)\s+(?:is|are|was|were)\s+.+$"#, in: fact), let subject = groups[1] else { return nil }
        let words = tokens(subject)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}
