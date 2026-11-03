import Foundation

/// The instant calculator (builder L): arithmetic, spoken numbers, percentages, unit conversions,
/// temperature and time zones with an injected clock, plus garbage that must return nil and
/// phrases that must never be stolen from the volume, brightness and timer parsers.
enum RioCalculatorTests {
    /// Tuesday 2026-11-03 14:05:09 UTC. "Here" is Los Angeles (PST, UTC-8 from 2026-11-01).
    private static let now = Date(timeIntervalSince1970: 1_793_714_709)
    private static let here = TimeZone(identifier: "America/Los_Angeles")!

    private static func value(_ text: String) -> String? {
        RioCalculator.evaluate(text, now: now, timeZone: here)?.value
    }

    private static func check(_ cases: [(String, String)], _ group: String) {
        for (input, expected) in cases {
            ETest.eq(value(input), expected, "\(group): \(input)")
        }
    }

    static func run() {
        arithmetic()
        spokenNumbers()
        percentages()
        unitConversions()
        temperature()
        timeZones()
        garbage()
        sentences()
        phraseGate()
        throughTheRealParser()
    }

    private static func arithmetic() {
        check([
            ("2 plus 2", "4"), ("what's 2 + 2", "4"), ("what is 12 times 12", "144"), ("7 x 8", "56"),
            ("what's 100 divided by 8", "12.5"), ("10 minus 3", "7"), ("what's 2 plus 3 times 4", "14"),
            ("(2 + 3) * 4", "20"), ("what's 2 to the power of 10", "1,024"), ("2 ^ 8", "256"),
            ("2 ^ 3 ^ 2", "512"), ("7 squared", "49"), ("3 cubed", "27"), ("square root of 144", "12"),
            ("what's the square root of 2", "1.4142"), ("1,000 + 250", "1,250"), ("0.1 + 0.2", "0.3"),
            ("10 / 4", "2.5"), ("what's 15 over 3", "5"), ("minus 5 plus 8", "3"), ("-5 * -5", "25"),
            ("what's 3.5 times 2", "7"), ("calculate 45 divided by 9", "5"), ("how much is 19 plus 23", "42"),
            ("what's 1000000 times 3", "3,000,000"), ("2 million plus 3 million", "5,000,000"),
            ("1.5 billion divided by 3", "500,000,000"), ("-2 ^ 2", "-4"), ("what's 6 times 7?", "42"),
            ("5 × 5", "25"), ("20 ÷ 4", "5"), ("10 − 4", "6"), ("what is 3 plus 4 equals", "7"),
        ], "arithmetic")
    }

    private static func spokenNumbers() {
        check([
            ("two hundred and five plus ten", "215"), ("what's five times six", "30"),
            ("forty two plus eight", "50"), ("forty-two plus eight", "50"),
            ("three point five times two", "7"), ("one hundred twenty three plus one", "124"),
            ("two thousand five hundred minus one thousand", "1,500"), ("a hundred divided by four", "25"),
            ("one and a half times four", "6"), ("2 and a half times 4", "10"),
            ("what's nineteen plus twenty one", "40"), ("twelve hundred plus five", "1,205"),
            ("one million divided by four", "250,000"), ("two hundred and five miles in km", "329.9155 kilometers"),
        ], "spoken")
    }

    private static func percentages() {
        check([
            ("15% of 84", "12.6"), ("what's 15 percent of 84", "12.6"), ("what's 20% of 150", "30"),
            ("a third of 90", "30"), ("half of 50", "25"), ("a quarter of 200", "50"),
            ("two thirds of 90", "60"), ("three quarters of 80", "60"), ("what's 10% of 250", "25"),
            ("20% off 80", "64"), ("20 percent off of 80", "64"), ("add 15% to 80", "92"), ("80 plus 15%", "92"),
            ("100 - 10%", "90"), ("subtract 10 percent from 50", "45"),
            ("what percent is 25 of 200", "12.5%"), ("25 is what percent of 200", "12.5%"),
            ("what's 18% tip on 45", "8.1"), ("fifteen percent of eighty four", "12.6"),
            ("7.5% of 200", "15"), ("200% of 5", "10"), ("what's 15% of $84", "12.6"),
            ("increase 80 by 25 percent", "100"), ("decrease 200 by 10 percent", "180"),
        ], "percent")
    }

