import Foundation

/// Where a result came from.
enum RioFindSource: String, Equatable, Hashable, Comparable {
    case messages, mail, downloads, spotlight

    static func < (lhs: RioFindSource, rhs: RioFindSource) -> Bool { lhs.rawValue < rhs.rawValue }

    /// "in Messages", "in Mail", "in Downloads", "on this Mac".
    var phrase: String {
        switch self {
        case .messages: return "in Messages"
        case .mail: return "in Mail"
        case .downloads: return "in Downloads"
        case .spotlight: return "on this Mac"
        }
    }
}

/// One thing found, from any source. Pure value.
struct RioFindResult: Equatable {
    let path: String
    let date: Date?
    /// The chat handle (phone number or email) it arrived from; nil unless it came from someone else.
    var sender: String?
    var sources: Set<RioFindSource>

    var name: String { (path as NSString).lastPathComponent }
    var fileExtension: String { (path as NSString).pathExtension.lowercased() }
}

/// Phone numbers and emails compared the way Messages stores them.
enum RioFindHandles {
    /// "+1 (530) 555-0100" and "5305550100" both become "5305550100"; emails lowercase.
    static func key(for handle: String) -> String? {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@") { return trimmed.lowercased() }
        let digits = trimmed.filter { $0.isASCII && $0.isNumber }
        guard digits.count >= 7 else { return nil }
        return String(digits.suffix(10))
    }

    static func matches(_ handle: String?, anyOf handles: [String]) -> Bool {
        guard let handle, let key = key(for: handle) else { return false }
        return handles.contains { Self.key(for: $0) == key }
    }
}

enum RioFindRanker {
    /// Messages and Mail keep attachments under ~/Library, which the file allowlist hides. Only
    /// these two folders are opened up for this feature, with the same hidden-item and `..` rules.
    static let messagesAttachmentsSubpath = "Library/Messages/Attachments"
    static let mailDownloadsSubpath = "Library/Containers/com.apple.mail/Data/Library/Mail Downloads"

    static func isPresentable(path: String, home: String) -> Bool {
        if RioFileRanker.isEligible(path: path, home: home) { return true }
        let base = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        for root in [messagesAttachmentsSubpath, mailDownloadsSubpath] {
            let prefix = base + "/" + root + "/"
            guard path.hasPrefix(prefix) else { continue }
            let rest = path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: true)
            guard !rest.isEmpty else { return false }
            if rest.contains(where: { $0 == ".." || $0.hasPrefix(".") }) { return false }
            return true
        }
        return false
    }

    private static func filenameMentions(_ result: RioFindResult, person: String) -> Bool {
        let name = RioFileRanker.tokens(of: result.name)
        let wanted = person.split(separator: " ").map(String.init).filter { $0.count >= 2 }
        guard !wanted.isEmpty else { return false }
        return wanted.contains { token in name.contains { $0 == token || $0.hasPrefix(token) } }
    }

    /// Merges duplicates by path, applies the person, time and kind filters, and orders the rest
    /// best first. `personHandles` are the phone numbers and emails Contacts has for the named person.
    static func rank(
        _ results: [RioFindResult], query: RioFindQuery, personHandles: [String], home: String, now: Date
    ) -> [RioFindResult] {
        let merged = merge(results)
        let extensions = query.allowedExtensions
        var scored: [(result: RioFindResult, score: Double)] = []
        for result in merged {
            guard isPresentable(path: result.path, home: home) else { continue }
            if !extensions.isEmpty, !extensions.contains(result.fileExtension) { continue }
            if let interval = query.interval {
                guard let date = result.date, date >= interval.start, date <= interval.end else { continue }
            }
            var score = 0.0
            if let person = query.person {
                if RioFindHandles.matches(result.sender, anyOf: personHandles) {
                    score += 40
                } else if filenameMentions(result, person: person) {
                    score += 25
                } else {
                    continue
                }
            }
            let nameTokens = RioFileRanker.tokens(of: result.name)
            for keyword in query.keywords where nameTokens.contains(where: { $0 == keyword || $0.hasPrefix(keyword) }) {
                score += 10
            }
            if let date = result.date {
                let ageDays = max(0, now.timeIntervalSince(date) / 86_400)
                score += max(0, 10 - ageDays / 3)
            }
            if result.sources.count > 1 { score += 3 }
            scored.append((result, score))
        }
        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.result.date != rhs.result.date { return (lhs.result.date ?? .distantPast) > (rhs.result.date ?? .distantPast) }
            return lhs.result.path < rhs.result.path
        }.map(\.result)
    }

    /// Same file from two sources becomes one result that remembers both (and the sender).
    static func merge(_ results: [RioFindResult]) -> [RioFindResult] {
        var order: [String] = []
        var byPath: [String: RioFindResult] = [:]
        for result in results {
            let key = (result.path as NSString).standardizingPath
            if var existing = byPath[key] {
                existing.sources.formUnion(result.sources)
                if existing.sender == nil { existing.sender = result.sender }
                byPath[key] = RioFindResult(
                    path: existing.path, date: [existing.date, result.date].compactMap { $0 }.max(),
                    sender: existing.sender, sources: existing.sources
                )
            } else {
                order.append(key)
                byPath[key] = result
            }
        }
        return order.compactMap { byPath[$0] }
    }
}

/// Short spoken and written answers. Pure.
enum RioFindSpeech {
    static let fullDiskAccessNote = "I can't look in Messages attachments without Full Disk Access. You can allow it for Rio Dictate in System Settings, Privacy and Security."
    static let contactsNote = "I need Contacts access to match that person's number."
    static let linkNote = "I can only find saved link files, not links inside messages."

    static func dayPhrase(_ date: Date, now: Date, calendar: Calendar) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<0, 0: return "today"
        case 1: return "yesterday"
        case 2...6: return format(date, "EEEE", calendar)
        default: return format(date, "MMM d", calendar)
        }
    }

    private static func format(_ date: Date, _ pattern: String, _ calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// "Found 3. Best is Report.pdf from yesterday, in Messages."
    static func summary(_ results: [RioFindResult], now: Date, calendar: Calendar) -> String {
        guard let best = results.first else { return "I couldn't find that" }
        var sentence = results.count == 1 ? "Found it: \(best.name)" : "Found \(results.count). Best is \(best.name)"
        if let date = best.date { sentence += " from \(dayPhrase(date, now: now, calendar: calendar))" }
        if let source = best.sources.sorted().first, source != .spotlight { sentence += ", \(source.phrase)" }
        return sentence
    }
}
