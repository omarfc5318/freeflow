import Foundation

/// Pure tests for the undo inverse table and the undo stack.
enum RioUndoPlanTests {
    private typealias Snapshot = RioUndoSnapshot

    private static func disposition(_ action: RioAction, _ snapshot: Snapshot = Snapshot()) -> RioUndoPlan.Disposition {
        RioUndoPlan.disposition(for: action, snapshot: snapshot)
    }

    private static func reversible(_ actions: RioAction...) -> RioUndoPlan.Disposition {
        .reversible(.actions(actions))
    }

    static func run() {
        testAppInverses()
        testVolumeInverses()
        testBrightnessAndWindow()
        testTimerInverses()
        testToggleInverses()
        testCreatedItems()
        testIrreversibleActions()
        testIgnoredActions()
        testSummaries()
        testStack()
    }

    private static func testAppInverses() {
        // A freshly launched app is quit again.
        TestSupport.expectEqual(
            disposition(.openApp(name: "chrome"), Snapshot(wasRunning: false, resolvedAppName: "Google Chrome", previousFrontApp: "Notes")),
            reversible(.quitApp(name: "Google Chrome"))
        )
        // An app that was already running just hands focus back.
        TestSupport.expectEqual(
            disposition(.openApp(name: "chrome"), Snapshot(wasRunning: true, resolvedAppName: "Google Chrome", previousFrontApp: "Notes")),
            reversible(.switchToApp(name: "Notes"))
        )
        TestSupport.expectEqual(
            disposition(.switchToApp(name: "slack"), Snapshot(wasRunning: true, resolvedAppName: "Slack", previousFrontApp: "Safari")),
            reversible(.switchToApp(name: "Safari"))
        )
        TestSupport.expectEqual(
            disposition(.switchToApp(name: "slack"), Snapshot(wasRunning: false, resolvedAppName: "Slack", previousFrontApp: "Safari")),
            reversible(.quitApp(name: "Slack"))
        )
        // Nothing to hand focus back to, nothing to undo.
        TestSupport.expectEqual(
            disposition(.openApp(name: "chrome"), Snapshot(wasRunning: true, resolvedAppName: "Google Chrome", previousFrontApp: "Google Chrome")),
            .irreversible
        )
        TestSupport.expectEqual(disposition(.openApp(name: "zzz")), .irreversible)
        // quit -> reopen, but only if it was running.
        TestSupport.expectEqual(
            disposition(.quitApp(name: "spotify"), Snapshot(wasRunning: true, resolvedAppName: "Spotify")),
            reversible(.openApp(name: "Spotify"))
        )
        TestSupport.expectEqual(disposition(.quitApp(name: "spotify"), Snapshot(wasRunning: false, resolvedAppName: "Spotify")), .ignore)
        // hide -> bring it back.
        TestSupport.expectEqual(
            disposition(.hideApp(name: "slack"), Snapshot(wasRunning: true, resolvedAppName: "Slack")),
            reversible(.switchToApp(name: "Slack"))
        )
        TestSupport.expectEqual(disposition(.hideApp(name: "slack"), Snapshot(wasRunning: false, resolvedAppName: "Slack")), .ignore)
    }

    private static func testVolumeInverses() {
        TestSupport.expectEqual(disposition(.volume(.up), Snapshot(volumeLevel: 30, wasMuted: false)), reversible(.volume(.set(30))))
        TestSupport.expectEqual(disposition(.volume(.set(80)), Snapshot(volumeLevel: 30, wasMuted: false)), reversible(.volume(.set(30))))
        // Raising the volume unmutes; undo restores the level and the mute.
        TestSupport.expectEqual(
            disposition(.volume(.up), Snapshot(volumeLevel: 0, wasMuted: true)),
            reversible(.volume(.set(0)), .volume(.mute))
        )
        TestSupport.expectEqual(disposition(.volume(.up), Snapshot()), .irreversible)
        TestSupport.expectEqual(disposition(.volume(.mute), Snapshot(volumeLevel: 30, wasMuted: false)), reversible(.volume(.unmute)))
        TestSupport.expectEqual(disposition(.volume(.mute), Snapshot(volumeLevel: 30, wasMuted: true)), .ignore)
        TestSupport.expectEqual(disposition(.volume(.unmute), Snapshot(volumeLevel: 30, wasMuted: true)), reversible(.volume(.mute)))
        TestSupport.expectEqual(disposition(.volume(.unmute), Snapshot(volumeLevel: 30, wasMuted: false)), .ignore)
        TestSupport.expectEqual(disposition(.volume(.mute), Snapshot()), .irreversible)
    }

