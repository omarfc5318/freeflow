import Foundation

/// Round 3 fixes for the phrases / schedule / memory / timer group. Synthetic phrases only, with a
/// fixed "now" (Tuesday 2026-11-03 10:00, UTC-8) wherever a date matters.
enum RioR3PhrasesTests {
    private static let parser = RioActionParser(installedApps: [])
    private static let calendar = RioDateTimeParserTests.calendar
    private static let now = RioDateTimeParserTests.now

    private static func parse(_ text: String) -> RioActionParse { parser.parse(text) }
    private static func actions(_ list: RioAction...) -> RioActionParse { .actions(list) }

    static func run() {
        repeatingReminderText()
        bareRemindMe()
        calendarNotRecall()
        recurringEventsLeftAlone()
        noteSaying()
        timerAndReminderChains()
        hugeDurationsDoNotCrash()
        timerLabelsWithNumbers()
        thousandsSeparators()
        trailingDelay()
        emailInstructionsGoToTheResolver()
    }

    @MainActor static func runAsync() async {
        await recallFallbackPrivacy()
    }

    // MARK: [3] "remind me every monday at 9 am to check canvas"

    private static func repeatingReminderText() {
        ETest.eq(parse("rio remind me every monday at 9 am to check canvas"),
                 actions(.scheduleCommand(command: "remind me to check canvas", when: "every monday at 9 am")))
        ETest.eq(parse("rio remind me every day at 10 pm to do my homework"),
                 actions(.scheduleCommand(command: "remind me to do my homework", when: "every day at 10 pm")))
        // The reordered form keeps working.
        ETest.eq(parse("every monday at 9 am remind me to check canvas"),
                 actions(.scheduleCommand(command: "remind me to check canvas", when: "every monday at 9 am")))
        ETest.eq(parse("remind me to call mom every monday at 9 am"),
                 actions(.scheduleCommand(command: "remind me to call mom", when: "every monday at 9 am")))
        // The schedule the handler sees parses.
        if case .actions(let list) = parse("remind me every weekday at 8:30 am to stretch"),
           case .scheduleCommand(let command, let when)? = list.first {
            ETest.eq(command, "remind me to stretch")
            TestSupport.expect(RioScheduleParser.parse(when, now: now, calendar: calendar) != nil, "'\(when)' must parse")
        } else {
            TestSupport.expect(false, "weekday reminder must be a schedule: \(parse("remind me every weekday at 8:30 am to stretch"))")
        }
        // A when-group that never parses still keeps the reminder text in the command.
        if case .actions(let list) = parse("remind me every monday at 9 to check canvas"),
           case .scheduleCommand(let command, _)? = list.first {
            ETest.eq(command, "remind me to check canvas")
        }
    }

    // MARK: [55] "remind me in five minutes"

    private static func bareRemindMe() {
        // Never the bare scheduled command "remind me": with no subject the resolver asks or
        // writes the reminder (RioReminderPhrasesTests keeps "remind me in 10 minutes" unclaimed).
        for text in ["Rio remind me in five minutes", "remind me in 5 minutes", "remind me tomorrow at 7 pm"] {
            if case .actions(let list) = parse(text), case .scheduleCommand? = list.first {
                TestSupport.expect(false, "'\(text)' must not schedule a bare 'remind me': \(list)")
            }
        }
        // The scheduler never takes a verb with no object.
        ETest.eq(RioAutomationPhrases.parse(raw: "remind me in 5 minutes", simplified: "remind me in 5 minutes"), nil)
        ETest.eq(RioAutomationPhrases.parse(raw: "text in 5 minutes", simplified: "text in 5 minutes"), nil)
        // A command that is whole on its own still schedules.
        ETest.eq(RioAutomationPhrases.parse(raw: "lock the screen in 5 minutes", simplified: "lock the screen in 5 minutes"),
                 .scheduleCommand(command: "lock the screen", when: "in 5 minutes"))
        ETest.eq(RioAutomationPhrases.parse(raw: "mute in 10 minutes", simplified: "mute in 10 minutes"),
                 .scheduleCommand(command: "mute", when: "in 10 minutes"))
        // A reminder with its own text and time stays the reminder parser's.
        let mom = parse("remind me to call mom in 5 minutes")
        if case .actions(let list) = mom, case .createReminder? = list.first {} else {
            TestSupport.expect(false, "remind me to call mom in 5 minutes stays a reminder: \(mom)")
        }
    }

    // MARK: [23+54] "what's my 4pm", "what's my first meeting tomorrow"

