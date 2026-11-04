import Foundation

/// Local reminder phrases with a fixed "now" (Tuesday 2026-11-03 10:00, UTC-8): the owner's
/// own words become `.createReminder` without the network.
enum RioReminderPhrasesTests {
    private static let calendar = RioDateTimeParserTests.calendar
    private static let now = RioDateTimeParserTests.now
    private static func date(_ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        RioDateTimeParserTests.date(2026, mo, d, h, mi)
    }

    private static func parse(_ text: String) -> RioAction? {
        RioReminderPhrases.parse(text, now: now, calendar: calendar)
    }

    static func run() {
        dated()
        undated()
        leftAlone()
        throughTheRealParser()
        dayOnly()
        timeOnly()
    }

    /// "remind me in 10 minutes": a time and no title is a plain "Reminder" (finding 55).
    private static func timeOnly() {
        ETest.eq(parse("remind me in 10 minutes"), .createReminder(title: "Reminder", due: date(11, 3, 10, 10)))
        ETest.eq(parse("Rio remind me in five minutes"), .createReminder(title: "Reminder", due: date(11, 3, 10, 5)))
        ETest.eq(parse("remind me"), nil)
    }

    private static func dated() {
        let cases: [(String, String, Date)] = [
            ("Rio, remind me to submit homework 6 tonight at 11:59", "Submit homework 6", date(11, 3, 23, 59)),
            ("remind me to email my TA tomorrow morning", "Email my TA", date(11, 4, 9)),
            ("remind me in 20 minutes to switch the laundry", "Switch the laundry", date(11, 3, 10, 20)),
            ("remind me friday at 3 to go to office hours", "Go to office hours", date(11, 6, 15)),
            ("set a reminder for 9 pm to submit the lab", "Submit the lab", date(11, 3, 21)),
            ("remind me to email the investors at 5", "Email the investors", date(11, 3, 17)),
            ("remind me in 20 minutes to check the deploy", "Check the deploy", date(11, 3, 10, 20)),
            ("remind me tomorrow to follow up with sequoia", "Follow up with sequoia", date(11, 4, 9)),
            ("remind me to call mom at 5", "Call mom", date(11, 3, 17)),
            ("remind me to call mom at 5 pm", "Call mom", date(11, 3, 17)),
            ("remind me tomorrow to submit the homework", "Submit the homework", date(11, 4, 9)),
            ("set a reminder to drink water at 3", "Drink water", date(11, 3, 15)),
            ("Rio remind me to call my dad tomorrow", "Call my dad", date(11, 4, 9)),
            ("Rio remind me tomorrow to call my dad", "Call my dad", date(11, 4, 9)),
            ("remind me to call mom and dad at 5, please", "Call mom and dad", date(11, 3, 17)),
            ("remind me about the dentist tomorrow afternoon", "The dentist", date(11, 4, 14)),
            ("remind me tomorrow to call dad at 5", "Call dad", date(11, 4, 17)),
        ]
        for (input, title, due) in cases {
            ETest.eq(parse(input), .createReminder(title: title, due: due), input)
        }
    }

    private static func undated() {
        let cases: [(String, String)] = [
            ("add a reminder: buy a blue book", "Buy a blue book"),
            ("add a reminder to renew the domain", "Renew the domain"),
            ("remind me to call mom", "Call mom"),
            ("remind me to plan game night", "Plan game night"),
            ("create a reminder called pick up the cake", "Pick up the cake"),
            ("reminder: return the library books", "Return the library books"),
        ]
        for (input, title) in cases {
            ETest.eq(parse(input), .createReminder(title: title, due: nil), input)
        }
    }

    /// A time it can't place, a repeating reminder or no title: the resolver or the scheduler.
    private static func leftAlone() {
        for text in [
            "remind me at 13 pm", "remind me to call mom at 13 pm", "remind me to call mom at 9",
            "remind me to call mom an hour from now", "remind me to take vitamins every day at 9 am",
            "remind me my locker code is 4321", "remind me", "set a reminder",
            "remember to call mom", "remind me tonight to call mom later", "open reminders",
            "add milk to my reminders", "what are my reminders",
        ] {
            ETest.eq(parse(text), nil, "must not claim '\(text)'")
        }
    }

    private static func throughTheRealParser() {
        let parser = RioActionParser(installedApps: [])
        func title(_ text: String) -> String? {
            guard case .actions(let list) = parser.parse(text), list.count == 1,
                  case .createReminder(let title, _) = list[0] else { return nil }
            return title
        }
        ETest.eq(title("Rio, remind me to call mom and grab milk"), "Call mom and grab milk", "one reminder, not split at and")
        ETest.eq(title("set a reminder to drink water"), "Drink water")
        ETest.eq(title("remind me in 20 minutes to switch the laundry"), "Switch the laundry")
        // Remembering stays memory.
        ETest.eq(parser.parse("remember my locker code is 4321"), .actions([.remember(fact: "my locker code is 4321")]))
        // A repeating reminder is still the scheduler's.
        if case .actions(let list) = parser.parse("remind me to take vitamins every day at 9 am") {
            TestSupport.expect(!list.contains { if case .createReminder = $0 { return true } else { return false } }, "repeating reminder became one-off")
        }
    }

    private static func dayOnly() {
        func day(_ text: String) -> RioDateTimeParser.Result? { RioDateTimeParser.parseDay(text, now: now, calendar: calendar) }
        ETest.eq(day("tomorrow")?.start, date(11, 4, 9))
        ETest.eq(day("call dad tomorrow evening")?.start, date(11, 4, 19))
        ETest.eq(day("call dad tomorrow evening")?.remainder, "call dad")
        ETest.eq(day("tonight")?.start, date(11, 3, 20))
        ETest.eq(day("Friday")?.start, date(11, 6, 9))
        ETest.eq(day("call dad"), nil)
        // The default hour already passed: nothing to place.
        ETest.eq(RioDateTimeParser.parseDay("tonight", now: date(11, 3, 22), calendar: calendar), nil)
    }
}