    private static func testBrightnessAndWindow() {
        TestSupport.expectEqual(disposition(.brightness(.up), Snapshot(brightness: 40)), reversible(.brightness(.set(40))))
        TestSupport.expectEqual(disposition(.brightness(.set(90)), Snapshot(brightness: 55)), reversible(.brightness(.set(55))))
        TestSupport.expectEqual(disposition(.brightness(.up), Snapshot()), .irreversible)
        let move = RioAction.window(WindowCommand(appName: "Chrome", placement: .leftHalf))
        TestSupport.expectEqual(disposition(move, Snapshot(hasWindowSnapshot: true)), .reversible(.restoreWindow))
        TestSupport.expectEqual(disposition(move, Snapshot(hasWindowSnapshot: false)), .irreversible)
    }

    private static func testTimerInverses() {
        TestSupport.expectEqual(disposition(.startTimer(seconds: 60, label: nil)), .reversible(.cancelCountdown))
        TestSupport.expectEqual(
            disposition(.cancelTimer, Snapshot(timerRemaining: 125, timerLabel: "pasta")),
            reversible(.startTimer(seconds: 125, label: "pasta"))
        )
        TestSupport.expectEqual(disposition(.cancelTimer, Snapshot()), .ignore)
        TestSupport.expectEqual(disposition(.cancelTimer, Snapshot(timerRemaining: 0)), .ignore)
    }

    private static func testToggleInverses() {
        TestSupport.expectEqual(disposition(.media(.playPause)), reversible(.media(.playPause)))
        TestSupport.expectEqual(disposition(.media(.next)), reversible(.media(.previous)))
        TestSupport.expectEqual(disposition(.media(.previous)), reversible(.media(.next)))
        TestSupport.expectEqual(disposition(.doNotDisturb(isOn: true)), reversible(.doNotDisturb(isOn: false)))
        TestSupport.expectEqual(disposition(.systemToggle(.darkMode, isOn: true)), reversible(.systemToggle(.darkMode, isOn: false)))
        TestSupport.expectEqual(disposition(.systemToggle(.nightShift, isOn: false)), reversible(.systemToggle(.nightShift, isOn: true)))
        // Turning Wi-Fi or Bluetooth off can be reversed; turning on can't be (we don't know the prior state).
        TestSupport.expectEqual(disposition(.systemToggle(.wifi, isOn: false)), reversible(.systemToggle(.wifi, isOn: true)))
        TestSupport.expectEqual(disposition(.systemToggle(.bluetooth, isOn: false)), reversible(.systemToggle(.bluetooth, isOn: true)))
        TestSupport.expectEqual(disposition(.systemToggle(.wifi, isOn: true)), .irreversible)
        TestSupport.expectEqual(disposition(.systemToggle(.bluetooth, isOn: true)), .irreversible)
    }

    private static func testCreatedItems() {
        let event = RioAction.createEvent(title: "Lunch", start: Date(timeIntervalSince1970: 0), durationMinutes: 60)
        TestSupport.expectEqual(
            disposition(event, Snapshot(created: .calendarEvent(identifier: "EV-1"))),
            .reversible(.deleteCreated(.calendarEvent(identifier: "EV-1")))
        )
        TestSupport.expectEqual(disposition(event), .irreversible)
        let reminder = RioAction.createReminder(title: "Milk", due: nil)
        TestSupport.expectEqual(
            disposition(reminder, Snapshot(created: .reminder(identifier: "RM-9"))),
            .reversible(.deleteCreated(.reminder(identifier: "RM-9")))
        )
        TestSupport.expectEqual(disposition(reminder), .irreversible)
    }

    private static func testIrreversibleActions() {
        let url = URL(string: "https://example.com")!
        let actions: [RioAction] = [
            .sendMessage(to: "Ali", body: "hi"), .replyInConversation(body: "ok"), .screenshot(.fullScreen),
            .typeText("hello"), .lockScreen, .selectionTask(.improve), .openURL(url), .webSearch(query: "cats"),
            .pressKeys(KeyCombo(key: "t", command: true, shift: false, option: false, control: false)),
            .browser(.newTab), .emptyTrash, .joinNextMeeting, .openFile(query: "resume"),
            .revealFile(query: "resume"), .clipboard(.pasteRecent(matching: "link")),
        ]
        for action in actions {
            TestSupport.expectEqualNamed(disposition(action), .irreversible, "\(action) can't be undone")
        }
        TestSupport.expectEqual(RioUndoPlan.cantUndoMessage, "I can't undo that one")
    }

    private static func testIgnoredActions() {
        let actions: [RioAction] = [
            .undoLast, .showHelp, .timerStatus, .answer("hi"), .readAloud(.selection), .calendarAgenda(.today),
            .batteryStatus, .stopListening, .clipboard(.readCurrent), .clipboard(.showHistory), .selectionTask(.summarize),
        ]
        for action in actions {
            TestSupport.expectEqualNamed(disposition(action), .ignore, "\(action) is read-only")
        }
    }

