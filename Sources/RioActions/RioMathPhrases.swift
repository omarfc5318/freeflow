import Foundation

/// "what's 15% of 84", "5 miles in km", "what's 9 AM Doha time here". Claims a phrase only when the
/// calculator can really answer it, so "volume 40", "10 minute timer" and every other command
/// keep their own parsers. Pure.
enum RioMathPhrases {
    /// Words that mean the user is talking to another part of Rio.
    private static let otherCommand = #"\b(?:volume|brightness|timer|alarm|remind|reminder|remember|forget|note|email|text|message|open|play|call)\b"#

    static func parse(raw: String, simplified: String) -> RioAction? {
        var text = raw.trimmingCharacters(in: CharacterSet(charactersIn: " .!?,;:\n\t"))
        text = RioText.replacing(#"[,\s]+(?:please|thanks)$"#, with: "", in: text)
        guard !text.isEmpty, text.count <= 200, !RioText.matches(otherCommand, text),
              RioCalculator.evaluate(text) != nil else { return nil }
        return .calculate(expression: text)
    }

    /// Whole-sentence check run before the parser splits on "and", "plus" and "then", which would
    /// cut "two hundred and five plus ten" apart.
    static func wholeUtterance(_ body: String) -> RioAction? {
        parse(raw: body, simplified: "")
    }
}

/// Builder L's phrases that must see the whole sentence (the parser's clause splitter would
/// otherwise cut a note or a sum at "and" / "plus" / a comma).
enum RioPersonalPhrases {
    static func wholeUtterance(_ body: String) -> RioAction? {
        RioMemoryPhrases.parse(raw: body, simplified: RioText.simplify(body))
    }
}
