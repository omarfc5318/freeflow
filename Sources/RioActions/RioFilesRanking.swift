import Foundation

/// A search result, reduced to what ranking needs. Pure: built from NSMetadataItem by the
/// searcher, from synthetic values in tests.
struct RioFileCandidate: Equatable {
    let path: String
    let lastUsed: Date?
    let modified: Date?
    let isDirectory: Bool
}

enum RioFileRanker {
    // MARK: Which files may ever be opened

    private static let skippedBundleSuffixes = [".app", ".photoslibrary", ".fcpbundle", ".lrlibrary", ".imovielibrary", ".musiclibrary"]

    /// Under the home folder only: no hidden items, no ~/Library (except iCloud Drive), no app
    /// bundles, package contents or dependency folders.
    static func isEligible(path: String, home: String) -> Bool {
        let base = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        guard path.hasPrefix(base + "/") else { return false }
        let components = path.dropFirst(base.count + 1).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty else { return false }
        for component in components {
            if component == ".." || component.hasPrefix(".") || component == "node_modules" { return false }
            let lowered = component.lowercased()
            if skippedBundleSuffixes.contains(where: { lowered.hasSuffix($0) }) { return false }
        }
        if components[0] == "Library" {
            return components.count >= 3 && components[1] == "Mobile Documents" && components[2] == "com~apple~CloudDocs"
        }
        return true
    }

    // MARK: Safety

    private static let programExtensions: Set<String> = [
        "app", "command", "sh", "zsh", "bash", "csh", "tool", "workflow", "action", "scpt", "scptd", "applescript",
        "jar", "pkg", "mpkg", "dmg", "exe", "bat", "cmd", "msi", "terminal",
    ]

