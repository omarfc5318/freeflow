import Foundation

/// One day's dictation totals. Only counts are kept; no dictated text is ever stored here.
struct DailyUsage: Codable, Equatable {
    var words: Int = 0
    var seconds: Double = 0
    var sessions: Int = 0
}

struct UsageSummary: Equatable {
    let totalWords: Int
    let totalSessions: Int
    let wordsThisWeek: Int
    let wordsToday: Int
    /// Speaking speed across all dictations, or 0 before the first one.
    let wordsPerMinute: Int
    /// Consecutive days with a dictation, ending today or yesterday.
    let currentStreak: Int
    let longestStreak: Int
    /// Typing time saved versus `typingWordsPerMinute`, never negative.
    let timeSavedSeconds: Double
}

enum UsageStatsCore {
    /// A typical typing speed, used for the "time saved" estimate.
    static let typingWordsPerMinute = 40.0

    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
    }

    /// Returns a copy of `days` with one dictation added to `date`'s totals.
    static func recording(
        words: Int, seconds: Double, on date: Date, into days: [String: DailyUsage], calendar: Calendar
    ) -> [String: DailyUsage] {
        guard words > 0 else { return days }
        var updated = days
        let key = dayKey(for: date, calendar: calendar)
        var day = updated[key] ?? DailyUsage()
        day.words += words
        day.seconds += max(0, seconds)
        day.sessions += 1
        updated[key] = day
        return updated
    }

    static func summary(of days: [String: DailyUsage], today: Date, calendar: Calendar) -> UsageSummary {
        let active = days.filter { $0.value.words > 0 }
        let totalWords = active.values.reduce(0) { $0 + $1.words }
        let totalSeconds = active.values.reduce(0) { $0 + $1.seconds }
        let totalSessions = active.values.reduce(0) { $0 + $1.sessions }

        let lastSevenKeys = Set((0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { dayKey(for: $0, calendar: calendar) }
        })
        let wordsThisWeek = active.filter { lastSevenKeys.contains($0.key) }.values.reduce(0) { $0 + $1.words }
        let wordsToday = active[dayKey(for: today, calendar: calendar)]?.words ?? 0

        let wordsPerMinute = totalSeconds > 0 ? Int((Double(totalWords) / totalSeconds * 60).rounded()) : 0
        let typingSeconds = Double(totalWords) / typingWordsPerMinute * 60

        return UsageSummary(
            totalWords: totalWords,
            totalSessions: totalSessions,
            wordsThisWeek: wordsThisWeek,
            wordsToday: wordsToday,
            wordsPerMinute: wordsPerMinute,
            currentStreak: currentStreak(activeKeys: Set(active.keys), today: today, calendar: calendar),
            longestStreak: longestStreak(activeKeys: Set(active.keys), calendar: calendar),
            timeSavedSeconds: max(0, typingSeconds - totalSeconds)
        )
    }

    /// A streak survives until a full day passes with no dictation, so it still counts
    /// in the morning before today's first dictation.
    static func currentStreak(activeKeys: Set<String>, today: Date, calendar: Calendar) -> Int {
        var day = today
        if !activeKeys.contains(dayKey(for: day, calendar: calendar)) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var streak = 0
        while activeKeys.contains(dayKey(for: day, calendar: calendar)) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }

    static func longestStreak(activeKeys: Set<String>, calendar: Calendar) -> Int {
        let dates = activeKeys.compactMap { date(fromKey: $0, calendar: calendar) }.sorted()
        var longest = 0
        var run = 0
        var previous: Date?
        for date in dates {
            if let previous, let next = calendar.date(byAdding: .day, value: 1, to: previous),
               calendar.isDate(next, inSameDayAs: date) {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = date
        }
        return longest
    }

    static func date(fromKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
}