    private static func calendarNotRecall() {
        func agenda(_ text: String) -> RioAction? {
            RioCalendarPhrases.parse(raw: text, simplified: RioText.simplify(text), now: now, calendar: calendar)
        }
        let cases: [(String, CalendarRange)] = [
            ("what's my 2pm", .today), ("what's my 4pm", .today), ("what's my 4 pm meeting", .today),
            ("what's my 4:30 pm", .today), ("what's my 3 pm tomorrow", .tomorrow),
            ("what's my first meeting tomorrow", .tomorrow), ("what's my last class today", .today),
            ("what is my first class", .today), ("what's my next class tomorrow", .tomorrow),
            ("what's my meeting at 3", .today), ("what's my call at 4 pm tomorrow", .tomorrow),
            ("when is my first meeting tomorrow", .tomorrow), ("what do i have at 2pm", .today),
            ("what's my next meeting", .next),
        ]
        for (text, range) in cases {
            ETest.eq(agenda(text), .calendarAgenda(range), text)
            ETest.eq(parse(text), actions(.calendarAgenda(range)), "through the parser: \(text)")
        }
        // Recall never claims a clock time or a calendar noun.
        for text in ["what's my 2 pm thing", "whats my standup about", "what's my lecture"] {
            if case .actions(let list) = parse(text), case .recall? = list.first {
                TestSupport.expect(false, "'\(text)' must not be memory recall")
            }
        }
        // Real memories still recall.
        ETest.eq(parse("what's my locker code"), actions(.recall(query: "locker code")))
        ETest.eq(parse("what's my zoom meeting link"), actions(.recall(query: "zoom meeting link")))
        ETest.eq(parse("what did I tell you about the meeting with sequoia"), actions(.recall(query: "the meeting with sequoia")))
    }

    // MARK: [4] recurring calendar events

    private static func recurringEventsLeftAlone() {
        for text in ["add office hours every tuesday at 3 to my calendar", "schedule standup every day at 10 am",
                     "add gym weekly on monday at 7 pm", "put yoga each friday at 6 pm on my calendar"] {
            ETest.eq(RioCalendarPhrases.parse(raw: text, simplified: RioText.simplify(text), now: now, calendar: calendar), nil, text)
        }
        if case .actions(let list) = parse("rio add office hours every tuesday at 3 to my calendar"), case .createEvent? = list.first {
            TestSupport.expect(false, "a recurring event must not become one garbled event")
        }
        // One-off events still work.
        ETest.eq(RioCalendarPhrases.parse(raw: "add office hours tuesday at 3", simplified: "add office hours tuesday at 3", now: now, calendar: calendar),
                 .createEvent(title: "Office hours", start: RioDateTimeParserTests.date(2026, 11, 10, 15), durationMinutes: nil))
    }

    // MARK: [29] "add a note saying X"

    private static func noteSaying() {
        ETest.eq(parse("add a note saying ship the landing page by friday"), actions(.addNote(text: "Ship the landing page by friday")))
        ETest.eq(parse("take a note saying ship it"), actions(.addNote(text: "Ship it")))
        ETest.eq(parse("add a note that says ship it"), actions(.addNote(text: "Ship it")))
        ETest.eq(parse("make a note that reads ship it"), actions(.addNote(text: "Ship it")))
        ETest.eq(parse("note saying ship it"), actions(.addNote(text: "Ship it")))
        ETest.eq(parse("add a note to self saying buy milk"), actions(.addNote(text: "Buy milk")))
        // Unchanged forms.
        ETest.eq(parse("take a note that the demo is at 3"), actions(.addNote(text: "The demo is at 3")))
        ETest.eq(parse("add a note buy eggs"), actions(.addNote(text: "Buy eggs")))
    }

    // MARK: [66] timer + reminder in one sentence

    private static func timerAndReminderChains() {
        // Neither parser swallows the other command, so the splitter can take them apart.
        ETest.eq(RioReminderPhrases.parse("remind me to call mom and set a timer for 5 minutes", now: now, calendar: calendar), nil)
        ETest.eq(RioReminderPhrases.parse("remind me to call mom and then start a 5 minute timer", now: now, calendar: calendar), nil)
        ETest.eq(RioReminderPhrases.parse("remind me to stretch and remind me to drink water", now: now, calendar: calendar), nil)
        ETest.eq(RioActionParser.splitClauses("remind me to call mom and set a timer for 5 minutes"),
                 ["remind me to call mom", "set a timer for 5 minutes"])
        ETest.eq(RioActionParser.splitClauses("set a timer for 10 minutes and remind me to take out the laundry"),
                 ["set a timer for 10 minutes", "remind me to take out the laundry"])
        // An "and" inside the reminder text stays.
        ETest.eq(RioReminderPhrases.parse("remind me to buy milk and eggs", now: now, calendar: calendar),
                 .createReminder(title: "Buy milk and eggs", due: nil))
        // A timer label never swallows the next command.
        ETest.eq(RioTimerPhrases.parseStart("set a timer for 10 minutes called pasta and remind me to stir"),
                 .startTimer(seconds: 600, label: "pasta"))
        // End to end: "remind me to X" is also a clause parser (RioExtraPhrases).
        for (text, timerFirst) in [("set a timer for 10 minutes and remind me to take out the laundry", true),
                                   ("remind me to call mom and set a timer for 5 minutes", false)] {
            let result = parse(text)
            guard case .actions(let list) = result, list.count == 2 else {
                TestSupport.expect(false, "'\(text)' must give a timer and a reminder: \(result)")
                continue
            }
            let (timer, reminder) = timerFirst ? (list[0], list[1]) : (list[1], list[0])
            if case .startTimer = timer {} else { TestSupport.expect(false, "timer in '\(text)': \(result)") }
            if case .createReminder = reminder {} else { TestSupport.expect(false, "reminder in '\(text)': \(result)") }
        }
    }

