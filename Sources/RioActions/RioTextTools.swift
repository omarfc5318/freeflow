import Foundation

/// Small pure text helpers shared by the Rio Actions parser and matcher. Foundation only.
enum RioText {
    /// Case-insensitive match; returns the capture groups (index 0 is the whole match), or nil.
    static func firstMatch(_ pattern: String, in text: String) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let full = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: full) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    static func matches(_ pattern: String, _ text: String) -> Bool {
        firstMatch(pattern, in: text) != nil
    }

    static func replacing(_ pattern: String, with template: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let full = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: full, withTemplate: template)
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Lowercase letters and digits only: "Visual Studio Code" and "V S code" compare as
    /// "visualstudiocode" and "vscode".
    static func compact(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Words as a speech-to-text transcript spells them, with punctuation turned into spaces
    /// (case is kept so app names survive). Apostrophes vanish ("don't" -> "dont"), dots
    /// between letters or digits stay so "github.com" survives, "%" becomes "percent".
    static func simplify(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "\u{2019}", with: "")
            .replacingOccurrences(of: "\u{2018}", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "%", with: " percent ")
            .replacingOccurrences(of: "&", with: " and ")
        text = replacing(#"(?<![A-Za-z0-9])\.|\.(?![A-Za-z0-9])"#, with: " ", in: text)
        text = replacing(#"[,!?;:"()\[\]{}/\\_–—-]"#, with: " ", in: text)
        return collapseWhitespace(text)
    }

    // MARK: Numbers spoken or typed

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
        "eighty": 80, "ninety": 90,
    ]

    /// "40" -> 40, "forty five" -> 45, "a hundred" -> 100. Nil when it isn't a number.
    static func number(from text: String) -> Int? {
        let cleaned = text.lowercased().trimmingCharacters(in: .whitespaces)
        if !cleaned.isEmpty, cleaned.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return Int(cleaned)
        }
        var total = 0
        var sawNumber = false
        for word in cleaned.split(separator: " ").map(String.init) {
            if let value = units[word] {
                total += value
            } else if let value = tens[word] {
                total += value
            } else if word == "hundred" {
                total = (total == 0 ? 1 : total) * 100
            } else if word == "a" || word == "and" {
                continue
            } else {
                return nil
            }
            sawNumber = true
        }
        return sawNumber ? total : nil
    }

    // MARK: Edit distance

    /// Optimal string alignment distance (insert, delete, substitute, adjacent swap).
    static func editDistance(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var table = Array(repeating: Array(repeating: 0, count: t.count + 1), count: s.count + 1)
        for i in 0...s.count { table[i][0] = i }
        for j in 0...t.count { table[0][j] = j }
        for i in 1...s.count {
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                table[i][j] = min(table[i - 1][j] + 1, table[i][j - 1] + 1, table[i - 1][j - 1] + cost)
                if i > 1, j > 1, s[i - 1] == t[j - 2], s[i - 2] == t[j - 1] {
                    table[i][j] = min(table[i][j], table[i - 2][j - 2] + 1)
                }
            }
        }
        return table[s.count][t.count]
    }
}