    private static func unitConversions() {
        check([
            ("5 miles in km", "8.0467 kilometers"), ("convert 5 miles to kilometers", "8.0467 kilometers"),
            ("what's 5 miles in kilometers", "8.0467 kilometers"), ("10 km to miles", "6.2137 miles"),
            ("1 mile in feet", "5,280 feet"), ("a pound in kg", "0.4536 kilograms"),
            ("how many ounces in a pound", "16 ounces"), ("how many kilometers in 5 miles", "8.0467 kilometers"),
            ("how many kilometers are in 5 miles", "8.0467 kilometers"),
            ("2 cups in ml", "473.1765 milliliters"), ("1 gallon to liters", "3.7854 liters"),
            ("3 tablespoons in teaspoons", "9 teaspoons"), ("90 mph in km/h", "144.841 kilometers per hour"),
            ("100 km/h to mph", "62.1371 miles per hour"), ("10 gb in mb", "10,000 megabytes"),
            ("1 tb to gb", "1,000 gigabytes"), ("1.5 hours in minutes", "90 minutes"),
            ("3 hours in seconds", "10,800 seconds"), ("2 days in hours", "48 hours"), ("a week in days", "7 days"),
            ("500 grams in ounces", "17.637 ounces"), ("150 lbs in kg", "68.0389 kilograms"),
            ("6 feet in cm", "182.88 centimeters"), ("10 meters in inches", "393.7008 inches"),
            ("how many minutes in a day", "1,440 minutes"), ("1 knot in mph", "1.1508 miles per hour"),
            ("5 liters in gallons", "1.3209 gallons"), ("half a mile in meters", "804.672 meters"),
            ("1 inch in mm", "25.4 millimeters"), ("2 kg to pounds", "4.4092 pounds"),
        ], "units")
    }

    private static func temperature() {
        check([
            ("100 fahrenheit in celsius", "37.7778 degrees Celsius"), ("30 celsius to fahrenheit", "86 degrees Fahrenheit"),
            ("0 c in f", "32 degrees Fahrenheit"), ("72 degrees fahrenheit to celsius", "22.2222 degrees Celsius"),
            ("300 kelvin to celsius", "26.85 degrees Celsius"), ("-40 f in c", "-40 degrees Celsius"),
            ("what's 25 celsius in fahrenheit", "77 degrees Fahrenheit"), ("100 c to kelvin", "373.15 kelvin"),
            ("72°F to °C", "22.2222 degrees Celsius"),
        ], "temperature")
    }

    private static func timeZones() {
        check([
            ("what's 9 AM Doha time here", "10 PM yesterday"), ("9 AM Doha time in my time", "10 PM yesterday"),
            ("nine am doha time here", "10 PM yesterday"), ("what time is it in Doha", "5:05 PM"),
            ("time in Tokyo", "11:05 PM"), ("what time is it in London", "2:05 PM"),
            ("what time is it in New York", "9:05 AM"), ("what time is it in Dubai", "6:05 PM"),
            ("3 pm here in Doha", "2 AM tomorrow"), ("12 pm London time here", "4 AM"),
            ("9:30 pm Tokyo time here", "4:30 AM"), ("convert 3pm eastern to doha", "11 PM"),
            ("what time is it", "6:05 AM"), ("what's the time", "6:05 AM"), ("what time is it in Davis", "6:05 AM"),
            ("noon Tokyo time here", "7 PM yesterday"), ("what time is it in UTC", "2:05 PM"),
            ("what's 8 pm in Riyadh here", "9 AM"), ("9 am pst in doha", "8 PM"),
        ], "time zones")
    }

    private static func garbage() {
        let nils = [
            "", "   ", "hello", "open Chrome", "volume 40", "set volume to 40", "turn the volume up 10 percent",
            "10 minute timer", "set a timer for 5 minutes", "timer 10 minutes", "brightness 50", "5", "five",
            "twenty percent", "2 +", "(2 + 3", "2 + 3)", "5 / 0", "one two three", "12 12", "what's the weather",
            "what is the capital of France", "remember my locker code is 4321", "note: 2 plus 2",
            "banana plus apple", "what's up", "call mom", "10 minutes", "5 miles", "5 miles in", "in km",
            "2 ^ 100000", "0 ^ -1", "square root of -4", "5 miles in kg", "5 foo in km", "what time is it in Atlantis",
            "-5", "plus", "x", "5 of 10", "9999999999 times 9999999999 times 9999999999", "what time is my meeting",
            "go to chrome", "text mom 5 plus 3", "play song 5", "what's 5 percent", "1 / 0", "0 / 0", "9 am",
            "10 percent brightness",
        ]
        for input in nils {
            ETest.eq(value(input), nil, "garbage must be nil: '\(input)'")
        }
    }

