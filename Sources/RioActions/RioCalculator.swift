import Foundation

struct RioCalcAnswer: Equatable {
    /// Just the result: "12.6", "8.0467 kilometers", "10 PM yesterday".
    let value: String
    /// The whole line Rio shows and says: "15 percent of 84 is 12.6".
    let sentence: String
}

/// Instant, offline maths: arithmetic, percentages, unit conversions, temperature and time zones.
/// Pure. The clock and the local time zone are injected so tests are deterministic. Anything it
/// can't make sense of returns nil, so garbage never becomes an answer.
enum RioCalculator {
    static func evaluate(_ spoken: String, now: Date = Date(), timeZone: TimeZone = .current) -> RioCalcAnswer? {
        guard spoken.count <= 300 else { return nil }
        let cleaned = clean(spoken)
        guard !cleaned.isEmpty else { return nil }
        let stripped = stripCue(cleaned)
        guard !stripped.isEmpty else { return nil }
        return RioCalcTime.evaluate(cleaned: cleaned, stripped: stripped, now: now, local: timeZone)
            ?? convertUnits(stripped)
            ?? percentForm(stripped)
            ?? arithmetic(stripped)
    }

    // MARK: Normalising

    static func clean(_ spoken: String) -> String {
        var text = spoken.lowercased()
        for (from, to) in [
            ("\u{2019}", ""), ("'", ""), ("\u{00D7}", " * "), ("\u{00F7}", " / "), ("\u{2212}", " - "), ("\u{2013}", " - "),
            ("\u{2014}", " - "), ("\u{00B0}", " degrees "), ("$", ""), ("\u{20AC}", ""), ("\u{00A3}", ""), ("%", " percent "),
            ("a.m.", "am"), ("p.m.", "pm"), ("km/h", "kmh"), ("mi/h", "mph"), ("m/s", "mps"), ("ft/s", "fps"),
        ] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        text = RioText.replacing(#"(?<=\d),(?=\d{3})"#, with: "", in: text)
        text = RioText.replacing(#"(?<=[a-z])-(?=[a-z])"#, with: " ", in: text)
        text = RioText.replacing(#"(?<=\d)\s*x\s*(?=\d)"#, with: " * ", in: text)
        text = RioText.replacing(#"[?!,;"]"#, with: " ", in: text)
        text = RioText.replacing(#"(?<!\d)\.|\.(?!\d)"#, with: " ", in: text)
        text = RioText.replacing(#"([+*/^()-])"#, with: " $1 ", in: text)
        return RioText.collapseWhitespace(text)
    }

    private static func stripCue(_ cleaned: String) -> String {
        var text = cleaned
        let lead = #"^(?:what is|whats|what are|how much is|how much are|how much|calculate|compute|work out|figure out|tell me|convert|solve|give me|the answer to|can you|please|rio|hey|the)\s+"#
        let trail = #"\s+(?:equals?|is|please|thanks)$"#
        while true {
            let next = RioText.replacing(trail, with: "", in: RioText.replacing(lead, with: "", in: text))
            if next == text { break }
            text = next
        }
        return text
    }

    // MARK: Formatting

    static func format(_ value: Double) -> String {
        var number = (value * 1e9).rounded() / 1e9
        if abs(number) < 1e-12 { number = 0 }
        let magnitude = abs(number)
        let decimals = magnitude >= 1 || magnitude == 0 ? 4 : min(10, 3 - Int(floor(log10(magnitude))))
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = decimals
        formatter.roundingMode = .halfUp
        let text = formatter.string(from: NSNumber(value: number)) ?? String(number)
        return text == "-0" ? "0" : text
    }

    // MARK: Arithmetic

    private static func arithmetic(_ stripped: String) -> RioCalcAnswer? {
        let words = stripped.split(separator: " ").map(String.init)
        guard let tokens = RioCalcTokenizer.tokenize(words), let tree = RioCalcParser.parse(tokens),
              !tree.isTrivial, let result = RioCalcEvaluator.value(tree) else { return nil }
        let value = format(result)
        return RioCalcAnswer(value: value, sentence: "\(describe(tokens)) is \(value)")
    }

    private static func describe(_ tokens: [RioCalcToken]) -> String {
        tokens.map { token -> String in
            switch token {
            case .number(_, _, let text): return text
            case .op(let symbol):
                switch symbol {
                case "+": return "plus"
                case "-": return "minus"
                case "*": return "times"
                case "/": return "divided by"
                default: return "to the power of"
                }
            case .leftParen: return "("
            case .rightParen: return ")"
            case .percent: return "percent"
            case .of: return "of"
            case .squareRoot: return "the square root of"
            case .squared: return "squared"
            case .cubed: return "cubed"
            }
        }.joined(separator: " ")
    }

    /// One plain number ("84", "eighty four", "a half"); nil for anything else.
    private static func number(_ text: String) -> Double? {
        let words = text.split(separator: " ").map(String.init)
        guard let tokens = RioCalcTokenizer.tokenize(words), tokens.count == 1, case .number(let value, _, _) = tokens[0] else { return nil }
        return value
    }

    // MARK: Percent phrasings

    private static func percentForm(_ s: String) -> RioCalcAnswer? {
        func answer(_ result: Double, _ sentence: (String) -> String, suffix: String = "") -> RioCalcAnswer? {
            guard result.isFinite, abs(result) < RioCalcEvaluator.limit else { return nil }
            let value = format(result) + suffix
            return RioCalcAnswer(value: value, sentence: sentence(value))
        }
        if let g = RioText.firstMatch(#"^what percent(?:age)? is (.+?) of (.+)$"#, in: s), let a = number(g[1] ?? ""), let b = number(g[2] ?? ""), b != 0 {
            return answer(a / b * 100, { "\(g[1] ?? "") is \($0) of \(g[2] ?? "")" }, suffix: "%")
        }
        if let g = RioText.firstMatch(#"^(.+?) is what percent(?:age)? of (.+)$"#, in: s), let a = number(g[1] ?? ""), let b = number(g[2] ?? ""), b != 0 {
            return answer(a / b * 100, { "\(g[1] ?? "") is \($0) of \(g[2] ?? "")" }, suffix: "%")
        }
        if let g = RioText.firstMatch(#"^what percent(?:age)? of (.+?) is (.+)$"#, in: s), let b = number(g[1] ?? ""), let a = number(g[2] ?? ""), b != 0 {
            return answer(a / b * 100, { "\(g[2] ?? "") is \($0) of \(g[1] ?? "")" }, suffix: "%")
        }
        if let g = RioText.firstMatch(#"^(.+?) percent off(?: of)? (.+)$"#, in: s), let rate = number(g[1] ?? ""), let base = number(g[2] ?? "") {
            return answer(base * (1 - rate / 100), { "\(s) is \($0)" })
        }
        if let g = RioText.firstMatch(#"^add (.+?) percent to (.+)$"#, in: s), let rate = number(g[1] ?? ""), let base = number(g[2] ?? "") {
            return answer(base * (1 + rate / 100), { "\(s) is \($0)" })
        }
        if let g = RioText.firstMatch(#"^subtract (.+?) percent from (.+)$"#, in: s), let rate = number(g[1] ?? ""), let base = number(g[2] ?? "") {
            return answer(base * (1 - rate / 100), { "\(s) is \($0)" })
        }
        if let g = RioText.firstMatch(#"^(?:increase|raise) (.+?) by (.+?) percent$"#, in: s), let base = number(g[1] ?? ""), let rate = number(g[2] ?? "") {
            return answer(base * (1 + rate / 100), { "\(s) is \($0)" })
        }
        if let g = RioText.firstMatch(#"^(?:decrease|reduce|lower) (.+?) by (.+?) percent$"#, in: s), let base = number(g[1] ?? ""), let rate = number(g[2] ?? "") {
            return answer(base * (1 - rate / 100), { "\(s) is \($0)" })
        }
        if let g = RioText.firstMatch(#"^(.+?) percent (?:tip|tax|gratuity) (?:on|of) (.+)$"#, in: s), let rate = number(g[1] ?? ""), let base = number(g[2] ?? "") {
            return answer(base * rate / 100, { "\(s) is \($0)" })
        }
        return nil
    }

    // MARK: Unit conversions

    private static func convertUnits(_ s: String) -> RioCalcAnswer? {
        let words = s.split(separator: " ").map(String.init)
        var targetWords: [String]
        var sourceWords: [String]
        var allowBareUnit = false
        if let g = RioText.firstMatch(#"^how many (.+?) (?:are |is |does )?(?:in|per|are in) (.+)$"#, in: words.joined(separator: " ")),
           let target = g[1], let source = g[2] {
            targetWords = target.split(separator: " ").map(String.init)
            sourceWords = source.split(separator: " ").map(String.init)
            allowBareUnit = true
        } else if let split = words.firstIndex(where: { ["in", "to", "into", "as"].contains($0) }), split > 0, split < words.count - 1 {
            sourceWords = Array(words[..<split])
            targetWords = Array(words[(split + 1)...])
        } else {
            return nil
        }
        guard let target = RioUnits.find(targetWords.joined(separator: " ")),
              let (quantity, source) = quantityAndUnit(sourceWords, allowBareUnit: allowBareUnit),
              let result = RioUnits.convert(quantity, from: source, to: target), result.isFinite,
              abs(result) < RioCalcEvaluator.limit else { return nil }
        let given = format(quantity)
        let value = "\(format(result)) " + target.name(forFormatted: format(result))
        return RioCalcAnswer(value: value, sentence: "\(given) \(source.name(forFormatted: given)) is \(value)")
    }

    private static func quantityAndUnit(_ words: [String], allowBareUnit: Bool) -> (Double, RioUnit)? {
        guard !words.isEmpty else { return nil }
        for unitLength in stride(from: min(3, words.count), through: 1, by: -1) {
            let split = words.count - unitLength
            guard let unit = RioUnits.find(words[split...].joined(separator: " ")) else { continue }
            if split == 0 { return allowBareUnit ? (1, unit) : nil }
            if let quantity = quantity(Array(words[..<split])) { return (quantity, unit) }
        }
        return nil
    }

    private static func quantity(_ words: [String]) -> Double? {
        var rest = words
        var sign = 1.0
        if let first = rest.first, first == "-" || first == "minus" {
            sign = -1
            rest.removeFirst()
        }
        guard !rest.isEmpty else { return nil }
        if rest == ["a"] || rest == ["an"] { return sign }
        guard let tokens = RioCalcTokenizer.tokenize(rest), tokens.count == 1, case .number(let value, _, _) = tokens[0] else { return nil }
        return sign * value
    }
}
