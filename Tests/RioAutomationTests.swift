import Foundation

/// Scheduled commands, triggers, macros and their phrases (builder P). Fixed clock and time zone,
/// temp directories only; nothing here touches the real system or registers an observer.
enum RioAutomationTests {
    private static let zone = TimeZone(identifier: "America/Los_Angeles")!
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// Tuesday 3 November 2026, 10:00 in Los Angeles.
    private static var now: Date { date(2026, 11, 3, 10, 0) }

    private static func phrase(_ text: String) -> RioAction? {
        RioAutomationPhrases.parse(raw: text, simplified: RioText.simplify(text))
    }

    static func run() {
        whenParser()
        nextFire()
        resolution()
        triggers()
        macroMapping()
        phrases()
        notStealing()
        store()
    }

    // MARK: When and recurrence

    private static func whenParser() {
        func parsed(_ text: String) -> RioParsedSchedule? { RioScheduleParser.parse(text, now: now, calendar: calendar) }
        ETest.eq(parsed("every day at 8 am"),
                 RioParsedSchedule(recurrence: .daily, hour: 8, minute: 0, firstFire: date(2026, 11, 4, 8)), "daily")
        ETest.eq(parsed("every day at 9 am")?.firstFire, date(2026, 11, 4, 9), "daily, time already passed today")
        ETest.eq(parsed("every day at 11 am")?.firstFire, date(2026, 11, 3, 11), "daily, later today")
        ETest.eq(parsed("daily at 6:45 pm"),
                 RioParsedSchedule(recurrence: .daily, hour: 18, minute: 45, firstFire: date(2026, 11, 3, 18, 45)), "daily word")
        ETest.eq(parsed("every weekday at 8:30 am"),
                 RioParsedSchedule(recurrence: .weekdays, hour: 8, minute: 30, firstFire: date(2026, 11, 4, 8, 30)), "weekdays")
        ETest.eq(parsed("every monday at 9 am"),
                 RioParsedSchedule(recurrence: .weekly(weekday: 2), hour: 9, minute: 0, firstFire: date(2026, 11, 9, 9)), "weekly")
        ETest.eq(parsed("weekly on friday at 5 pm")?.recurrence, .weekly(weekday: 6), "weekly on")
        ETest.eq(parsed("every morning at 7 am")?.hour, 7, "every morning")
        ETest.eq(parsed("in 20 minutes"),
                 RioParsedSchedule(recurrence: .once, hour: 10, minute: 20, firstFire: date(2026, 11, 3, 10, 20)), "relative")
        ETest.eq(parsed("at 5 pm")?.firstFire, date(2026, 11, 3, 17), "at 5 pm")
        ETest.eq(parsed("tomorrow at 9 am")?.recurrence, .once, "tomorrow")
        ETest.eq(parsed("every day"), nil, "recurrence without a time")
        ETest.eq(parsed("sometime soon"), nil, "no clock time")
        ETest.eq(parsed("banana"), nil, "garbage")
        ETest.eq(parsed("every day at 8 am and bring snacks"), nil, "leftover words")
    }

    // MARK: Next fire