    /// Files that would run code or install something when opened. Rio shows these in Finder
    /// instead of opening them. `isExecutable` is the file's execute bit (only trusted for
    /// files with no extension, like a bare unix binary).
    static func isRiskyToOpen(path: String, isDirectory: Bool, isExecutable: Bool) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        if programExtensions.contains(ext) { return true }
        return ext.isEmpty && !isDirectory && isExecutable
    }

    // MARK: Name matching

    /// Lowercase words of a file name: extension dropped, camelCase, digits and punctuation split.
    static func tokens(of fileName: String) -> [String] {
        var stem = fileName
        let ext = (fileName as NSString).pathExtension
        if !ext.isEmpty, ext.count <= 5, ext.allSatisfy({ $0.isLetter || $0.isNumber }) {
            stem = (fileName as NSString).deletingPathExtension
        }
        stem = stem.folding(options: [.diacriticInsensitive], locale: nil)
        var result: [String] = []
        var current = ""
        var previous: Character?
        func flush() {
            if !current.isEmpty { result.append(current.lowercased()); current = "" }
        }
        let characters = Array(stem)
        for (index, character) in characters.enumerated() {
            guard character.isLetter || character.isNumber else { flush(); previous = nil; continue }
            if let previous {
                let digitChange = previous.isNumber != character.isNumber
                let lowerToUpper = previous.isLowercase && character.isUppercase
                let nextIsLower = index + 1 < characters.count && characters[index + 1].isLowercase
                let acronymEnd = previous.isUppercase && character.isUppercase && nextIsLower
                if digitChange || lowerToUpper || acronymEnd { flush() }
            }
            current.append(character)
            previous = character
        }
        flush()
        return result
    }

    private static func equivalent(_ wanted: String, _ found: String) -> Bool {
        if wanted.allSatisfy(\.isNumber) || found.allSatisfy(\.isNumber) {
            guard wanted.allSatisfy(\.isNumber), found.allSatisfy(\.isNumber) else { return false }
            return Int(wanted) == Int(found) && Int(wanted) != nil
        }
        for option in RioFileQuery.equivalents(of: wanted) {
            if option == found || option + "s" == found || option + "es" == found || found + "s" == option || found + "es" == option {
                return true
            }
        }
        return false
    }

    private static func matched(_ wanted: [String], in tokens: [String]) -> [Bool] {
        wanted.map { word in tokens.contains { equivalent(word, $0) } }
    }

    /// Every word of the query is in the file's name or (for files kept in a named folder) the
    /// name of its folder. A query with no words matches any name.
    static func nameMatches(_ name: String, parent: String? = nil, query: RioFileQuery) -> Bool {
        let wanted = query.effectiveTokens
        if wanted.isEmpty { return true }
        let own = tokens(of: name)
        let folder = parent.map(tokens(of:)) ?? []
        return wanted.allSatisfy { word in (own + folder).contains { equivalent(word, $0) } }
    }

    // MARK: Ranking

    private static func fileType(_ candidate: RioFileCandidate) -> RioFileType? {
        if candidate.isDirectory { return .folder }
        return RioFileType.forExtension((candidate.path as NSString).pathExtension)
    }

    private static func recencyPoints(_ candidate: RioFileCandidate, now: Date) -> Double {
        guard let date = candidate.lastUsed ?? candidate.modified else { return 0 }
        let days = max(0, now.timeIntervalSince(date) / 86_400)
        switch days {
        case ...1: return 12
        case ...7: return 9
        case ...30: return 6
        case ...90: return 3
        default: return 0
        }
    }

    private static let friendlyTopFolders: Set<String> = ["Desktop", "Documents", "Downloads"]

    private static func parentName(_ path: String) -> String {
        ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
    }

    private static func score(_ candidate: RioFileCandidate, query: RioFileQuery, home: String, now: Date) -> Double {
        let name = (candidate.path as NSString).lastPathComponent
        let own = tokens(of: name)
        let folder = tokens(of: parentName(candidate.path))
        let wanted = query.effectiveTokens
        let direct = matched(wanted, in: own)
        let viaFolder = matched(wanted, in: folder)
        var total = 0.0
        for (index, hit) in direct.enumerated() {
            if hit { total += 10 } else if viaFolder[index] { total += 5 }
        }
        let directCount = direct.filter { $0 }.count
        if !wanted.isEmpty, directCount == wanted.count, own.count == wanted.count { total += 10 }
        let softHits = matched(query.softTokens, in: own).filter { $0 }.count
        if !query.coreTokens.isEmpty { total += Double(softHits) * 12 }
        if let type = fileType(candidate), query.types.contains(type) { total += type == .folder ? 20 : 15 }
        total += recencyPoints(candidate, now: now) * (query.preferRecent ? 3 : 1)
        total -= Double(min(max(0, own.count - directCount - softHits), 3)) * 0.5
        let relative = candidate.path.dropFirst(home.count).split(separator: "/").first.map(String.init)
        if let relative, friendlyTopFolders.contains(relative) { total += 2 }
        return total
    }

    private static func sorted(_ candidates: [RioFileCandidate], by score: (RioFileCandidate) -> Double) -> [RioFileCandidate] {
        candidates
            .map { ($0, score($0)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.path < $1.0.path }
            .map(\.0)
    }

    /// Name matches, best first.
    static func rank(_ candidates: [RioFileCandidate], query: RioFileQuery, home: String, now: Date) -> [RioFileCandidate] {
        let eligible = candidates.filter { isEligible(path: $0.path, home: home) }
        let qualified: [RioFileCandidate]
        if query.effectiveTokens.isEmpty {
            // Only a type was asked for ("the latest PDF"): the file must be of that type.
            qualified = eligible.filter { candidate in
                guard let type = fileType(candidate) else { return false }
                return query.types.contains(type)
            }
        } else {
            qualified = eligible.filter {
                nameMatches(($0.path as NSString).lastPathComponent, parent: parentName($0.path), query: query)
            }
        }
        return sorted(qualified) { score($0, query: query, home: home, now: now) }
    }

    /// Content matches: Spotlight already matched the text, so the newest come first.
    static func rankContentMatches(_ candidates: [RioFileCandidate], query: RioFileQuery, home: String, now: Date) -> [RioFileCandidate] {
        let eligible = candidates.filter { isEligible(path: $0.path, home: home) }
        return sorted(eligible) { ($0.lastUsed ?? $0.modified ?? .distantPast).timeIntervalSince1970 }
    }
}
