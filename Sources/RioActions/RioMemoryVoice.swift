import Foundation

/// How Rio says memories back: "my locker code is 4321" becomes "Your locker code is 4321".
enum RioMemoryVoice {
    private static func replace(_ pattern: String, _ template: String, in text: String, ignoreCase: Bool) -> String {
        let options: NSRegularExpression.Options = ignoreCase ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        return regex.stringByReplacingMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    static func secondPerson(_ fact: String) -> String {
        var text = fact.replacingOccurrences(of: "\u{2019}", with: "'")
        for (pattern, template) in [
            (#"\bI'm\b"#, "you're"), (#"\bI've\b"#, "you've"), (#"\bI'll\b"#, "you'll"), (#"\bI'd\b"#, "you'd"),
            (#"\bI am\b"#, "you are"), (#"\bI\b"#, "you"),
        ] {
            text = replace(pattern, template, in: text, ignoreCase: false)
        }
        for (pattern, template) in [(#"\bmyself\b"#, "yourself"), (#"\bmine\b"#, "yours"), (#"\bmy\b"#, "your"), (#"\bme\b"#, "you")] {
            text = replace(pattern, template, in: text, ignoreCase: true)
        }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func sentence(_ text: String) -> String {
        guard let last = text.last else { return text }
        return ".!?".contains(last) ? text : text + "."
    }

    /// One or more facts as spoken sentences.
    static func recallSentence(_ facts: [String]) -> String {
        facts.map { sentence(secondPerson($0)) }.joined(separator: " ")
    }

    static let listedCount = 5

    /// "I remember 8 things. ... and 3 more." `sentences` are already in Rio's voice.
    static func overview(_ sentences: [String]) -> String {
        let count = sentences.count
        var parts = ["I remember \(count) thing\(count == 1 ? "" : "s")."]
        parts += sentences.prefix(listedCount).map(sentence)
        if count > listedCount { parts.append("and \(count - listedCount) more.") }
        return parts.joined(separator: " ")
    }
}
