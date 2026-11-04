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
        let plain = withoutCurrency(stripped)
        return RioCalcTime.evaluate(cleaned: cleaned, stripped: stripped, now: now, local: timeZone)
            ?? convertUnits(stripped)
            ?? numberBase(plain)
            ?? percentForm(plain)
            ?? average(plain)
            ?? arithmetic(plain)
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
        // ".5" is 0.5 (the dot rule below would otherwise drop it and leave 5).
        text = RioText.replacing(#"(?<![\d.])\.(?=\d)"#, with: "0.", in: text)
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

    /// "20 percent of 45 dollars": money words say what the number is, not a word to calculate.
    private static func withoutCurrency(_ text: String) -> String {
        RioText.collapseWhitespace(RioText.replacing(#"(?<=\d)\s+(?:dollars?|bucks|usd|euros?|eur|riyals?|qar|sar|dirhams?|aed|rupees?)\b"#, with: "", in: text))
    }

    // MARK: Formatting

    /// Decimals Rio says for a result of 1 or more: "22.22 degrees", not "22.2222".
    static let spokenDecimals = 2
    /// Significant digits for a maths answer ("the square root of 2 is 1.414"; round 3).
    static let mathSignificantDigits = 4

    /// `significant` nil: conversions and percentages (2 decimals, or 2 significant digits below
    /// 1). A maths answer passes `mathSignificantDigits`.
    static func format(_ value: Double, significant: Int? = nil) -> String {
        // Tiny results ("1 divided by 3 billion") keep their digits instead of rounding to 0.
        var number = abs(value) < 1e-3 ? value : (value * 1e9).rounded() / 1e9
        if abs(number) < 1e-15 { number = 0 }
        let magnitude = abs(number)
        let digits = significant ?? 2
        let decimals: Int
        if magnitude == 0 {
            decimals = spokenDecimals
        } else if magnitude >= 1 {
            // Below 1, two significant digits: 0.4536 -> 0.45, 0.001234 -> 0.0012.
            decimals = significant.map { max(spokenDecimals, $0 - 1 - Int(floor(log10(magnitude)))) } ?? spokenDecimals
        } else {
            decimals = min(15, digits - 1 - Int(floor(log10(magnitude))))
        }
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
        guard let tokens = RioCalcTokenizer.tokenize(words), let tree = RioCalcParser.parse(tokens), !tree.isTrivial else { return nil }
        guard let result = RioCalcEvaluator.value(tree) else {
            // "100 divided by 0" gets a plain answer instead of a shrug.
            if tree.dividesByZero { return RioCalcAnswer(value: "undefined", sentence: "You can't divide by zero") }
            // "2 to the power of 64": past the double's exact range, said exactly or rounded.
            return bigPower(tree).map { RioCalcAnswer(value: $0, sentence: "\(describe(tokens)) is \($0)") }
        }
        let value = format(result, significant: mathSignificantDigits)
        return RioCalcAnswer(value: value, sentence: "\(describe(tokens)) is \(value)")
    }

    static let maxExactDigits = 38.0

    /// A whole-number power too big for the plain path: every digit when it fits in a Decimal,
    /// else "about 1.607 times 10 to the 60".
    private static func bigPower(_ tree: RioCalcNode) -> String? {
        guard case .binary("^", .number(let base, _), .number(let exponent, _)) = tree,
              base == base.rounded(), exponent == exponent.rounded(), abs(base) >= 2, abs(base) <= 1e6,
              exponent >= 1, exponent <= 1_000 else { return nil }
        let digits = exponent * log10(abs(base))
        if digits < maxExactDigits {
            let exact = pow(Decimal(Int(base)), Int(exponent))
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = true
            formatter.groupingSeparator = ","
            formatter.groupingSize = 3
            formatter.maximumFractionDigits = 0
            return formatter.string(from: NSDecimalNumber(decimal: exact))
        }
        let power = floor(digits)
        let mantissa = pow(10, digits - power)
        let sign = base < 0 && exponent.truncatingRemainder(dividingBy: 2) == 1 ? "minus " : ""
        return "about \(sign)\(format(mantissa, significant: mathSignificantDigits)) times 10 to the \(format(power))"
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
                case "m": return "mod"
                case "C": return "choose"
                case "t": return "to the"
                default: return "to the power of"
                }
            case .leftParen: return "("
            case .rightParen: return ")"
            case .percent: return "percent"
            case .of: return "of"
            case .squareRoot: return "the square root of"
            case .squared: return "squared"
            case .cubed: return "cubed"
            case .factorial: return "factorial"
            case .function(_, let text), .root(_, let text): return text
            case .logBase: return "log base"
            case .degrees: return "degrees"
            case .radians: return "radians"
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
        // "98 out of 120 as a percent" (round 3).
        if let g = RioText.firstMatch(#"^(?:what percent(?:age)? is )?(.+?) out of (.+?)(?: (?:as|in|into|to) (?:a )?percent(?:age)?)?$"#, in: s),
           let a = number(g[1] ?? ""), let b = number(g[2] ?? ""), b != 0 {
            return answer(a / b * 100, { "\(g[1] ?? "") out of \(g[2] ?? "") is \($0)" }, suffix: "%")
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

    // MARK: Number bases and averages (round 3)

    static let maxBaseValue = 9_007_199_254_740_992.0

    /// "1000 in binary", "255 in hex": a whole number in base 2, 8 or 16.
    private static func numberBase(_ s: String) -> RioCalcAnswer? {
        guard let g = RioText.firstMatch(#"^(.+?) (?:in|to|into|as) (binary|hex|hexadecimal|octal|base (?:2|8|16))$"#, in: s),
              let source = g[1], let base = g[2], let value = number(source),
              value >= 0, value == value.rounded(), value <= maxBaseValue else { return nil }
        let radix: Int
        let name: String
        switch base {
        case "binary", "base 2": (radix, name) = (2, "binary")
        case "octal", "base 8": (radix, name) = (8, "octal")
        default: (radix, name) = (16, "hex")
        }
        let digits = String(Int64(value), radix: radix, uppercase: true)
        return RioCalcAnswer(value: digits, sentence: "\(source) in \(name) is \(digits)")
    }

    /// "the average of 85 and 92", "mean of 3 4 and 8": at least two numbers.
    private static func average(_ s: String) -> RioCalcAnswer? {
        guard let g = RioText.firstMatch(#"^(?:the )?(?:average|mean) of (.+)$"#, in: s), let list = g[1] else { return nil }
        var values: [Double] = []
        for part in list.components(separatedBy: " and ") {
            if let whole = number(part) {
                values.append(whole)
                continue
            }
            for word in part.split(separator: " ").map(String.init) {
                guard let one = number(word) else { return nil }
                values.append(one)
            }
        }
        guard values.count >= 2 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean.isFinite, abs(mean) < RioCalcEvaluator.limit else { return nil }
        let value = format(mean, significant: mathSignificantDigits)
        return RioCalcAnswer(value: value, sentence: "The average of \(list) is \(value)")
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
        guard let target = RioUnits.find(targetWords.joined(separator: " ")) else { return nil }
        let parsed: (Double, RioUnit, String?)
        if let height = feetAndInches(sourceWords), let inches = RioUnits.find("inches") {
            parsed = (height.inches, inches, height.spoken)
        } else if let (amount, unit) = quantityAndUnit(sourceWords, allowBareUnit: allowBareUnit) {
            parsed = (amount, unit, nil)
        } else {
            return nil
        }
        let (quantity, source, described) = parsed
        guard let result = RioUnits.convert(quantity, from: source, to: target), result.isFinite,
              abs(result) < RioCalcEvaluator.limit else { return nil }
        let given = format(quantity)
        let value = "\(format(result)) " + target.name(forFormatted: format(result))
        return RioCalcAnswer(value: value, sentence: "\(described ?? "\(given) \(source.name(forFormatted: given))") is \(value)")
    }

    /// "5 feet 10", "5 foot 10 inches", "six feet and two inches" -> 70 inches.
    private static func feetAndInches(_ words: [String]) -> (inches: Double, spoken: String)? {
        guard let feetIndex = words.firstIndex(where: { ["feet", "foot", "ft"].contains($0) }), feetIndex > 0,
              feetIndex < words.count - 1 else { return nil }
        var rest = Array(words[(feetIndex + 1)...])
        if rest.first == "and" { rest.removeFirst() }
        if let last = rest.last, ["inches", "inch"].contains(last) { rest.removeLast() }
        guard let feet = quantity(Array(words[..<feetIndex])), let inches = quantity(rest), feet >= 0, inches >= 0, inches < 12 else { return nil }
        return (feet * 12 + inches, "\(format(feet)) feet \(format(inches)) inches")
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
