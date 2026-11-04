import Foundation

// A small hand-written tokenizer, parser and evaluator. User text is never handed to NSExpression,
// a shell or any scripting engine: it becomes tokens from a fixed vocabulary, then a tree.

enum RioCalcToken: Equatable {
    case number(Double, isFraction: Bool, text: String)
    case op(Character)
    case leftParen
    case rightParen
    case percent
    case of
    case squareRoot
    case squared
    case cubed
    case factorial
}

enum RioCalcTokenizer {
    private static let phrases: [([String], RioCalcToken)] = [
        (["raised", "to", "the", "power", "of"], .op("^")), (["to", "the", "power", "of"], .op("^")),
        (["raised", "to", "the", "power"], .op("^")), (["to", "the", "power"], .op("^")), (["raised", "to"], .op("^")),
        (["multiplied", "by"], .op("*")), (["divided", "by"], .op("/")), (["square", "root", "of"], .squareRoot),
        (["square", "root"], .squareRoot), (["sqrt", "of"], .squareRoot), (["sqrt"], .squareRoot),
        (["per", "cent"], .percent),
    ]

    private static func isDigits(_ word: String) -> Bool {
        // "1e6" is scientific notation; Double reads it.
        RioText.matches(#"^(?:\d+(?:\.\d+)?|\.\d+)(?:e\d{1,3})?$"#, word)
    }

    private static let ordinalWords: [String: Double] = [
        "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
        "eleventh": 11, "twelfth": 12,
    ]

    /// "4th", "fourth" -> 4.
    private static func ordinal(_ word: String) -> Double? {
        if let groups = RioText.firstMatch(#"^(\d{1,3})(?:st|nd|rd|th)$"#, in: word), let digits = groups[1] { return Double(digits) }
        return ordinalWords[word]
    }

    /// "to the 4th (power)", "raised to the fourth": the exponent and how many words it took.
    private static func ordinalPower(_ words: [String], at index: Int) -> (value: Double, text: String, consumed: Int)? {
        var at = index
        if at < words.count, words[at] == "raised" { at += 1 }
        guard at + 2 < words.count, words[at] == "to", words[at + 1] == "the", let value = ordinal(words[at + 2]) else { return nil }
        var end = at + 3
        if end < words.count, words[end] == "power" { end += 1 }
        return (value, words[at + 2], end - index)
    }

    /// Nil as soon as any word is outside the vocabulary.
    static func tokenize(_ words: [String]) -> [RioCalcToken]? {
        var tokens: [RioCalcToken] = []
        var index = 0
        outer: while index < words.count {
            if let power = ordinalPower(words, at: index) {
                tokens.append(.op("^"))
                tokens.append(.number(power.value, isFraction: false, text: power.text))
                index += power.consumed
                continue outer
            }
            for (phrase, token) in phrases where index + phrase.count <= words.count && Array(words[index..<index + phrase.count]) == phrase {
                tokens.append(token)
                index += phrase.count
                continue outer
            }
            let word = words[index]
            switch word {
            case "+", "plus": tokens.append(.op("+"))
            case "-", "minus", "negative": tokens.append(.op("-"))
            case "*", "times": tokens.append(.op("*"))
            case "/", "over": tokens.append(.op("/"))
            case "^": tokens.append(.op("^"))
            case "(": tokens.append(.leftParen)
            case ")": tokens.append(.rightParen)
            case "percent": tokens.append(.percent)
            case "of": tokens.append(.of)
            case "squared": tokens.append(.squared)
            case "cubed": tokens.append(.cubed)
            case "factorial": tokens.append(.factorial)
            case "pi": tokens.append(.number(Double.pi, isFraction: false, text: "pi"))
            case "x":
                guard let last = tokens.last, case .number = last else { return nil }
                tokens.append(.op("*"))
            default:
                if isDigits(word), var value = Double(word) {
                    var end = index + 1
                    var text = word
                    if end < words.count, let scale = RioNumberWords.scales[words[end]] {
                        value *= scale
                        text += " " + words[end]
                        end += 1
                    }
                    if let extra = RioNumberWords.andAHalf(words, at: end) {
                        value += extra.value
                        text += " and a " + words[end + 2]
                        end += extra.consumed
                    }
                    tokens.append(.number(value, isFraction: false, text: text))
                    index = end
                    continue outer
                }
                guard let parsed = RioNumberWords.parse(words, at: index) else { return nil }
                let text = words[index..<index + parsed.consumed].joined(separator: " ")
                tokens.append(.number(parsed.value, isFraction: parsed.isFraction, text: text))
                index += parsed.consumed
                continue outer
            }
            index += 1
        }
        return tokens
    }
}

indirect enum RioCalcNode {
    case number(Double, isFraction: Bool)
    case negate(RioCalcNode)
    case binary(Character, RioCalcNode, RioCalcNode)
    case percent(RioCalcNode)
    case squareRoot(RioCalcNode)
    case factorial(RioCalcNode)

    /// True when some division in the tree divides by zero ("100 divided by 0").
    var dividesByZero: Bool {
        switch self {
        case .number: return false
        case .negate(let inner), .percent(let inner), .squareRoot(let inner), .factorial(let inner): return inner.dividesByZero
        case .binary(let symbol, let left, let right):
            if symbol == "/", let divisor = RioCalcEvaluator.value(right), divisor == 0 { return true }
            return left.dividesByZero || right.dividesByZero
        }
    }

    /// A lone number, a negative number or a lone percentage is not a calculation.
    var isTrivial: Bool {
        switch self {
        case .number: return true
        case .negate(let inner), .percent(let inner): return inner.isTrivial
        default: return false
        }
    }
}

struct RioCalcParser {
    private let tokens: [RioCalcToken]
    private var index = 0

    private init(tokens: [RioCalcToken]) { self.tokens = tokens }

    static func parse(_ tokens: [RioCalcToken]) -> RioCalcNode? {
        guard !tokens.isEmpty else { return nil }
        var parser = RioCalcParser(tokens: tokens)
        guard let node = parser.expression(), parser.index == tokens.count else { return nil }
        return node
    }

    private var current: RioCalcToken? { index < tokens.count ? tokens[index] : nil }

    private mutating func expression() -> RioCalcNode? {
        guard var left = term() else { return nil }
        while case .op(let symbol)? = current, symbol == "+" || symbol == "-" {
            index += 1
            guard let right = term() else { return nil }
            left = .binary(symbol, left, right)
        }
        return left
    }

    private mutating func term() -> RioCalcNode? {
        guard var left = unary() else { return nil }
        while true {
            if case .op(let symbol)? = current, symbol == "*" || symbol == "/" {
                index += 1
                guard let right = unary() else { return nil }
                left = .binary(symbol, left, right)
            } else if case .of? = current {
                switch left {
                case .percent, .number(_, true): break
                // "1/3 of 90": a written fraction.
                case .binary("/", .number, .number): break
                default: return nil
                }
                index += 1
                guard var right = unary() else { return nil }
                // "50% of 50% of 80": each further "of" needs a percentage or fraction before it.
                while case .of? = current {
                    switch right {
                    case .percent, .number(_, true): break
                    default: return nil
                    }
                    index += 1
                    guard let next = unary() else { return nil }
                    right = .binary("*", right, next)
                }
                left = .binary("*", left, right)
            } else {
                return left
            }
        }
    }

    private mutating func unary() -> RioCalcNode? {
        if case .op(let symbol)? = current, symbol == "-" || symbol == "+" {
            index += 1
            guard let inner = unary() else { return nil }
            return symbol == "-" ? .negate(inner) : inner
        }
        return power()
    }

    private mutating func power() -> RioCalcNode? {
        guard let base = postfix() else { return nil }
        if case .op("^")? = current {
            index += 1
            guard let exponent = unary() else { return nil }
            return .binary("^", base, exponent)
        }
        return base
    }

    private mutating func postfix() -> RioCalcNode? {
        guard var node = primary() else { return nil }
        while let token = current {
            switch token {
            case .squared: node = .binary("^", node, .number(2, isFraction: false))
            case .cubed: node = .binary("^", node, .number(3, isFraction: false))
            case .factorial: node = .factorial(node)
            case .percent: node = .percent(node)
            default: return node
            }
            index += 1
        }
        return node
    }

    private mutating func primary() -> RioCalcNode? {
        guard let token = current else { return nil }
        switch token {
        case .number(let value, let isFraction, _):
            index += 1
            return .number(value, isFraction: isFraction)
        case .leftParen:
            index += 1
            guard let inner = expression(), case .rightParen? = current else { return nil }
            index += 1
            return inner
        case .squareRoot:
            index += 1
            guard let inner = unary() else { return nil }
            return .squareRoot(inner)
        default:
            return nil
        }
    }
}

enum RioCalcEvaluator {
    static let limit = 1e15
    static let maxFactorial = 20.0

    static func value(_ node: RioCalcNode) -> Double? {
        guard let result = evaluate(node), result.isFinite, abs(result) < limit else { return nil }
        return result
    }

    private static func evaluate(_ node: RioCalcNode) -> Double? {
        switch node {
        case .number(let value, _): return value
        case .negate(let inner): return evaluate(inner).map { -$0 }
        case .percent(let inner): return evaluate(inner).map { $0 / 100 }
        case .squareRoot(let inner):
            guard let value = evaluate(inner), value >= 0 else { return nil }
            return value.squareRoot()
        case .factorial(let inner):
            // Whole numbers only, and small enough to stay exact-ish (170! is the last finite Double).
            guard let value = evaluate(inner), value >= 0, value <= maxFactorial, value == value.rounded() else { return nil }
            return (0..<Int(value)).reduce(1.0) { $0 * Double($1 + 1) }
        case .binary(let symbol, let left, let right):
            guard let lhs = evaluate(left) else { return nil }
            if (symbol == "+" || symbol == "-"), case .percent(let inner) = right {
                // "80 plus 15%" means 15 percent of 80 added on.
                guard let rate = evaluate(inner) else { return nil }
                let delta = lhs * rate / 100
                return symbol == "+" ? lhs + delta : lhs - delta
            }
            guard let rhs = evaluate(right) else { return nil }
            switch symbol {
            case "+": return lhs + rhs
            case "-": return lhs - rhs
            case "*": return lhs * rhs
            case "/": return rhs == 0 ? nil : lhs / rhs
            case "^":
                guard abs(rhs) <= 1_000 else { return nil }
                let result = pow(lhs, rhs)
                return result.isFinite ? result : nil
            default: return nil
            }
        }
    }
}
