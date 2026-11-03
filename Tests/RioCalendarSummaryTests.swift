import Foundation

/// Spoken calendar summaries from synthetic events (nothing reads a real calendar).
enum RioCalendarSummaryTests {
    private static let now = RioDateTimeParserTests.now
    private static let calendar = RioDateTimeParserTests.calendar
    private static func d(_ h: Int, _ m: Int = 0, day: Int = 3) -> Date { RioDateTimeParserTests.date(2026, 11, day, h, m) }

    private static func event(_ title: String, _ start: Date, _ end: Date, allDay: Bool = false, declined: Bool = false) -> RioCalendarEventInfo {
        RioCalendarEventInfo(
            identifier: title, title: title, start: start, end: end, isAllDay: allDay,
            location: nil, notes: nil, url: nil, isDeclined: declined
        )
    }

    private static func say(_ range: CalendarRange, _ events: [RioCalendarEventInfo]) -> String {
        RioCalendarSummary.agenda(range: range, events: events, now: now, calendar: calendar)
    }

    static func run() {
        timeFormatting()
        agenda()
        createdEvent()
    }

    private static func timeFormatting() {
        TestSupport.expectEqual(RioCalendarSummary.clock(d(15), calendar: calendar), "3 PM")
        TestSupport.expectEqual(RioCalendarSummary.clock(d(15, 30), calendar: calendar), "3:30 PM")
        TestSupport.expectEqual(RioCalendarSummary.clock(d(0, 5), calendar: calendar), "12:05 AM")
        TestSupport.expectEqual(RioCalendarSummary.clock(d(12), calendar: calendar), "12 PM")
        TestSupport.expectEqual(RioCalendarSummary.clock(d(9), calendar: calendar), "9 AM")
        TestSupport.expectEqual(RioCalendarSummary.dayAndTime(d(19, day: 4), now: now, calendar: calendar), "tomorrow at 7 PM")
        TestSupport.expectEqual(RioCalendarSummary.dayAndTime(d(19), now: now, calendar: calendar), "today at 7 PM")
        TestSupport.expectEqual(RioCalendarSummary.dayAndTime(d(13, day: 6), now: now, calendar: calendar), "Friday at 1 PM")
        TestSupport.expectEqual(RioCalendarSummary.dayAndTime(RioDateTimeParserTests.date(2026, 11, 20, 9), now: now, calendar: calendar), "November 20 at 9 AM")
        TestSupport.expectEqual(RioCalendarSummary.dayAndTime(RioDateTimeParserTests.date(2027, 3, 5, 16), now: now, calendar: calendar), "March 5, 2027 at 4 PM")
    }

    private static func agenda() {
        let call = event("Call with Ali", d(15), d(16))
        let lunch = event("Lunch", d(12), d(13))
        let study = event("Study session", d(19), d(20))
        TestSupport.expectEqual(
            say(.today, [study, call, lunch]),
            "You've got 3 things today. Next: Lunch at 12 PM."
        )
        TestSupport.expectEqual(say(.today, [call]), "You've got 1 thing today. Next: Call with Ali at 3 PM.")
        TestSupport.expectEqual(say(.today, []), "Your calendar is clear today.")
        // In progress
        let current = event("Standup", d(9, 30), d(10, 30))
        TestSupport.expectEqual(
            say(.today, [current, call]),
            "You've got 2 things today. Right now: Standup until 10:30 AM."
        )
        // Everything over
        let over = event("Breakfast", d(7), d(8))
        TestSupport.expectEqual(say(.today, [over]), "You've got 1 thing today, and it's already done.")
        TestSupport.expectEqual(say(.today, [over, event("Gym", d(8), d(9))]), "You've got 2 things today, and they're all done.")
        // All-day events and declined ones
        let holiday = event("Veterans Day", d(0), d(23, 59), allDay: true)
        TestSupport.expectEqual(say(.today, [holiday]), "You've got 1 thing today: Veterans Day, all day.")
        let declined = event("Skipped", d(14), d(15), declined: true)
        TestSupport.expectEqual(say(.today, [declined]), "Your calendar is clear today.")
        // Tomorrow
        let t1 = event("Class", d(9, day: 4), d(10, day: 4))
        let t2 = event("Office hours", d(14, day: 4), d(15, day: 4))
        TestSupport.expectEqual(say(.tomorrow, [t2, t1]), "Tomorrow you've got 2 things. First: Class at 9 AM.")
        TestSupport.expectEqual(say(.tomorrow, []), "Your calendar is clear tomorrow.")
        // Next
        TestSupport.expectEqual(say(.next, [lunch, call]), "Next up: Lunch at 12 PM.")
        TestSupport.expectEqual(say(.next, [current, call]), "Right now: Standup until 10:30 AM. Then Call with Ali at 3 PM.")
        TestSupport.expectEqual(say(.next, [t1]), "Next up: Class tomorrow at 9 AM.")
        TestSupport.expectEqual(say(.next, []), "Nothing coming up on your calendar.")
        TestSupport.expectEqual(say(.next, [over]), "Nothing coming up on your calendar.")
        // An untitled event is still spoken sensibly.
        TestSupport.expectEqual(say(.next, [event("", d(15), d(16))]), "Next up: an untitled event at 3 PM.")
    }

    private static func createdEvent() {
        TestSupport.expectEqual(
            RioCalendarSummary.created(title: "Study session", start: d(19, day: 4), durationMinutes: nil, now: now, calendar: calendar),
            "Added Study session, tomorrow at 7 PM"
        )
        TestSupport.expectEqual(
            RioCalendarSummary.created(title: "Lunch with Sarah", start: d(13, day: 6), durationMinutes: 60, now: now, calendar: calendar),
            "Added Lunch with Sarah, Friday at 1 PM for an hour"
        )
        TestSupport.expectEqual(
            RioCalendarSummary.durationPhrase(minutes: 90), "an hour and a half"
        )
        TestSupport.expectEqual(RioCalendarSummary.durationPhrase(minutes: 30), "30 minutes")
        TestSupport.expectEqual(RioCalendarSummary.durationPhrase(minutes: 120), "2 hours")
    }
}