    private static func nextFire() {
        func next(_ after: Date, _ rec: RioRecurrence, _ h: Int, _ m: Int) -> Date? {
            RioScheduleMath.nextFire(after: after, recurrence: rec, hour: h, minute: m, calendar: calendar)
        }
        ETest.eq(next(date(2026, 11, 3, 7), .daily, 8, 0), date(2026, 11, 3, 8), "same day")
        ETest.eq(next(date(2026, 11, 3, 8), .daily, 8, 0), date(2026, 11, 4, 8), "strictly after")
        // Friday evening: the next weekday run is Monday.
        ETest.eq(next(date(2026, 11, 6, 17), .weekdays, 8, 0), date(2026, 11, 9, 8), "weekdays skip the weekend")
        ETest.eq(next(date(2026, 11, 3, 10), .weekly(weekday: 3), 9, 0), date(2026, 11, 10, 9), "weekly, same weekday later")
        ETest.eq(next(date(2026, 11, 3, 10), .once, 9, 0), nil, "once has no next")
        // Spring forward: 9 am the next day is 23 hours later, not 24.
        let before = date(2026, 3, 7, 9)
        let after = next(before, .daily, 9, 0)
        ETest.eq(after, date(2026, 3, 8, 9), "daily across spring forward")
        ETest.eq(after?.timeIntervalSince(before), 23 * 3600, "23 real hours")
        // 2:30 am does not exist on 8 March: it runs just after the gap, still that day.
        let gap = next(date(2026, 3, 7, 12), .daily, 2, 30)
        ETest.eq(gap.map { calendar.component(.day, from: $0) }, 8, "gap day")
        TestSupport.expect((gap.map { calendar.component(.hour, from: $0) } ?? 0) >= 3, "gap hour moves forward")
        // Fall back: 1:30 am happens twice on 1 November; it fires once and the next is the next day.
        let fall = next(date(2026, 10, 31, 12), .daily, 1, 30)
        ETest.eq(fall.map { calendar.component(.day, from: $0) }, 1, "fall back day")
        let afterFall = fall.flatMap { next($0, .daily, 1, 30) }
        ETest.eq(afterFall.map { calendar.component(.day, from: $0) }, 2, "no double fire after fall back")
    }

    private static func item(_ rec: RioRecurrence, fire: Date, hour: Int = 8) -> RioScheduledCommand {
        RioScheduledCommand(id: UUID(), command: "open Slack", recurrence: rec, hour: hour, minute: 0,
                            nextFire: fire, createdAt: date(2026, 11, 1))
    }

    private static func resolution() {
        let daily = item(.daily, fire: date(2026, 11, 3, 11))
        ETest.eq(RioScheduleMath.resolve(daily, now: now, calendar: calendar).verdict, .notDue, "not due")
        ETest.eq(RioScheduleMath.resolve(daily, now: now, calendar: calendar).updated, daily, "unchanged")

        let onTime = item(.daily, fire: date(2026, 11, 3, 10), hour: 10)
        let fired = RioScheduleMath.resolve(onTime, now: date(2026, 11, 3, 10, 0), calendar: calendar)
        ETest.eq(fired.verdict, .fire(late: false), "fires on time")
        ETest.eq(fired.updated?.nextFire, date(2026, 11, 4, 10), "recurring moves to the next day")

        // The Mac slept through 8 am and woke at 8:10: catch up, and say it was late.
        let slept = item(.daily, fire: date(2026, 11, 3, 8))
        let caught = RioScheduleMath.resolve(slept, now: date(2026, 11, 3, 8, 10), calendar: calendar)
        ETest.eq(caught.verdict, .fire(late: true), "catch up inside the window")
        ETest.eq(caught.updated?.nextFire, date(2026, 11, 4, 8), "next day after catching up")

        // Woke at 10:00: two hours late is skipped with a note, and the next run is tomorrow.
        let missed = RioScheduleMath.resolve(slept, now: now, calendar: calendar)
        ETest.eq(missed.verdict, .skipped, "skip outside the window")
        ETest.eq(missed.updated?.nextFire, date(2026, 11, 4, 8), "reschedules after a skip")

        // Several days asleep: one skip, not a pile of runs.
        let days = RioScheduleMath.resolve(slept, now: date(2026, 11, 7, 13), calendar: calendar)
        ETest.eq(days.verdict, .skipped, "days asleep skip once")
        ETest.eq(days.updated?.nextFire, date(2026, 11, 8, 8), "next run after the sleep")

        let once = item(.once, fire: date(2026, 11, 3, 10, 5))
        let onceFired = RioScheduleMath.resolve(once, now: date(2026, 11, 3, 10, 6), calendar: calendar)
        ETest.eq(onceFired.verdict, .fire(late: true), "one-off fires")
        ETest.eq(onceFired.updated, nil, "one-off is removed once it ran")
        let onceMissed = RioScheduleMath.resolve(once, now: date(2026, 11, 3, 14), calendar: calendar)
        ETest.eq(onceMissed.verdict, .skipped, "one-off missed")
        ETest.eq(onceMissed.updated, nil, "missed one-off is removed")
        ETest.eq(RioAutomationText.skipNote(for: once, calendar: calendar).contains("open Slack"), true, "skip note names the command")
    }