    private static func sentences() {
        ETest.eq(RioCalculator.evaluate("15% of 84", now: now, timeZone: here)?.sentence, "15 percent of 84 is 12.6")
        ETest.eq(RioCalculator.evaluate("2 plus 2", now: now, timeZone: here)?.sentence, "2 plus 2 is 4")
        ETest.eq(RioCalculator.evaluate("5 miles in km", now: now, timeZone: here)?.sentence, "5 miles is 8.0467 kilometers")
        ETest.eq(
            RioCalculator.evaluate("what's 9 AM Doha time here", now: now, timeZone: here)?.sentence,
            "9 AM in Doha is 10 PM yesterday here"
        )
        ETest.eq(RioCalculator.evaluate("what time is it in Doha", now: now, timeZone: here)?.sentence, "It's 5:05 PM in Doha")
        ETest.eq(RioCalculator.evaluate("what time is it", now: now, timeZone: here)?.sentence, "It's 6:05 AM")
        ETest.eq(RioCalculator.evaluate("3 pm here in Doha", now: now, timeZone: here)?.sentence, "3 PM here is 2 AM tomorrow in Doha")
        // Summer time moves the answer: the clock is injected, so this is deterministic.
        let july = Date(timeIntervalSince1970: 1_784_815_509)   // 2026-07-23 14:05:09 UTC
        ETest.eq(RioCalculator.evaluate("what time is it in New York", now: july, timeZone: here)?.value, "10:05 AM")
        ETest.eq(RioCalculator.evaluate("what time is it", now: july, timeZone: here)?.value, "7:05 AM")
    }

    // MARK: Phrase gate

    private static func phraseGate() {
        ETest.eq(RioMathPhrases.parse(raw: "what's 15% of 84", simplified: RioText.simplify("what's 15% of 84")), .calculate(expression: "what's 15% of 84"))
        ETest.eq(RioMathPhrases.parse(raw: "5 miles in km.", simplified: ""), .calculate(expression: "5 miles in km"))
        ETest.eq(RioMathPhrases.parse(raw: "2 plus 2 please", simplified: ""), .calculate(expression: "2 plus 2"))
        for stolen in ["volume 40", "set the volume to forty", "10 minute timer", "set a timer for 10 minutes", "brightness 50",
                       "make it 50 percent brighter", "remind me in 5 minutes", "open Chrome", "what's the weather"] {
            ETest.eq(RioMathPhrases.parse(raw: stolen, simplified: RioText.simplify(stolen)), nil, "math must not claim '\(stolen)'")
        }
        ETest.eq(RioMathPhrases.wholeUtterance("open Chrome and what's 2 plus 3"), nil)
    }

    private static func throughTheRealParser() {
        let parser = RioActionParser(installedApps: [])
        func actions(_ text: String) -> [RioAction]? {
            if case .actions(let list) = parser.parse(text) { return list }
            return nil
        }
        ETest.eq(actions("Rio, what's 2 plus 3"), [.calculate(expression: "what's 2 plus 3")])
        ETest.eq(actions("what's two hundred and five plus ten"), [.calculate(expression: "what's two hundred and five plus ten")])
        ETest.eq(actions("what's 15% of 84"), [.calculate(expression: "what's 15% of 84")])
        ETest.eq(actions("5 miles in km"), [.calculate(expression: "5 miles in km")])
        ETest.eq(actions("what's 9 AM Doha time here"), [.calculate(expression: "what's 9 AM Doha time here")])
        // B's and G's phrases keep their own commands.
        ETest.eq(actions("volume 40"), [.volume(.set(40))])
        ETest.eq(actions("Rio, set the volume to forty"), [.volume(.set(40))])
        ETest.eq(actions("10 minute timer"), [.startTimer(seconds: 600, label: nil)])
        ETest.eq(actions("set a timer for 2 and a half minutes"), [.startTimer(seconds: 150, label: nil)])
        ETest.eq(actions("volume up and open Chrome"), [.volume(.up), .openApp(name: "Chrome")])
    }
}
