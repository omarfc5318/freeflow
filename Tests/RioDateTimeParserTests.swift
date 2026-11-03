import Foundation

/// Spoken date and time parsing with a fixed "now" (Tuesday 2026-11-03 10:00, UTC-8).
enum RioDateTimeParserTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -8 * 3600)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 1
        return calendar
    }()

    static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    static let now = date(2026, 11, 3, 10, 0)

    private static func parse(_ text: String) -> RioDateTimeParser.Result? {
        RioDateTimeParser.parse(text, now: now, calendar: calendar)
    }

    static func run() {
        let startCases: [(String, Date)] = [
            ("study session tomorrow at 7 pm", date(2026, 11, 4, 19)),
            ("study session tomorrow at 7pm", date(2026, 11, 4, 19)),
            ("study session tomorrow at 7 p.m.", date(2026, 11, 4, 19)),
            ("lunch with Sarah Friday at 1", date(2026, 11, 6, 13)),
            ("lunch on Friday at 1:30 pm", date(2026, 11, 6, 13, 30)),
            ("dentist next Tuesday at 3pm", date(2026, 11, 10, 15)),
            ("call Ali this Friday at 2:30 pm", date(2026, 11, 6, 14, 30)),
            ("meeting Tuesday at 4 pm", date(2026, 11, 10, 16)),
            ("meeting this Tuesday at 4 pm", date(2026, 11, 3, 16)),
            ("meeting next Friday at 9 am", date(2026, 11, 13, 9)),
            ("meeting Sunday at 5 pm", date(2026, 11, 8, 17)),
            ("gym today at 5 pm", date(2026, 11, 3, 17)),
            ("coffee at 3 pm", date(2026, 11, 3, 15)),
            ("coffee at 9 am", date(2026, 11, 4, 9)),
            ("breakfast tomorrow at 8 in the morning", date(2026, 11, 4, 8)),
            ("dinner tomorrow evening at 8", date(2026, 11, 4, 20)),
            ("dinner tonight at 8", date(2026, 11, 3, 20)),
            ("lunch tomorrow at noon", date(2026, 11, 4, 12)),
            ("lunch tomorrow at 12", date(2026, 11, 4, 12)),
            ("call tomorrow at 19:00", date(2026, 11, 4, 19)),
            ("call the day after tomorrow at 4 pm", date(2026, 11, 5, 16)),
            ("review on December 3rd at noon", date(2026, 12, 3, 12)),
            ("review Dec 3 at 4 pm", date(2026, 12, 3, 16)),
            ("party March 5 at 4 pm", date(2027, 3, 5, 16)),
            ("party on the 15th at 2 pm", date(2026, 11, 15, 14)),
            ("party on the 2nd at 2 pm", date(2026, 12, 2, 14)),
            ("exam 11/20 at 9 am", date(2026, 11, 20, 9)),
            ("exam 11/20/2026 at 9 am", date(2026, 11, 20, 9)),
            ("exam 1/5 at 9 am", date(2027, 1, 5, 9)),
            ("call in 2 days at 3 pm", date(2026, 11, 5, 15)),
            ("call in a week at 3 pm", date(2026, 11, 10, 15)),
            ("break in 2 hours", date(2026, 11, 3, 12)),
            ("break in 30 minutes", date(2026, 11, 3, 10, 30)),
            ("study from 3 to 4 pm tomorrow", date(2026, 11, 4, 15)),
            ("study from 10 to 11:30 am tomorrow", date(2026, 11, 4, 10)),
        ]
        for (text, expected) in startCases {
            guard let result = parse(text) else {
                fatalError("'\(text)' should parse")
            }
            TestSupport.expectEqual(result.start, expected)
        }

        let remainders: [(String, String)] = [
            ("study session tomorrow at 7 pm", "study session"),
            ("lunch with Sarah Friday at 1", "lunch with Sarah"),
            ("MAT108 office hours on Thursday at 2 pm", "MAT108 office hours"),
            ("dentist next Tuesday at 3pm", "dentist"),
            ("Hala sync tomorrow at 10 am for an hour", "Hala sync"),
            ("tomorrow at 10 am Hala sync", "Hala sync"),
            ("at 3 pm today call Ali", "call Ali"),
        ]
        for (text, expected) in remainders {
            TestSupport.expectEqual(parse(text)?.remainder, expected)
        }

        let durations: [(String, Int?)] = [
            ("sync tomorrow at 10 am for an hour", 60),
            ("sync tomorrow at 10 am for 30 minutes", 30),
            ("sync tomorrow at 10 am for 90 minutes", 90),
            ("sync tomorrow at 10 am for two hours", 120),
            ("sync tomorrow at 10 am for half an hour", 30),
            ("sync tomorrow at 10 am for an hour and a half", 90),
            ("sync tomorrow at 10 am for 1.5 hours", 90),
            ("sync tomorrow at 10 am for 45 mins", 45),
            ("sync tomorrow at 3 to 4 pm", 60),
            ("sync tomorrow from 10 to 11:30 am", 90),
            ("sync tomorrow at 10 am", nil),
        ]
        for (text, expected) in durations {
            TestSupport.expectEqual(parse(text)?.durationMinutes, expected)
        }

        // Not enough to schedule: no time, or a bare hour that could be am or pm.
        let rejected = [
            "tomorrow", "study session", "standup at 8", "standup tomorrow at 7:30", "tomorrow morning",
            "on Friday", "at the library", "party on the 15th",
        ]
        for text in rejected {
            TestSupport.expect(parse(text) == nil, "'\(text)' must not parse")
        }
        TestSupport.expectEqual(parse("sync tomorrow at 7:30 am")?.start, date(2026, 11, 4, 7, 30))
    }
}