    // MARK: Triggers

    private static func triggers() {
        for kind in [RioTriggerKind.displayConnected, .audioOutput(name: "AirPods"), .wifi(ssid: "Home Wi-Fi")] {
            ETest.eq(RioTriggerKind(spec: kind.spec), kind, "spec round trip \(kind.spec)")
        }
        ETest.eq(RioTriggerKind(spec: "bluetooth:foo"), nil, "unknown spec")
        ETest.eq(RioTriggerKind(spec: "audio:"), nil, "empty name")
        ETest.eq(RioTriggerMatcher.matches(.displayConnected, .displayConnected), true, "display")
        ETest.eq(RioTriggerMatcher.matches(.displayConnected, .audioOutput(deviceName: "AirPods")), false, "display vs audio")
        let pods = RioTriggerKind.audioOutput(name: "AirPods")
        ETest.eq(RioTriggerMatcher.matches(pods, .audioOutput(deviceName: "Omar\u{2019}s AirPods Pro")), true, "airpods substring, curly apostrophe")
        ETest.eq(RioTriggerMatcher.matches(pods, .audioOutput(deviceName: "MacBook Pro Speakers")), false, "speakers")
        ETest.eq(RioTriggerMatcher.matches(.audioOutput(name: "air pods"), .audioOutput(deviceName: "Omar's AirPods")), true, "spacing ignored")
        ETest.eq(RioTriggerMatcher.matches(.wifi(ssid: "Home"), .wifiJoined(ssid: "home")), true, "ssid case")
        ETest.eq(RioTriggerMatcher.matches(.wifi(ssid: "Home"), .wifiJoined(ssid: "Home Guest")), false, "ssid exact")
        let t0 = date(2026, 11, 3, 10)
        ETest.eq(RioTriggerMatcher.shouldFire(lastFired: nil, now: t0), true, "first fire")
        ETest.eq(RioTriggerMatcher.shouldFire(lastFired: t0, now: t0.addingTimeInterval(5)), false, "cooldown")
        ETest.eq(RioTriggerMatcher.shouldFire(lastFired: t0, now: t0.addingTimeInterval(120)), true, "after cooldown")
    }

    // MARK: Macro mapping

    private static func key(_ k: String, cmd: Bool = false, shift: Bool = false, option: Bool = false, ctrl: Bool = false) -> KeyCombo {
        KeyCombo(key: k, command: cmd, shift: shift, option: option, control: ctrl)
    }

