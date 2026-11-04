import Foundation

// A small hand-written tokenizer, parser and evaluator. User text is never handed to NSExpression,
// a shell or any scripting engine: it becomes tokens from a fixed vocabulary, then a tree.

enum RioCalcToken: Equatable {
    case number(Double, isFraction: Bool, text: String)
    /// + - * / ^, "t" for a power said "to the 10th", "m" for mod and "C" for choose.
    case op(Character)
    case leftParen
    case rightParen
    case percent
    case of
    case squareRoot
    case squared
    case cubed
    case factorial
    /// log, ln, sin, cos, tan, as spoken ("sine").
    case function(RioCalcFunction, text: String)
    /// "log base 2 of 1024": the base follows.
    case logBase
    /// "cube root", "fourth root".
    case root(Double, text: String)
    /// "30 degrees" inside sin, cos or tan.
    case degrees
    case radians
}

enum RioCalcFunction: Equatable {
    case log10, ln, sin, cos, tan

    var isTrig: Bool { self == .sin || self == .cos || self == .tan }
}

enum RioCalcTokenizer {
    private static let phrases: [([String], RioCalcToken)] = [
        (["raised", "to", "the", "power", "of"], .op("^")), (["to", "the", "power", "of"], .op("^")),
        (["raised", "to", "the", "power"], .op("^")), (["to", "the", "power"], .op("^")), (["raised", "to"], .op("^")),
        (["multiplied", "by"], .op("*")), (["divided", "by"], .op("/")), (["square", "root", "of"], .squareRoot),
        (["square", "root"], .squareRoot), (["sqrt", "of"], .squareRoot), (["sqrt"], .squareRoot),
        (["per", "cent"], .percent),
        (["log", "base"], .logBase), (["logarithm", "base"], .logBase),
        (["natural", "log"], .function(.ln, text: "the natural log")), (["natural", "logarithm"], .function(.ln, text: "the natural log")),
        (["cube", "root", "of"], .root(3, text: "the cube root of")), (["cube", "root"], .root(3, text: "the cube root of")),
    ]

    /// Single words with a fixed meaning (round 3: mod, choose, logs, trig, e).
    private static let words: [String: RioCalcToken] = [
        "mod": .op("m"), "modulo": .op("m"), "modulus": .op("m"), "choose": .op("C"),
        "log": .function(.log10, text: "the log"), "logarithm": .function(.log10, text: "the log"),
        "ln": .function(.ln, text: "the natural log"),
        "sin": .function(.sin, text: "sine"), "sine": .function(.sin, text: "sine"),
        "cos": .function(.cos, text: "cosine"), "cosine": .function(.cos, text: "cosine"),
        "tan": .function(.tan, text: "tangent"), "tangent": .function(.tan, text: "tangent"),
        "degrees": .degrees, "degree": .degrees, "radians": .radians, "radian": .radians,
        "e": .number(M_E, isFraction: false, text: "e"),
    ]

    /// "fourth root of 81": an ordinal before "root".
    private static func nthRoot(_ words: [String], at index: Int) -> (token: RioCalcToken, consumed: Int)? {
        guard index + 1 < words.count, words[index + 1] == "root", let n = ordinal(words[index]), n >= 2 else { return nil }
        let consumed = index + 2 < words.count && words[index + 2] == "of" ? 3 : 2
        return (.root(n, text: "the \(words[index]) root of"), consumed)
    }

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

