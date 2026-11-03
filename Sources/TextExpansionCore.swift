import Foundation

/// "When I say X, write Y": a fixed rewrite applied to every dictation, for words the
/// speech model keeps mishearing the same way ("clawed" → "Claude").
struct WordReplacement: Codable, Identifiable, Equatable {
    var id = UUID()
    var heard: String
    var replacement: String
}

/// A phrase found anywhere in a dictation and swapped for fixed text.
struct TextExpansionRule: Equatable {
    let phrase: String
    let output: String
    /// Match the case of the spoken phrase ("Gonna" → "Going to"). Off for snippets,
    /// whose text is pasted exactly as written.
    let adaptsCase: Bool
}

/// Pure phrase matching shared by word replacements and inline snippets.
enum TextExpansionCore {
    static func replacementRules(_ replacements: [WordReplacement]) -> [TextExpansionRule] {
        replacements.map {
            TextExpansionRule(phrase: $0.heard, output: $0.replacement, adaptsCase: true)
        }
    }

    /// Replaces every whole-word, case-insensitive occurrence of each rule's phrase in one
    /// left-to-right pass, so one rule's output is never rewritten by another rule.
    /// Where two phrases start at the same place, the longer one wins.
    static func apply(_ rules: [TextExpansionRule], to text: String) -> String {
        let compiled = rules
            .filter { !$0.phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.phrase.count > $1.phrase.count }
            .compactMap { rule in pattern(for: rule.phrase).map { (rule, $0) } }
        guard !compiled.isEmpty, !text.isEmpty else { return text }

        let source = text as NSString
        var result = ""
        var location = 0
        while location < source.length {
            let searchRange = NSRange(location: location, length: source.length - location)
            var best: (rule: TextExpansionRule, range: NSRange)?
            for (rule, regex) in compiled {
                guard let match = regex.firstMatch(in: text, range: searchRange) else { continue }
                if best == nil || match.range.location < best!.range.location {
                    best = (rule, match.range)
                }
            }
            guard let best else { break }
            result += source.substring(with: NSRange(location: location, length: best.range.location - location))
            let spoken = source.substring(with: best.range)
            result += best.rule.adaptsCase ? matchingCase(of: spoken, for: best.rule.output) : best.rule.output
            location = best.range.location + best.range.length
        }
        if location < source.length { result += source.substring(from: location) }
        return result
    }

    /// Words of the phrase in order, separated by any run of spaces or hyphens, and not
    /// glued to surrounding letters or digits.
    static func pattern(for phrase: String) -> NSRegularExpression? {
        let words = phrase
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty else { return nil }
        let body = words.joined(separator: #"[\s\-]+"#)
        return try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}])"# + body + #"(?![\p{L}\p{N}])"#,
            options: [.caseInsensitive]
        )
    }

    /// Capitalizes a lowercase replacement when the spoken phrase started a sentence.
    static func matchingCase(of spoken: String, for output: String) -> String {
        guard let spokenFirst = spoken.first, spokenFirst.isUppercase,
              let outputFirst = output.first, outputFirst.isLowercase else { return output }
        return outputFirst.uppercased() + output.dropFirst()
    }
}

extension TextExpansionRule {
    /// False for rules whose output contains their own phrase ("John" → "John Smith"),
    /// which would grow every time they ran again on already-replaced text.
    var isIdempotent: Bool {
        TextExpansionCore.apply([self], to: output) == output
    }
}

/// Everything that rewrites one dictation's text, captured once on the main thread when
/// the dictation stops, so later settings edits can't race with processing.
struct DictationTextRules {
    let replacements: [TextExpansionRule]
    let snippets: [TextExpansionRule]
    /// The cleanup system prompt to send; empty means the default prompt.
    let systemPrompt: String

    static let none = DictationTextRules(replacements: [], snippets: [], systemPrompt: "")

    /// Fixes misheard words so the cleanup model sees the intended ones.
    func beforeCleanup(_ text: String) -> String {
        TextExpansionCore.apply(replacements, to: text)
    }

    /// When the model rewrote the text, replacements run once more in case it reintroduced
    /// a misheard form, skipping rules that would apply twice. Snippets expand last.
    func afterCleanup(_ text: String, cleanupRan: Bool) -> String {
        let replaced = cleanupRan ? TextExpansionCore.apply(replacements.filter(\.isIdempotent), to: text) : text
        return TextExpansionCore.apply(snippets, to: replaced)
    }
}