    private static func macroMapping() {
        func map(_ kind: RioMacroEvent.Kind, bundle: String? = "com.apple.Safari", secure: Bool = false) -> RioAction? {
            RioMacroMapper.action(for: RioMacroEvent(kind: kind, bundleID: bundle, isSecureContext: secure))
        }
        ETest.eq(map(.appSwitch(name: "Notes"), bundle: "com.apple.Notes"), .switchToApp(name: "Notes"), "app switch")
        ETest.eq(map(.click(label: "Save")), .click(label: "Save", ordinal: nil), "click label")
        ETest.eq(map(.click(label: nil)), nil, "unlabelled click is dropped")
        ETest.eq(map(.click(label: "  ")), nil, "blank label is dropped")
        ETest.eq(map(.click(label: "Password")), nil, "sensitive label")
        ETest.eq(map(.key(combo: key("t", cmd: true), typed: "t")), .pressKeys(key("t", cmd: true)), "command combo")
        ETest.eq(map(.key(combo: key("return"), typed: "\r")), .pressKeys(key("return")), "return key")
        ETest.eq(map(.key(combo: key("a", shift: true), typed: "A")), .typeText("A"), "shifted letter is text")
        ETest.eq(map(.key(combo: key("h"), typed: "h")), .typeText("h"), "plain letter is text")
        ETest.eq(map(.key(combo: nil, typed: "é")), .typeText("é"), "unmapped printable character")
        ETest.eq(map(.key(combo: nil, typed: nil)), nil, "nothing to record")
        ETest.eq(map(.key(combo: key("q", cmd: true, option: true), typed: nil)), .pressKeys(key("q", cmd: true, option: true)), "allowed")
        ETest.eq(map(.key(combo: key("a", ctrl: true), typed: "\u{01}")), .pressKeys(key("a", ctrl: true)), "control combo never types the control char")
        // Secure contexts and password managers record nothing.
        ETest.eq(map(.key(combo: key("a"), typed: "a"), secure: true), nil, "secure field typing")
        ETest.eq(map(.click(label: "Save"), secure: true), nil, "secure click")
        ETest.eq(map(.key(combo: key("a"), typed: "a"), bundle: "com.1password.1password"), nil, "1Password")
        ETest.eq(map(.appSwitch(name: "Bitwarden"), bundle: "com.bitwarden.desktop"), nil, "switch to a password manager")
        ETest.eq(map(.click(label: "Allow"), bundle: "com.apple.SecurityAgent"), nil, "system password prompt")
        ETest.eq(RioMacroMapper.isSkippedApp(bundleID: "com.apple.Passwords"), true, "Passwords app")
        ETest.eq(RioMacroMapper.isSkippedApp(bundleID: "com.apple.Safari"), false, "Safari is fine")

        let merged = RioMacroMapper.compact([.typeText("he"), .typeText("llo"), .pressKeys(key("return")), .typeText("a"), .typeText("b")])
        ETest.eq(merged, [.typeText("hello"), .pressKeys(key("return")), .typeText("ab")], "typed text merges")
        ETest.eq(RioMacroMapper.compact([.switchToApp(name: "Notes"), .switchToApp(name: "Notes")]), [.switchToApp(name: "Notes")], "repeat switch")
        ETest.eq(RioMacroMapper.compact([]), [], "empty")
        ETest.eq(RioMacroMapper.isReplayable(.openApp(name: "Notes")), false, "only recorded kinds replay")
        ETest.eq(RioMacroMapper.isReplayable(.click(label: "Save", ordinal: nil)), true, "click replays")
        ETest.eq(RioMacroMapper.isReplayable(.runTask(goal: "delete everything")), false, "no tasks in macros")
        let tooLong = RioMacroMapper.compact((0..<(RioMacroMapper.maxSteps + 20)).map { .click(label: "b\($0)", ordinal: nil) })
        ETest.eq(tooLong.count, RioMacroMapper.maxSteps, "step cap")
    }

    // MARK: Phrases

