import Foundation

enum RioUnitCategory: Equatable {
    case length, mass, volume, speed, data, time, temperature
}

struct RioUnit: Equatable {
    let category: RioUnitCategory
    /// Multiply by this to reach the category's base unit (metre, kilogram, litre, m/s, byte, second).
    let factor: Double
    let singular: String
    let plural: String

    func name(forFormatted formatted: String) -> String { formatted == "1" ? singular : plural }
}

/// The unit table and conversions. Pure.
enum RioUnits {
    private static func define(
        _ category: RioUnitCategory, _ factor: Double, _ singular: String, _ plural: String, _ aliases: [String]
    ) -> [(String, RioUnit)] {
        let unit = RioUnit(category: category, factor: factor, singular: singular, plural: plural)
        return ([singular, plural] + aliases).map { ($0, unit) }
    }

    private static let table: [String: RioUnit] = {
        var entries: [(String, RioUnit)] = []
        entries += define(.length, 0.001, "millimeter", "millimeters", ["mm", "millimetre", "millimetres"])
        entries += define(.length, 0.01, "centimeter", "centimeters", ["cm", "centimetre", "centimetres"])
        entries += define(.length, 1, "meter", "meters", ["m", "metre", "metres"])
        entries += define(.length, 1_000, "kilometer", "kilometers", ["km", "kilometre", "kilometres"])
        entries += define(.length, 0.0254, "inch", "inches", [])
        entries += define(.length, 0.3048, "foot", "feet", ["ft", "foots"])
        entries += define(.length, 0.9144, "yard", "yards", ["yd", "yds"])
        entries += define(.length, 1_609.344, "mile", "miles", ["mi"])
        entries += define(.length, 1_852, "nautical mile", "nautical miles", ["nmi"])
        entries += define(.mass, 1e-6, "milligram", "milligrams", ["mg"])
        entries += define(.mass, 0.001, "gram", "grams", ["g", "gm", "gms"])
        entries += define(.mass, 1, "kilogram", "kilograms", ["kg", "kgs", "kilo", "kilos"])
        entries += define(.mass, 0.028_349_523_125, "ounce", "ounces", ["oz"])
        entries += define(.mass, 0.453_592_37, "pound", "pounds", ["lb", "lbs"])
        entries += define(.mass, 6.350_293_18, "stone", "stone", ["st"])
        entries += define(.mass, 1_000, "tonne", "tonnes", ["metric ton", "metric tons"])
        entries += define(.mass, 907.184_74, "ton", "tons", [])
        entries += define(.volume, 0.001, "milliliter", "milliliters", ["ml", "millilitre", "millilitres"])
        entries += define(.volume, 1, "liter", "liters", ["l", "litre", "litres"])
        entries += define(.volume, 0.004_928_921_593_75, "teaspoon", "teaspoons", ["tsp", "tsps"])
        entries += define(.volume, 0.014_786_764_781_25, "tablespoon", "tablespoons", ["tbsp", "tbsps"])
        entries += define(.volume, 0.029_573_529_562_5, "fluid ounce", "fluid ounces", ["fl oz", "floz"])
        entries += define(.volume, 0.236_588_236_5, "cup", "cups", [])
        entries += define(.volume, 0.473_176_473, "pint", "pints", ["pt"])
        entries += define(.volume, 0.946_352_946, "quart", "quarts", ["qt"])
        entries += define(.volume, 3.785_411_784, "gallon", "gallons", ["gal"])
        entries += define(.speed, 1, "meter per second", "meters per second", ["mps", "metre per second", "metres per second"])
        entries += define(.speed, 1_000.0 / 3_600.0, "kilometer per hour", "kilometers per hour", ["kmh", "kph", "kilometre per hour", "kilometres per hour"])
        entries += define(.speed, 0.447_04, "mile per hour", "miles per hour", ["mph"])
        entries += define(.speed, 1_852.0 / 3_600.0, "knot", "knots", ["kt", "kts"])
        entries += define(.speed, 0.3048, "foot per second", "feet per second", ["fps"])
        entries += define(.data, 0.125, "bit", "bits", [])
        entries += define(.data, 1, "byte", "bytes", [])
        entries += define(.data, 1e3, "kilobyte", "kilobytes", ["kb"])
        entries += define(.data, 1e6, "megabyte", "megabytes", ["mb", "meg", "megs"])
        entries += define(.data, 1e9, "gigabyte", "gigabytes", ["gb", "gig", "gigs"])
        entries += define(.data, 1e12, "terabyte", "terabytes", ["tb"])
        entries += define(.data, 1e15, "petabyte", "petabytes", ["pb"])
        entries += define(.time, 0.001, "millisecond", "milliseconds", ["ms"])
        entries += define(.time, 1, "second", "seconds", ["sec", "secs", "s"])
        entries += define(.time, 60, "minute", "minutes", ["min", "mins"])
        entries += define(.time, 3_600, "hour", "hours", ["hr", "hrs", "h"])
        entries += define(.time, 86_400, "day", "days", [])
        entries += define(.time, 604_800, "week", "weeks", [])
        entries += define(.time, 2_629_800, "month", "months", [])
        entries += define(.time, 31_557_600, "year", "years", ["yr", "yrs"])
        entries += define(.temperature, 1, "degree Celsius", "degrees Celsius", ["celsius", "centigrade", "c"])
        entries += define(.temperature, 2, "degree Fahrenheit", "degrees Fahrenheit", ["fahrenheit", "f"])
        entries += define(.temperature, 3, "kelvin", "kelvin", ["k"])
        var result: [String: RioUnit] = [:]
        for (key, unit) in entries where result[key] == nil { result[key] = unit }
        return result
    }()

    /// Finds a unit by spoken name: "km", "kilometers", "degrees fahrenheit", "miles per hour".
    static func find(_ spoken: String) -> RioUnit? {
        var text = RioText.collapseWhitespace(spoken.lowercased())
        text = RioText.replacing(#"^(?:degrees?|deg)\s+"#, with: "", in: text)
        guard !text.isEmpty else { return nil }
        if let unit = table[text] { return unit }
        for suffix in ["es", "s"] where text.hasSuffix(suffix) && text.count > suffix.count + 1 {
            if let unit = table[String(text.dropLast(suffix.count))] { return unit }
        }
        return nil
    }

    static func convert(_ value: Double, from: RioUnit, to: RioUnit) -> Double? {
        guard from.category == to.category else { return nil }
        guard from.category == .temperature else { return value * from.factor / to.factor }
        let celsius: Double
        switch from.factor {
        case 1: celsius = value
        case 2: celsius = (value - 32) * 5 / 9
        default: celsius = value - 273.15
        }
        switch to.factor {
        case 1: return celsius
        case 2: return celsius * 9 / 5 + 32
        default: return celsius + 273.15
        }
    }
}