    private static func testSummaries() {
        TestSupport.expectEqual(RioUndoPlan.undoneSummary(for: .actions([.quitApp(name: "Google Chrome")])), "Undone: closed Google Chrome")
        TestSupport.expectEqual(RioUndoPlan.undoneSummary(for: .actions([.openApp(name: "Spotify")])), "Undone: reopened Spotify")
        TestSupport.expectEqual(RioUndoPlan.undoneSummary(for: .actions([.switchToApp(name: "Notes")])), "Undone: back to Notes")
        TestSupport.expectEqual(RioUndoPlan.undoneSummary(for: .actions([.volume(.set(30))])), "Undone: volume back to 30 percent")
        TestSupport.expectEqual(RioUndoPlan.undoneSummary(for: .actions([.volume(.set(0)), .volume(.mute)])), "Undone: volume back to 0 percent")
        TestSupport.expectEqual(RioUndoPlan.undoneSummary(for: .actions([.volume(.unmute)])), "Undone: unmuted")
        TestSupport.expectEqual(RioUndoPlan.undoneSummary(for: .actions([.volume(.mute)])), "Undone: muted again")
        TestSupport.expectEqual(RioUndoPlan.undoneSummary(for: .actions([.brightness(.set(55))])), "Undone: brightness back to 55 percent")
        TestSupport.expectEqual(RioUndoPlan.undoneSummary(for: .actions([.cancelTimer])), "Undone: timer cancelled")
        TestSupport.expectEqual(RioUndoPlan.undoneSummary(for: .actions([.startTimer(seconds: 60, label: nil)])), "Undone: timer is back")
        TestSupport.expectEqual(RioUndoPlan.undoneSummary(for: .restoreWindow), "Undone: window put back")
        TestSupport.expectEqual(RioUndoPlan.undoneSummary(for: .deleteCreated(.calendarEvent(identifier: "x"))), "Undone: removed the event")
        TestSupport.expectEqual(RioUndoPlan.undoneSummary(for: .deleteCreated(.reminder(identifier: "x"))), "Undone: removed the reminder")
        TestSupport.expectEqual(RioUndoPlan.nothingToUndoMessage, "There's nothing to undo")
    }

    private static func testStack() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var stack = RioUndoStack(limit: 3, maxAge: 600)
        TestSupport.expect(stack.pop(now: t0) == nil, "empty stack")
        let a = RioUndoRecord(action: .volume(.up), disposition: reversible(.volume(.set(10))), date: t0)
        let b = RioUndoRecord(action: .lockScreen, disposition: .irreversible, date: t0.addingTimeInterval(10))
        let c = RioUndoRecord(action: .media(.next), disposition: reversible(.media(.previous)), date: t0.addingTimeInterval(20))
        let d = RioUndoRecord(action: .doNotDisturb(isOn: true), disposition: reversible(.doNotDisturb(isOn: false)), date: t0.addingTimeInterval(30))
        stack.push(a)
        stack.push(b)
        // The newest entry comes back first, and an irreversible one answers "can't undo" rather than
        // quietly undoing something older.
        TestSupport.expectEqual(stack.pop(now: t0.addingTimeInterval(40))?.action, .lockScreen)
        TestSupport.expectEqual(stack.pop(now: t0.addingTimeInterval(40))?.action, .volume(.up))
        TestSupport.expect(stack.pop(now: t0.addingTimeInterval(40)) == nil, "drained")

        // The limit drops the oldest entries.
        stack.push(a); stack.push(b); stack.push(c); stack.push(d)
        TestSupport.expectEqual(stack.count, 3)
        TestSupport.expectEqual(stack.pop(now: t0.addingTimeInterval(40))?.action, .doNotDisturb(isOn: true))
        TestSupport.expectEqual(stack.pop(now: t0.addingTimeInterval(40))?.action, .media(.next))
        TestSupport.expectEqual(stack.pop(now: t0.addingTimeInterval(40))?.action, .lockScreen)

        // Old entries expire: nobody expects "undo" to reach back an hour.
        stack.push(a)
        TestSupport.expect(stack.pop(now: t0.addingTimeInterval(601)) == nil, "expired entry is gone")
        TestSupport.expectEqual(stack.count, 0)

        // Ignored actions are never recorded.
        stack.record(.answer("hi"), disposition: .ignore, now: t0)
        TestSupport.expectEqual(stack.count, 0)
        stack.record(.media(.next), disposition: reversible(.media(.previous)), now: t0)
        TestSupport.expectEqual(stack.count, 1)
    }
}
