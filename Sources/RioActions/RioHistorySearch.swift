import Foundation

// Timeline search (#70): find something the owner dictated, locally. Pure, Foundation only. The
// handler hands this the owner's own dictation text; nothing is stored, logged or sent anywhere.

/// One dictation, reduced to what search needs.
struct RioHistoryEntry: Equatable {
    let id: UUID
    let date: Date
    let text: String
}

struct RioHistoryHit: Equatable {
    let entry: RioHistoryEntry
    let score: Double
    /// The best sentence of the dictation, clipped.
    let snippet: String
}

enum RioHistorySearch {
    static let maxSnippetLength = 160
    static let maxEntries = 3000

    private static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "to", "in", "on", "at", "for", "with", "about", "my", "me", "i", "is", "was", "it",
        "that", "this", "we", "you", "he", "she", "they", "be", "are", "so", "do", "did", "have", "has", "had", "said", "say",
        "last", "from", "by", "as", "if", "but", "not", "regarding", "concerning",
    ]
    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    // MARK: Ranking

    static func rank(
        query: String,
        entries: [RioHistoryEntry],
        now: Date = Date(),
        calendar: Calendar = .current,
        limit: Int = 3
    ) -> [RioHistoryHit] {
        let parsed = parse(query: query, now: now, calendar: calendar)
        guard !parsed.tokens.isEmpty || parsed.window != nil else { return [] }
        var hits: [RioHistoryHit] = []
        for entry in entries.sorted(by: { $0.date > $1.date }).prefix(maxEntries) {
            if let window = parsed.window, !window.contains(entry.date) { continue }
            if parsed.tokens.isEmpty {
                hits.append(RioHistoryHit(entry: entry, score: recency(entry.date, now), snippet: snippet(in: entry.text, tokens: [])))
                continue
            }
            let entryTokens = tokens(entry.text)
            let matched = parsed.tokens.filter { token in entryTokens.contains { matches($0, token) } }
            let fraction = Double(matched.count) / Double(parsed.tokens.count)
            guard !matched.isEmpty, fraction >= 0.5 else { continue }
            var score = fraction + recency(entry.date, now) * 0.25
            if parsed.tokens.count > 1, tokens(entry.text).joined(separator: " ").contains(parsed.tokens.joined(separator: " ")) {
                score += 0.3
            }
            hits.append(RioHistoryHit(entry: entry, score: score, snippet: snippet(in: entry.text, tokens: matched)))
        }
        let ordered = hits.sorted { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.entry.date > rhs.entry.date
        }
        return Array(ordered.prefix(max(0, limit)))
    }

    /// 1 for now, halving every ~3 weeks.
    private static func recency(_ date: Date, _ now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(date)) / 86_400
        return exp(-days / 30)
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Prefix match for plurals and endings, once both words are long enough to mean something.
    private static func matches(_ word: String, _ token: String) -> Bool {
        if word == token { return true }
        guard min(word.count, token.count) >= 4 else { return false }
        return word.hasPrefix(token) || token.hasPrefix(word)
    }

    private struct ParsedQuery {
        let tokens: [String]
        let window: DateInterval?
    }

    /// Splits "plumber yesterday" into content words and a day window.
    private static func parse(query: String, now: Date, calendar: Calendar) -> ParsedQuery {
        var window: DateInterval?
        var content: [String] = []
        let startOfToday = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> DateInterval? {
            guard let start = calendar.date(byAdding: .day, value: -offset, to: startOfToday),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            return DateInterval(start: start, end: end)
        }
        for token in tokens(query) {
            if token == "today" { window = day(0); continue }
            if token == "yesterday" { window = day(1); continue }
            if let index = weekdays.firstIndex(of: token) {
                let todayIndex = calendar.component(.weekday, from: now) - 1
                window = day((todayIndex - index + 7) % 7)
                continue
            }
            if stopwords.contains(token) { continue }
            content.append(token)
        }
        return ParsedQuery(tokens: content, window: window)
    }

    // MARK: Snippet

    private static func snippet(in text: String, tokens matched: [String]) -> String {
        let sentences = text.split(whereSeparator: { ".!?\n\u{061F}".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let best = sentences.max { lhs, rhs in
            score(lhs, matched) < score(rhs, matched)
        } ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
        // `max` returns the last of equal elements; prefer the first.
        let firstBest = sentences.first { score($0, matched) == score(best, matched) } ?? best
        return clip(firstBest)
    }

    private static func score(_ sentence: String, _ matched: [String]) -> Int {
        let words = tokens(sentence)
        return matched.filter { token in words.contains { matches($0, token) } }.count
    }

    private static func clip(_ text: String) -> String {
        guard text.count > maxSnippetLength else { return text }
        return String(text.prefix(maxSnippetLength)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: Answer

    /// "On Monday you said: “…”".
    static func answer(for hit: RioHistoryHit, now: Date = Date(), calendar: Calendar = .current) -> String {
        "\(when(hit.entry.date, now: now, calendar: calendar)) you said: \u{201C}\(hit.snippet)\u{201D}"
    }

    static func when(_ date: Date, now: Date, calendar: Calendar) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = days < 7 ? "EEEE" : "MMMM d"
        return "On " + formatter.string(from: date)
    }
}