    // MARK: [85+96] huge durations

    private static func hugeDurationsDoNotCrash() {
        let huge = [
            "set a timer for 100000000000 billion hours",
            "set a timer for 10000000000000000 hours", "set a timer for 99999999999999999999999999 seconds",
            "set a timer for 100000000000000000000 minutes and 5 seconds",
        ]
        for text in huge {
            let simple = RioText.simplify(text).lowercased()
            if let result = RioTimerPhrases.parseStart(simple) { ETest.eq(result, .answer(RioTimerPhrases.tooLongReply), text) }
            _ = RioTimerPhrases.protectingDurations(in: text)
            _ = RioTimerDuration.parse(text)
            _ = parse(text)
        }
        ETest.eq(RioTimerPhrases.parseStart("set a timer for 100000000000 billion hours"), .answer(RioTimerPhrases.tooLongReply))
        // "1e30" is not a number word: whatever it reads as, it must not trap.
        _ = parse("set a timer for 1e30 minutes")
        ETest.eq(RioTimerDuration.parse("10000000000000000 hours"), nil)
        // The date parser and the scheduler take the same numbers without trapping.
        for text in ["meeting tomorrow at 3 pm for 99999999999999999999 minutes", "lunch in 99999999999999999999 hours",
                     "lunch in 99999999999999999999 days at 3 pm", "sync for 99999999999999999999 and a half hours tomorrow at 3 pm"] {
            _ = RioDateTimeParser.parse(text, now: now, calendar: calendar)
        }
        _ = RioScheduleParser.parse("in 99999999999999999999 seconds", now: now, calendar: calendar)
        _ = RioReminderPhrases.parse("remind me in 99999999999999999999 minutes to stretch", now: now, calendar: calendar)
    }

    // MARK: [13] labels with numbers

    private static func timerLabelsWithNumbers() {
        ETest.eq(RioTimerPhrases.parseStart("set a timer for 45 minutes called mat 108 homework"),
                 .startTimer(seconds: 2700, label: "mat 108 homework"))
        ETest.eq(parse("rio set a timer for 45 minutes called MAT 108 homework"),
                 actions(.startTimer(seconds: 2700, label: "mat 108 homework")))
        ETest.eq(RioTimerPhrases.parseStart("set a timer for 20 minutes for ecs 119"), .startTimer(seconds: 1200, label: "ecs 119"))
        // Digits alone are not a label.
        ETest.eq(RioTimerPhrases.parseStart("set a timer for 20 minutes called 108"), .startTimer(seconds: 1200, label: nil))
        ETest.eq(RioTimerPhrases.parseStart("set a timer for 10 minutes called pasta"), .startTimer(seconds: 600, label: "pasta"))
    }

    // MARK: [47a] "1,000 seconds"

    private static func thousandsSeparators() {
        ETest.eq(parse("set a timer for 1,000 seconds"), actions(.startTimer(seconds: 1000, label: nil)))
        ETest.eq(RioTimerDuration.parse("10,000 seconds"), 10_000)
        ETest.eq(RioTimerDuration.parse("1,000 seconds"), 1000)
        ETest.eq(RioTimerPhrases.parseStart("set a timer for 1 000 seconds"), .startTimer(seconds: 1000, label: nil))
        // Ordinary numbers are unchanged.
        ETest.eq(RioTimerDuration.parse("1 hour 30 minutes"), 5400)
        ETest.eq(RioTimerDuration.parse("90 seconds"), 90)
    }

    // MARK: [45] "open Chrome in 5 seconds"