    private static func phrases() {
        ETest.eq(phrase("every day at 8 am open Slack"), .scheduleCommand(command: "open Slack", when: "every day at 8 am"), "daily")
        ETest.eq(phrase("Every weekday at 8:30 a.m., open Mail."), .scheduleCommand(command: "open Mail", when: "every weekday at 8:30 am"), "weekday comma")
        ETest.eq(phrase("every Monday at 9 open Notion"), .scheduleCommand(command: "open Notion", when: "every monday at 9"), "weekly")
        ETest.eq(phrase("in 20 minutes lock my screen"), .scheduleCommand(command: "lock my screen", when: "in 20 minutes"), "relative")
        ETest.eq(phrase("at 5 pm quit Slack"), .scheduleCommand(command: "quit Slack", when: "at 5 pm"), "at time")
        ETest.eq(phrase("schedule open Safari every day at 7 am"), .scheduleCommand(command: "open Safari", when: "every day at 7 am"), "schedule, trailing when")
        ETest.eq(phrase("schedule mute my volume at 11 pm"), .scheduleCommand(command: "mute my volume", when: "at 11 pm"), "schedule, trailing at")
        ETest.eq(phrase("open Slack every weekday at 9 am"), .scheduleCommand(command: "open Slack", when: "every weekday at 9 am"), "trailing every")
        ETest.eq(phrase("open Safari in 10 minutes"), .scheduleCommand(command: "open Safari", when: "in 10 minutes"), "trailing relative")
        ETest.eq(phrase("remind me to take vitamins every day at 9 am"),
                 .scheduleCommand(command: "remind me to take vitamins", when: "every day at 9 am"), "reminder every day")
        ETest.eq(phrase("schedule every day at 8 am to open Slack"), .scheduleCommand(command: "open Slack", when: "every day at 8 am"), "schedule leading")

        ETest.eq(phrase("when I connect my AirPods open Spotify"), .addTrigger(command: "open Spotify", trigger: "audio:AirPods"), "airpods")
        ETest.eq(phrase("When I connect my AirPods, play some music"), .addTrigger(command: "play some music", trigger: "audio:AirPods"), "airpods comma")
        ETest.eq(phrase("whenever my AirPods connect open Spotify"), .addTrigger(command: "open Spotify", trigger: "audio:AirPods"), "airpods connect")
        ETest.eq(phrase("when I plug in a monitor, open Slack"), .addTrigger(command: "open Slack", trigger: "display"), "monitor")
        ETest.eq(phrase("every time I connect an external display open Xcode"), .addTrigger(command: "open Xcode", trigger: "display"), "external display")
        ETest.eq(phrase("when a display connects open Slack"), .addTrigger(command: "open Slack", trigger: "display"), "display connects")
        ETest.eq(phrase("when I join the Wi-Fi Home open Notes"), .addTrigger(command: "open Notes", trigger: "wifi:Home"), "wifi named")
        ETest.eq(phrase("when I join the wifi network called Campus, quit Spotify"), .addTrigger(command: "quit Spotify", trigger: "wifi:Campus"), "wifi called")
        ETest.eq(phrase("when I connect to Home wifi turn off do not disturb"), .addTrigger(command: "turn off do not disturb", trigger: "wifi:Home"), "wifi trailing word")
        ETest.eq(phrase("open Spotify when I connect my AirPods"), .addTrigger(command: "open Spotify", trigger: "audio:AirPods"), "command first")

        ETest.eq(phrase("list my automations"), .listAutomations, "list")
        ETest.eq(phrase("what automations do I have"), .listAutomations, "what automations")
        ETest.eq(phrase("what macros do I have?"), .listAutomations, "what macros")
        ETest.eq(phrase("show my scheduled commands"), .listAutomations, "scheduled commands")
        ETest.eq(phrase("remove the Slack automation"), .removeAutomation(name: "Slack"), "remove automation")
        ETest.eq(phrase("delete automation open Slack"), .removeAutomation(name: "open Slack"), "delete automation name")
        ETest.eq(phrase("cancel the morning schedule"), .removeAutomation(name: "morning"), "cancel schedule")
        ETest.eq(phrase("delete the standup macro"), .removeAutomation(name: "standup"), "delete macro")
        ETest.eq(phrase("remove macro standup"), .removeAutomation(name: "standup"), "remove macro name")

        ETest.eq(phrase("record a macro called standup"), .recordMacro(name: "standup"), "record named")
        ETest.eq(phrase("start recording a macro named Morning Setup"), .recordMacro(name: "Morning Setup"), "record named, case kept")
        ETest.eq(phrase("watch me"), .recordMacro(name: ""), "watch me")
        ETest.eq(phrase("watch me and call it standup"), .recordMacro(name: "standup"), "watch me and call it")
        ETest.eq(phrase("learn this macro"), .recordMacro(name: ""), "learn")
        ETest.eq(phrase("stop recording the macro"), .stopRecordingMacro, "stop macro")
        ETest.eq(phrase("stop watching"), .stopRecordingMacro, "stop watching")
        ETest.eq(phrase("stop watching me"), .stopRecordingMacro, "stop watching me")
        ETest.eq(phrase("run my standup macro"), .runMacro(name: "standup"), "run my X macro")
        ETest.eq(phrase("run macro standup"), .runMacro(name: "standup"), "run macro X")
        ETest.eq(phrase("play back the morning setup macro"), .runMacro(name: "morning setup"), "play back")
        ETest.eq(phrase("do my standup macro"), .runMacro(name: "standup"), "do")
    }

