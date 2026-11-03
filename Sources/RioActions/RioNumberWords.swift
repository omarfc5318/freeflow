import Foundation

/// Spoken numbers for the calculator and time parser ("two hundred and five", "three point five",
/// "a third", "one and a half"). Pure: words in, a value and the number of words used out.
enum RioNumberWords {
    struct Parsed: Equatable {
        let value: Double
        let consumed: Int
        let isFraction: Bool
    }

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    static let scales: [String: Double] = [
        "thousand": 1e3, "million": 1e6, "billion": 1e9, "trillion": 1e12,
    ]
    private static let singularFractions: [String: Double] = [
        "half": 2, "third": 3, "quarter": 4, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7,
        "eighth": 8, "ninth": 9, "tenth": 10,
    ]
    private static let pluralFractions: [String: Double] = [
        "halves": 2, "thirds": 3, "quarters": 4, "fourths": 4, "fifths": 5, "sixths": 6, "sevenths": 7,
        "eighths": 8, "ninths": 9, "tenths": 10,
    ]

    private enum Kind { case none, unit, teen, tens, hundred, scale }

    static func isNumberWord(_ word: String) -> Bool {
        units[word] != nil || tens[word] != nil
    }

    static func parse(_ words: [String], at start: Int) -> Parsed? {
        guard start < words.count else { return nil }
        let first = words[start]
        if first == "half" {
            var next = start + 1
            if next < words.count, words[next] == "a" || words[next] == "an" { next += 1 }
            return Parsed(value: 0.5, consumed: next - start, isFraction: true)
        }
        if ["a", "an", "one"].contains(first), start + 1 < words.count, let den = singularFractions[words[start + 1]] {
            return Parsed(value: 1 / den, consumed: 2, isFraction: true)
        }
        guard let integer = composeInteger(words, at: start) else { return nil }
        var value = integer.value
        var end = start + integer.consumed
        if end < words.count, words[end] == "point" {
            var digits = ""
            var cursor = end + 1
            while cursor < words.count, let digit = units[words[cursor]], digit < 10 {
                digits += String(digit)
                cursor += 1
            }
            if !digits.isEmpty, let fraction = Double("0." + digits) {
                value += fraction
                end = cursor
            }
        }
        if let extra = andAHalf(words, at: end) {
            return Parsed(value: value + extra.value, consumed: end + extra.consumed - start, isFraction: false)
        }
        if end < words.count, let den = pluralFractions[words[end]], value >= 1 {
            return Parsed(value: value / den, consumed: end + 1 - start, isFraction: true)
        }
        return Parsed(value: value, consumed: end - start, isFraction: false)
    }

    /// "and a half" / "and a quarter" right after a number.
    static func andAHalf(_ words: [String], at index: Int) -> (value: Double, consumed: Int)? {
        guard index + 2 < words.count, words[index] == "and", words[index + 1] == "a" else { return nil }
        switch words[index + 2] {
        case "half": return (0.5, 3)
        case "quarter": return (0.25, 3)
        default: return nil
        }
    }

    private static func composeInteger(_ words: [String], at start: Int) -> (value: Double, consumed: Int)? {
        var total = 0.0
        var current = 0.0
        var last = Kind.none
        var index = start
        var any = false
        loop: while index < words.count {
            let word = words[index]
            if (word == "a" || word == "an"), index == start, index + 1 < words.count,
               words[index + 1] == "hundred" || scales[words[index + 1]] != nil {
                current = 1
                last = .unit
                index += 1
                continue
            }
            if let unit = units[word] {
                if unit == 0 {
                    guard index == start else { break loop }
                    any = true
                    last = .unit
                    index += 1
                    continue
                }
                if unit < 10 {
                    guard last == .none || last == .tens || last == .hundred || last == .scale else { break loop }
                    last = .unit
                } else {
                    guard last == .none || last == .hundred || last == .scale else { break loop }
                    last = .teen
                }
                current += Double(unit)
            } else if let ten = tens[word] {
                guard last == .none || last == .hundred || last == .scale else { break loop }
                current += Double(ten)
                last = .tens
            } else if word == "hundred" {
                guard last == .unit || last == .teen || last == .tens, current >= 1, current <= 99 else { break loop }
                current *= 100
                last = .hundred
            } else if let scale = scales[word] {
                guard current > 0, last != .none, last != .scale else { break loop }
                total += current * scale
                current = 0
                last = .scale
            } else if word == "and" {
                guard index + 1 < words.count, isNumberWord(words[index + 1]), units[words[index + 1]] != 0,
                      last == .hundred || last == .scale else { break loop }
                index += 1
                continue
            } else {
                break loop
            }
            any = true
            index += 1
        }
        guard any else { return nil }
        return (total + current, index - start)
    }
}