    private static func trailingDelay() {
        ETest.eq(parse("open Chrome in 5 seconds"), actions(.scheduleCommand(command: "open Chrome", when: "in 5 seconds")))
        ETest.eq(parse("quit Zoom in 10 minutes"), actions(.scheduleCommand(command: "quit Zoom", when: "in 10 minutes")))
        ETest.eq(parse("lock the screen after 30 seconds"), actions(.scheduleCommand(command: "lock the screen", when: "after 30 seconds")))
        ETest.eq(parse("after 10 minutes quit Zoom"), actions(.scheduleCommand(command: "quit Zoom", when: "after 10 minutes")))
        ETest.eq(parse("in 10 minutes quit Zoom"), actions(.scheduleCommand(command: "quit Zoom", when: "in 10 minutes")))
        // The scheduler can place them.
        ETest.eq(RioScheduleParser.parse("in 5 seconds", now: now, calendar: calendar)?.firstFire, now.addingTimeInterval(5))
        ETest.eq(RioScheduleParser.parse("after 30 seconds", now: now, calendar: calendar)?.firstFire, now.addingTimeInterval(30))
        ETest.eq(RioScheduleParser.parse("after 10 minutes", now: now, calendar: calendar)?.firstFire, now.addingTimeInterval(600))
        // Not ours: timers, reminders and messages keep their own parsers.
        ETest.eq(parse("set a timer for 5 minutes"), actions(.startTimer(seconds: 300, label: nil)))
        let stretch = parse("remind me to stretch in 5 minutes")
        if case .actions(let list) = stretch, case .createReminder? = list.first {} else {
            TestSupport.expect(false, "remind me to stretch in 5 minutes stays a reminder: \(stretch)")
        }
        if case .actions(let texts) = parse("text Sarah I'll be home in 20 minutes"), case .scheduleCommand? = texts.first {
            TestSupport.expect(false, "a message body keeps its time words")
        }
    }

    // MARK: [71] email purpose clauses

    private static func emailInstructionsGoToTheResolver() {
        let instructions = [
            "write an email to my professor saying I'll miss class tomorrow because I'm sick and ask if I can get the slides",
            "email Sam saying I'm running late and ask whether we can push to 4",
            "draft an email to Ali saying the deck is ready and tell him to review it",
            "email Sara saying thanks for the call and let her know I'll send the notes",
        ]
        for text in instructions {
            ETest.eq(RioEmailPhrases.parse(text), nil, text)
        }
        // Words that are the email's own text stay local.
        ETest.eq(RioEmailPhrases.parse("email Sam saying I'm running late and I'll call you"),
                 .draftEmail(to: "Sam", subject: nil, body: "I'm running late and I'll call you"))
        ETest.eq(RioEmailPhrases.parse("email Sam saying can you ask Ali for the deck"),
                 .draftEmail(to: "Sam", subject: nil, body: "Can you ask Ali for the deck"))
    }

    // MARK: [86] recall fallback privacy

    @MainActor private final class HistoryExecutor: RioActionExecuting {
        var executed: [RioAction] = []
        let reply: RioActionResult
        init(reply: RioActionResult) { self.reply = reply }
        func execute(_ action: RioAction) async -> RioActionResult {
            executed.append(action)
            return reply
        }
    }

    @MainActor private static func recallFallbackPrivacy() async {
        let miss = RioActionResult.failed(message: "I don't have anything saved about my password.")
        // A sensitive question never searches the dictations.
        for query in ["my password", "bank pin", "card number", "my passcode", "ssn", "the verification code"] {
            let executor = HistoryExecutor(reply: .done(summary: "On Monday you said: something"))
            let result = await RioRecallFallback.resolve(memory: miss, query: query, executor: executor)
            ETest.eq(result, miss, query)
            ETest.eq(executor.executed, [], "no history search for \(query)")
        }
        // A snippet that carries a secret is never spoken.
        let secret = HistoryExecutor(reply: .done(summary: "On Monday you said: the password is hunter2"))
        let hidden = await RioRecallFallback.resolve(memory: miss, query: "the wifi", executor: secret)
        ETest.eq(hidden, miss)
        let card = HistoryExecutor(reply: .done(summary: "On Monday you said: use 4111 1111 1111 1111"))
        let cardResult = await RioRecallFallback.resolve(memory: miss, query: "the order", executor: card)
        ETest.eq(cardResult, miss)
        // Not from the action key (conversation mode): no history read, a hint instead.
        let room = HistoryExecutor(reply: .done(summary: "On Monday you said: the budget is tight"))
        let hinted = await RioRecallFallback.resolve(memory: miss, query: "the budget", executor: room, allowsHistory: false)
        ETest.eq(room.executed, [], "conversation mode never reads the dictations aloud")
        if case .failed(let message) = hinted {
            TestSupport.expect(message.contains("search my dictations for the budget"), "the hint says how: \(message)")
        } else {
            TestSupport.expect(false, "a hint, not a success: \(hinted)")
        }
        // The action key keeps the fallback.
        let key = HistoryExecutor(reply: .done(summary: "On Monday you said: the budget is tight"))
        let keyResult = await RioRecallFallback.resolve(memory: miss, query: "the budget", executor: key)
        ETest.eq(keyResult, .done(summary: "On Monday you said: the budget is tight"))
    }
}