    /// "to the 4th (power)", "raised to the fourth", "2 to the 32": the exponent and how many words
    /// it took.
    private static func ordinalPower(_ words: [String], at index: Int) -> (value: Double, text: String, consumed: Int)? {
        var at = index
        if at < words.count, words[at] == "raised" { at += 1 }
        guard at + 2 < words.count, words[at] == "to", words[at + 1] == "the" else { return nil }
        let exponent = words[at + 2]
        guard let value = ordinal(exponent) ?? (RioText.matches(#"^\d{1,4}$"#, exponent) ? Double(exponent) : nil) else { return nil }
        var end = at + 3
        if end < words.count, words[end] == "power" { end += 1 }
        return (value, words[at + 2], end - index)
    }

    /// Nil as soon as any word is outside the vocabulary.
    static func tokenize(_ words: [String]) -> [RioCalcToken]? {
        var list: [RioCalcToken] = []
        // A spoken "negative 5" is the number -5, so "negative 5 squared" is 25 (round 3).
        var negateNext = false
        var tokens: [RioCalcToken] {
            get { list }
            set {
                guard negateNext, newValue.count == list.count + 1, let added = newValue.last else {
                    list = newValue
                    return
                }
                negateNext = false
                if case .number(let value, let isFraction, let text) = added {
                    list.append(.number(-value, isFraction: isFraction, text: "negative " + text))
                } else {
                    list.append(.op("-"))
                    list.append(added)
                }
            }
        }
        var index = 0
        outer: while index < words.count {
            if let power = ordinalPower(words, at: index) {
                // "t": a power said "to the 10th", so the answer repeats it that way.
                tokens.append(.op("t"))
                tokens.append(.number(power.value, isFraction: false, text: power.text))
                index += power.consumed
                continue outer
            }
            for (phrase, token) in phrases where index + phrase.count <= words.count && Array(words[index..<index + phrase.count]) == phrase {
                tokens.append(token)
                index += phrase.count
                continue outer
            }
            if let root = nthRoot(words, at: index) {
                tokens.append(root.token)
                index += root.consumed
                continue outer
            }
            let word = words[index]
            if let token = Self.words[word] {
                tokens.append(token)
                index += 1
                continue outer
            }
            switch word {
            case "+", "plus": tokens.append(.op("+"))
            case "negative":
                if negateNext { return nil }
                negateNext = true
            case "-", "minus": tokens.append(.op("-"))
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
        if negateNext { list.append(.op("-")) }
        return list
    }
}

indirect enum RioCalcNode {
    case number(Double, isFraction: Bool)
    case negate(RioCalcNode)
    case binary(Character, RioCalcNode, RioCalcNode)
    case percent(RioCalcNode)
    case squareRoot(RioCalcNode)
    case factorial(RioCalcNode)
    case function(RioCalcFunction, RioCalcNode)
    /// log base (first) of (second).
    case logBase(RioCalcNode, RioCalcNode)
    case root(Double, RioCalcNode)

    /// True when some division in the tree divides by zero ("100 divided by 0").
    var dividesByZero: Bool {
        switch self {
        case .number: return false
        case .negate(let inner), .percent(let inner), .squareRoot(let inner), .factorial(let inner),
             .function(_, let inner), .root(_, let inner):
            return inner.dividesByZero
        case .logBase(let base, let value): return base.dividesByZero || value.dividesByZero
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
            if case .op(let symbol)? = current, symbol == "*" || symbol == "/" || symbol == "m" || symbol == "C" {
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
        if case .op(let symbol)? = current, symbol == "^" || symbol == "t" {
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
        case .root(let degree, _):
            index += 1
            skipOf()
            guard let inner = unary() else { return nil }
            return .root(degree, inner)
        case .logBase:
            index += 1
            guard let base = primary() else { return nil }
            skipOf()
            guard let inner = unary() else { return nil }
            return .logBase(base, inner)
        case .function(let function, _):
            index += 1
            skipOf()
            guard function.isTrig else {
                guard let inner = unary() else { return nil }
                return .function(function, inner)
            }
            // "sin of pi over 6" is sin(pi/6): a spoken trig argument runs to the next plus or minus.
            guard var inner = term() else { return nil }
            if case .degrees? = current {
                index += 1
                inner = .binary("*", inner, .number(Double.pi / 180, isFraction: false))
            } else if case .radians? = current {
                index += 1
            }
            return .function(function, inner)
        default:
            return nil
        }
    }

    private mutating func skipOf() {
        if case .of? = current { index += 1 }
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
        case .function(let function, let inner):
            guard let value = evaluate(inner) else { return nil }
            switch function {
            case .log10: return value > 0 ? Foundation.log10(value) : nil
            case .ln: return value > 0 ? Foundation.log(value) : nil
            case .sin: return Foundation.sin(value)
            case .cos: return Foundation.cos(value)
            case .tan:
                // tan(90 degrees) has no value; cos is then (almost) zero.
                return abs(Foundation.cos(value)) < 1e-12 ? nil : Foundation.tan(value)
            }
        case .logBase(let baseNode, let inner):
            guard let base = evaluate(baseNode), let value = evaluate(inner), base > 0, base != 1, value > 0 else { return nil }
            return Foundation.log(value) / Foundation.log(base)
        case .root(let degree, let inner):
            guard let value = evaluate(inner), degree >= 2 else { return nil }
            let isOdd = degree.truncatingRemainder(dividingBy: 2) == 1
            if value < 0 { return isOdd ? -pow(-value, 1 / degree) : nil }
            return pow(value, 1 / degree)
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
            case "m":
                // Mathematical mod: the result has the divisor's sign ("-7 mod 3" is 2).
                guard rhs != 0 else { return nil }
                return lhs - rhs * (lhs / rhs).rounded(.down)
            case "C": return choose(lhs, rhs)
            case "^":
                guard abs(rhs) <= 1_000 else { return nil }
                let result = pow(lhs, rhs)
                return result.isFinite ? result : nil
            default: return nil
            }
        }
    }

    static let maxChoose = 1_000.0

    /// n choose k for whole numbers, 0 <= k <= n <= `maxChoose`.
    private static func choose(_ n: Double, _ k: Double) -> Double? {
        guard n == n.rounded(), k == k.rounded(), n >= 0, k >= 0, k <= n, n <= maxChoose else { return nil }
        let small = min(k, n - k)
        guard small > 0 else { return 1 }
        var result = 1.0
        for step in 1...Int(small) {
            result = result * (n - small + Double(step)) / Double(step)
        }
        return result.isFinite ? result.rounded() : nil
    }
}