    private static func notStealing() {
        let others = [
            "open Chrome", "open Slack at 5", "quit Safari", "set a timer for 20 minutes", "remind me in 20 minutes to call mom",
            "remind me to call mom tomorrow", "stop recording", "start recording the meeting", "stop", "what's on my calendar today",
            "what's my schedule", "show my schedule", "play some music", "play my playlist", "remember my locker code is 4321",
            "what's the weather", "when is my next meeting", "when does my class start", "join my next meeting",
            "every time", "what is my next meeting", "cancel the timer", "cancel", "delete the last note", "remove the last item",
            "undo", "run a task", "watch the video", "show me the macros on this page", "turn on do not disturb",
            "take a screenshot", "in 5 minutes", "at 5 pm", "every day", "list my reminders",
            "when I get home call mom", "stop watching tv", "run the tests", "record the meeting", "start a timer",
        ]
        for text in others { ETest.eq(phrase(text), nil, "must not steal: \(text)") }
    }

    // MARK: Store

    private static func store() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rio-automation-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RioAutomationStore(directory: directory)
        ETest.eq(store.data.schedules.isEmpty && store.data.macros.isEmpty, true, "starts empty")

        let schedule = item(.daily, fire: date(2026, 11, 4, 8))
        store.add(schedule)
        store.add(RioTriggerRule(id: UUID(), command: "open Spotify", kind: .audioOutput(name: "AirPods"), createdAt: now, lastFired: nil))
        store.save(RioMacro(id: UUID(), name: "Standup", steps: [.switchToApp(name: "Notes"), .typeText("hi")], createdAt: now))
        store.save(RioMacro(id: UUID(), name: "standup", steps: [.switchToApp(name: "Mail")], createdAt: now))
        ETest.eq(store.data.macros.count, 1, "same macro name replaces")
        ETest.eq(store.macro(named: "STANDUP")?.steps, [.switchToApp(name: "Mail")], "lookup ignores case")

        let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(RioAutomationStore.fileName).path)
        ETest.eq((attributes?[.posixPermissions] as? NSNumber)?.intValue, 0o600, "file is 0600")
        let reloaded = RioAutomationStore(directory: directory)
        ETest.eq(reloaded.data, store.data, "round trip through disk")

        ETest.eq(reloaded.remove(matching: "nothing like this"), .notFound, "no match")
        ETest.eq(reloaded.remove(matching: "standup"), .removed("standup macro"), "remove macro")
        ETest.eq(reloaded.remove(matching: "airpods"), .removed("open Spotify when AirPods connect"), "remove trigger by device")
        ETest.eq(reloaded.remove(matching: "slack"), .removed("open Slack every day at 8:00 AM"), "remove schedule by command")
        ETest.eq(reloaded.data.isEmpty, true, "all removed")

        reloaded.add(item(.daily, fire: date(2026, 11, 4, 8)))
        var second = item(.daily, fire: date(2026, 11, 4, 9))
        second.command = "open Slack channel"
        reloaded.add(second)
        if case .ambiguous(let names) = reloaded.remove(matching: "slack") {
            ETest.eq(names.count, 2, "ambiguous names both listed")
        } else {
            TestSupport.expect(false, "two matches must be ambiguous")
        }
        ETest.eq(reloaded.data.schedules.count, 2, "ambiguous removes nothing")

        // A damaged file is set aside, not overwritten.
        try? Data("{not json".utf8).write(to: directory.appendingPathComponent(RioAutomationStore.fileName))
        let damaged = RioAutomationStore(directory: directory)
        ETest.eq(damaged.data.isEmpty, true, "damaged file loads empty")
        ETest.eq(damaged.recoveredCorruptFile != nil, true, "damaged file kept aside")

        let summary = RioAutomationText.summary(reloaded.data, calendar: calendar)
        TestSupport.expect(summary.contains("open Slack"), "summary lists schedules")
        ETest.eq(RioAutomationText.summary(RioAutomationData(), calendar: calendar), "You have no automations or macros yet.", "empty summary")
    }
}
