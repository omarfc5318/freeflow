import Foundation

/// Round 3, group "wake-conversation-coordinator": waking on unpunctuated speech, stop listening
/// inside a chain, WhatsApp texts, typed-then-submitted confirmations, editor terminals, the
/// quiet-room wake gap, busy commands, lead-ins, the action-key brake, Rio quitting himself, the
/// echo-tail stop, action-key bare stops, Gulf yes/thanks, and Arabic local replies.
/// Transcripts are unpunctuated, as the live recognizer gives them. Synthetic data only.
enum RioR3ConversationTests {
    private static func wake(_ transcript: String) -> String? { WakePhraseExtractor.command(in: transcript) }

    @MainActor static func run() async {
        wakesOnNamesAppsNumbersAndQuestions()
        stillIgnoresTalkAboutRio()
        pauseAfterNameAddresses()
        naturalLeadIns()
        quietRoomListening()
        stopListeningInsideAChain()
        busyCommandsWait()
        await whatsappTextsSayIMessage()
        await typedThenSubmittedShowsEveryStep()
        await editorTerminalsAsk()
        actionKeyTapStillBrakes()
        await rioRefusesToQuitOrHideWithoutAPanel()
        stopAfterRioFinishedPausesMedia()
        actionKeyBareStops()
        gulfYesAndThanks()
        arabicLocalReplies()
    }

    // MARK: Finding 18+60+87

    private static func wakesOnNamesAppsNumbersAndQuestions() {
        let woken: [(String, String)] = [
            ("Rio Claude run the tests", "Claude run the tests"),
            ("Rio Claude what are you doing", "Claude what are you doing"),
            ("Rio Spotify", "Spotify"), ("Rio YouTube", "YouTube"), ("Rio YouTube lofi", "YouTube lofi"),
            ("Rio Chrome please", "Chrome please"), ("Rio Netflix", "Netflix"),
            ("Rio WhatsApp Ahmed I'm on my way", "WhatsApp Ahmed I'm on my way"), ("Rio Louder", "Louder"),
            ("Rio 5 minute timer", "5 minute timer"), ("Rio 10 minute timer", "10 minute timer"), ("Rio 10 minutes", "10 minutes"),
            ("Rio a bit louder", "a bit louder"), ("Rio a bit quieter", "a bit quieter"),
            ("Rio a little quieter please", "a little quieter please"), ("Rio a timer for 5 minutes", "a timer for 5 minutes"),
            ("Rio the weather", "the weather"), ("Rio the weather tomorrow", "the weather tomorrow"),
            ("Rio the time please", "the time please"), ("Rio the other one", "the other one"),
            ("Rio is Claude done", "is Claude done"), ("Rio, is claude done", "is claude done"),
            ("Rio, is the answer B", "is the answer B"), ("Rio is the build done", "is the build done"),
            ("Rio is Spotify playing", "is Spotify playing"), ("Rio has the build finished", "has the build finished"),
            ("Rio, is the oven timer done", "is the oven timer done"), ("Rio, was the email sent", "was the email sent"),
            ("Rio are the lights on", "are the lights on"), ("Rio has the package arrived", "has the package arrived"),
        ]
        for (heard, command) in woken {
            ETest.eq(wake(heard), command, "\(heard) wakes Rio")
        }
    }

    private static func stillIgnoresTalkAboutRio() {
        let statements = [
            "Rio is a 2011 animated film", "Rio was released in 2011", "Rio 2 came out in 2014", "Rio 2 is my favorite movie",
            "Rio Ferdinand scored a goal", "Rio the parrot is so cute", "Rio the movie is great", "Rio has a great soundtrack",
            "Rio de Janeiro is beautiful", "Rio has been praised by critics", "Rio was the best film of the year",
            "Rio is so cute", "Rio was directed by Carlos Saldanha", "Rio is Spanish for river", "Rio Olympics were in 2016",
        ]
        for heard in statements {
            ETest.eq(wake(heard), nil, "\(heard) is talk about Rio")
        }
    }

    private static func pauseAfterNameAddresses() {
        typealias W = WakePhraseExtractor.TimedWord
        // "Rio [pause] is Ahmed here": the recognizer writes no comma, the timing shows one.
        let paused = [W(text: "Rio", start: 0.2, duration: 0.3), W(text: "is", start: 0.85, duration: 0.1),
                      W(text: "Ahmed", start: 1.0, duration: 0.3), W(text: "here", start: 1.35, duration: 0.2)]
        ETest.eq(WakePhraseExtractor.transcript(from: paused), "Rio, is Ahmed here")
        ETest.eq(WakePhraseExtractor.command(in: paused), "is Ahmed here")
        // Run together, "Rio is Ahmeds friend" stays a statement.
        ETest.eq(wake("Rio is Ahmeds friend"), nil)
        // No timing: nothing is inserted.
        let untimed = ["Rio", "is", "Ahmed", "here"].map { W(text: $0, start: 0, duration: 0) }
        ETest.eq(WakePhraseExtractor.transcript(from: untimed), "Rio is Ahmed here")
    }

    // MARK: Finding 62

    private static func naturalLeadIns() {
        for heard in ["yeah Rio open chrome", "ya Rio open chrome", "yalla Rio open chrome", "dude Rio open chrome",
                      "yah Rio open chrome", "bro Rio open chrome"] {
            ETest.eq(wake(heard), "open chrome", "\(heard) wakes Rio")
        }
        ETest.eq(wake("يا ريو افتح سفاري"), "افتح سفاري")
        // Mentions inside a sentence are still not commands.
        ETest.eq(wake("I watched Rio yesterday"), nil)
        ETest.eq(wake("yeah Rio 2 was good"), nil)
        ETest.eq(wake("I told dude Rio open chrome"), nil)
    }

    // MARK: Finding 92+76

    private static func quietRoomListening() {
        let delays = (1...20).map { WakeListenTiming.emptyFinalDelay(consecutive: $0) }
        TestSupport.expect(delays.allSatisfy { $0 <= 1.5 }, "never deaf for more than 1.5 s")
        TestSupport.expect(WakeListenTiming.preRollSeconds >= 0.5, "the start of the command is replayed")
        // A normal voice a metre away (RMS about 0.02) trips the gate within a few buffers.
        var voice = WakeSoundGate()
        let tripped = (0..<3).contains { _ in voice.feed(rms: 0.02, seconds: 0.0427) }
        TestSupport.expect(tripped, "a soft voice wakes the listener")
        // One key click (one loud buffer) still doesn't; a quiet fan never does.
        var click = WakeSoundGate()
        TestSupport.expect(!click.feed(rms: 0.3, seconds: 0.0427), "one click")
        TestSupport.expect(!click.feed(rms: 0.002, seconds: 0.0427), "then quiet")
        var fan = WakeSoundGate()
        TestSupport.expect(!(0..<200).contains { _ in fan.feed(rms: 0.01, seconds: 0.0427) }, "a quiet fan")
    }

    // MARK: Finding 61 (+ 63's barge-in)

    private static func stopListeningInsideAChain() {
        let parser = RioActionParser(installedApps: [])
        for phrase in ["stop the music and go to sleep", "stop listening and lock the screen"] {
            guard case .actions(let actions) = parser.parse(phrase) else {
                TestSupport.expect(false, "\(phrase) parses")
                continue
            }
            TestSupport.expect(RioConversationCommands.includesStopListening(actions), "\(phrase) turns the mic off")
            TestSupport.expect(!RioConversationCommands.isStopListening(phrase), "\(phrase) is not a bare stop listening")
        }
        TestSupport.expect(!RioConversationCommands.includesStopListening([.lockScreen]), "no stop, no change")
        // While Rio talks, only an exact stop listening (or a bare stop) gets through.
        TestSupport.expect(RioConversationBargeIn.accepts("stop listening", isRioSpeaking: true, secondsSinceRioSpoke: nil),
                           "stop listening while Rio talks")
        TestSupport.expect(RioConversationBargeIn.accepts("go to sleep", isRioSpeaking: false, secondsSinceRioSpoke: 1),
                           "go to sleep in the echo tail")
        TestSupport.expect(!RioConversationBargeIn.accepts("stop listening and lock the screen", isRioSpeaking: true, secondsSinceRioSpoke: nil),
                           "a chain never rides along on Rio's own voice")
        TestSupport.expect(!RioConversationBargeIn.accepts("open chrome", isRioSpeaking: true, secondsSinceRioSpoke: nil),
                           "commands still wait for Rio to finish")
    }

    // MARK: Finding 63

    private static func busyCommandsWait() {
        let start = Date(timeIntervalSince1970: 1_000)
        var pending = RioConversationPending()
        ETest.eq(pending.next(now: start, isBusy: false), .none)
        pending.offer("open safari", now: start)
        pending.offer("open chrome", now: start.addingTimeInterval(1))
        ETest.eq(pending.next(now: start.addingTimeInterval(2), isBusy: true), .wait)
        ETest.eq(pending.next(now: start.addingTimeInterval(3), isBusy: false), .run("open chrome"), "the newest wins")
        TestSupport.expect(pending.isEmpty, "runs once")
        pending.offer("open notes", now: start)
        ETest.eq(
            pending.next(now: start.addingTimeInterval(RioConversationPending.lifetime + 1), isBusy: false), .expired,
            "never runs long after it was said"
        )
        TestSupport.expect(pending.isEmpty, "an expired command is dropped")
    }

    // MARK: Finding 50

    private struct RealParser: RioActionParsing {
        let parser = RioActionParser(installedApps: [])
        func parse(_ transcript: String) -> RioActionParse { parser.parse(transcript) }
    }

    @MainActor private static func whatsappTextsSayIMessage() async {
        let title = RioConfirmationContent.make(for: .sendMessage(to: "Ahmed", body: "hi"), appName: nil, resolvedRecipient: nil)?.title
        ETest.eq(title, "Send an iMessage to Ahmed?")

        let open = URL(string: "https://web.whatsapp.com")!
        let plan: [RioAction] = [.openURL(open), .sendMessage(to: "Ahmed", body: "hi")]
        ETest.eq(
            RioActionCoordinator.localMessagingGuard(plan, command: "open WhatsApp and text Ahmed saying hi"),
            [.openURL(open), .answer(RioSmartPlanGuards.otherAppAnswer("WhatsApp"))]
        )
        let app: [RioAction] = [.openApp(name: "Slack"), .sendMessage(to: "Sara", body: "running late")]
        ETest.eq(
            RioActionCoordinator.localMessagingGuard(app, command: "open slack and message Sara saying running late"),
            [.openApp(name: "Slack"), .answer(RioSmartPlanGuards.otherAppAnswer("Slack"))]
        )
        // A plain text, or one whose message only mentions WhatsApp, is untouched.
        let plain: [RioAction] = [.sendMessage(to: "Mom", body: "check WhatsApp")]
        ETest.eq(RioActionCoordinator.localMessagingGuard(plain, command: "text mom saying check WhatsApp"), plain)

        // Through the coordinator with the real parser: nothing is ever sent.
        let executor = Executor()
        let confirmer = Confirmer(answer: true)
        let coordinator = RioActionCoordinator(
            parser: RealParser(), executor: executor, confirmer: confirmer, followUps: RioFollowUpMemory()
        )
        _ = await coordinator.run("Rio open WhatsApp and text Ahmed saying hi", source: .actionKey)
        TestSupport.expect(!executor.executed.contains { if case .sendMessage = $0 { return true } else { return false } },
                           "no iMessage goes out for a WhatsApp request")
        TestSupport.expect(confirmer.plain.isEmpty, "and nothing to confirm")
    }

    // MARK: Finding 83+91

    private struct FixedParser: RioActionParsing {
        let result: RioActionParse
        func parse(_ transcript: String) -> RioActionParse { result }
    }

    private final class TableParser: RioActionParsing, @unchecked Sendable {
        let table: [String: RioActionParse]
        init(_ table: [String: RioActionParse]) { self.table = table }
        func parse(_ transcript: String) -> RioActionParse { table[transcript] ?? .unknown(transcript) }
    }

    @MainActor private final class Executor: RioActionExecuting, RioFrontAppReporting {
        var executed: [RioAction] = []
        var front: RioFrontApp
        /// The front app after the first typing (focus moved while Rio typed).
        var frontAfterTyping: RioFrontApp?
        init(front: RioFrontApp = RioFrontApp(name: "Notes", bundleID: "com.apple.Notes")) { self.front = front }
        func execute(_ action: RioAction) async -> RioActionResult {
            executed.append(action)
            if case .typeText = action, let moved = frontAfterTyping { front = moved }
            return .done(summary: "ok")
        }
        func frontmostApp() -> RioFrontApp { front }
    }

    @MainActor private final class Confirmer: RioConfirming, RioConversationConfirming {
        var plain: [RioAction] = []
        var single: [RioAction] = []
        var submits: [(steps: [RioAction], alreadyTyped: Bool, app: String?)] = []
        let answer: Bool
        init(answer: Bool) { self.answer = answer }
        func confirm(_ action: RioAction) async -> Bool { plain.append(action); return answer }
        func confirmConversationAction(_ action: RioAction) async -> Bool { single.append(action); return answer }
        func confirmConversationSubmit(_ steps: [RioAction], alreadyTyped: Bool, appName: String?) async -> Bool {
            submits.append((steps, alreadyTyped, appName))
            return answer
        }
    }

    private static func key(_ key: String, command: Bool = false) -> KeyCombo {
        KeyCombo(key: key, command: command, shift: false, option: false, control: false)
    }

    @MainActor private static func typedThenSubmittedShowsEveryStep() async {
        // The panel shows the text AND the Return, and where it goes.
        let pair = RioConfirmationContent.conversationSubmit(
            [.typeText("git push --force"), .pressKeys(key("return"))], alreadyTyped: false, appName: "Terminal"
        )
        ETest.eq(pair.detail, "Type \u{201C}git push --force\u{201D}, then press Return in Terminal")
        let three = RioConfirmationContent.conversationSubmit(
            [.typeText("I agree"), .pressKeys(key("space")), .pressKeys(key("return"))], alreadyTyped: false, appName: "Safari"
        )
        ETest.eq(three.detail, "Type \u{201C}I agree\u{201D}, press space, then press Return in Safari")
        let later = RioConfirmationContent.conversationSubmit(
            [.typeText("hello"), .pressKeys(key("return"))], alreadyTyped: true, appName: "Notes"
        )
        ETest.eq(later.detail, "Press Return to submit \u{201C}hello\u{201D} in Notes")

        // "type I agree and then press space and then press enter", trust on: asked once, all shown.
        let plan: [RioAction] = [.typeText("I agree"), .pressKeys(key("space")), .pressKeys(key("return"))]
        let executor = Executor()
        let confirmer = Confirmer(answer: true)
        let coordinator = RioActionCoordinator(
            parser: FixedParser(result: .actions(plan)), executor: executor, confirmer: confirmer,
            isTrustingConversation: { true }, followUps: RioFollowUpMemory()
        )
        _ = await coordinator.run("Rio type I agree and then press space and then press enter", source: .conversation)
        ETest.eq(confirmer.submits.count, 1, "one question for the whole submit")
        ETest.eq(confirmer.submits.first?.steps, plan)
        ETest.eq(confirmer.submits.first?.app, "Notes")
        ETest.eq(executor.executed, plan)

        // Typing then Return with another kind of step between: the Return asks on its own, showing the text.
        let clicky: [RioAction] = [.typeText("yes"), .browser(.reload), .pressKeys(key("return"))]
        let clickExecutor = Executor()
        let clickConfirmer = Confirmer(answer: false)
        let clickCoordinator = RioActionCoordinator(
            parser: FixedParser(result: .actions(clicky)), executor: clickExecutor, confirmer: clickConfirmer,
            isTrustingConversation: { true }, followUps: RioFollowUpMemory()
        )
        let outcome = await clickCoordinator.run("Rio do it", source: .conversation)
        ETest.eq(outcome, .cancelled)
        ETest.eq(clickConfirmer.submits.first?.alreadyTyped, true)
        TestSupport.expect(!clickExecutor.executed.contains(.pressKeys(key("return"))), "the Return never went out")

        // Two utterances: "Rio type …", then "Rio press enter" in the same app, asks.
        let two = TableParser([
            "type git push": .actions([.typeText("git push")]),
            "press enter": .actions([.pressKeys(key("return"))]),
        ])
        let twoExecutor = Executor()
        let twoConfirmer = Confirmer(answer: false)
        let twoCoordinator = RioActionCoordinator(
            parser: two, executor: twoExecutor, confirmer: twoConfirmer, isTrustingConversation: { true },
            followUps: RioFollowUpMemory()
        )
        _ = await twoCoordinator.run("Rio type git push", source: .conversation)
        let enter = await twoCoordinator.run("Rio press enter", source: .conversation)
        ETest.eq(enter, .cancelled, "the second command's Return is asked")
        ETest.eq(twoConfirmer.submits.first?.steps, [.typeText("git push"), .pressKeys(key("return"))])
        ETest.eq(twoExecutor.executed, [.typeText("git push")])
        // In another app (or with no typing before), a Return runs as before with trust on.
        twoExecutor.front = RioFrontApp(name: "Safari", bundleID: "com.apple.Safari")
        let elsewhere = await twoCoordinator.run("Rio press enter", source: .conversation)
        ETest.eq(elsewhere, .succeeded("ok"))
        // The action key is the owner: unchanged.
        let keyExecutor = Executor()
        let keyCoordinator = RioActionCoordinator(
            parser: two, executor: keyExecutor, confirmer: Confirmer(answer: false), followUps: RioFollowUpMemory()
        )
        _ = await keyCoordinator.run("Rio type git push", source: .actionKey)
        let keyEnter = await keyCoordinator.run("Rio press enter", source: .actionKey)
        ETest.eq(keyEnter, .succeeded("ok"))

        // The approved Return never goes to a different app.
        let moved = Executor()
        moved.frontAfterTyping = RioFrontApp(name: "Terminal", bundleID: "com.apple.Terminal")
        let movedCoordinator = RioActionCoordinator(
            parser: FixedParser(result: .actions([.typeText("hi"), .pressKeys(key("return"))])), executor: moved,
            confirmer: Confirmer(answer: true), isTrustingConversation: { true }, followUps: RioFollowUpMemory()
        )
        let movedOutcome = await movedCoordinator.run("Rio type hi and press enter", source: .conversation)
        ETest.eq(movedOutcome, .failed(RioActionText.frontAppChangedMessage))
        ETest.eq(moved.executed, [.typeText("hi")])
    }

    // MARK: Finding 82

    @MainActor private static func editorTerminalsAsk() async {
        let editors = [
            RioFrontApp(name: "Code", bundleID: "com.microsoft.VSCode"),
            RioFrontApp(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92"),
            RioFrontApp(name: "Zed", bundleID: "dev.zed.Zed"),
            RioFrontApp(name: "PyCharm", bundleID: "com.jetbrains.pycharm"),
        ]
        for editor in editors {
            TestSupport.expect(RioTaskSafety.isTerminalCapable(appName: editor.name, bundleID: editor.bundleID), "\(editor) can hold a terminal")
            let executor = Executor(front: editor)
            let confirmer = Confirmer(answer: false)
            let coordinator = RioActionCoordinator(
                parser: FixedParser(result: .actions([.pressKeys(key("return"))])), executor: executor, confirmer: confirmer,
                isTrustingConversation: { true }, followUps: RioFollowUpMemory()
            )
            let outcome = await coordinator.run("Rio press enter", source: .conversation)
            ETest.eq(outcome, .cancelled, "a heard Return in \(editor.name ?? "") asks")
            ETest.eq(executor.executed, [])
        }
        TestSupport.expect(RioTaskSafety.isTerminalCapable(appName: "Visual Studio Code"), "by name")
        TestSupport.expect(!RioTaskSafety.isTerminalCapable(appName: "Notes", bundleID: "com.apple.Notes"), "Notes is not")
        // The task agent's own terminal rule is unchanged: it may still work in an editor.
        TestSupport.expect(!RioTaskSafety.isTerminal(appName: "Code", bundleID: "com.microsoft.VSCode"), "isTerminal unchanged")
        // Typing into "switch to Cursor and type …" asks too.
        let executor = Executor()
        let confirmer = Confirmer(answer: false)
        let coordinator = RioActionCoordinator(
            parser: FixedParser(result: .actions([.switchToApp(name: "Cursor"), .typeText("rm -rf build")])),
            executor: executor, confirmer: confirmer, isTrustingConversation: { true }, followUps: RioFollowUpMemory()
        )
        _ = await coordinator.run("Rio switch to cursor and type it", source: .conversation)
        ETest.eq(executor.executed, [.switchToApp(name: "Cursor")])
    }

    // MARK: Finding 89

    private static func actionKeyTapStillBrakes() {
        // AppState's path: the action-key event goes to the controller, then the session begins.
        let controller = DictationShortcutSessionController()
        controller.discardsShortHoldTaps = true
        ETest.eq(controller.handle(event: .holdActivated, isTranscribing: false, now: 10), .start(.hold))
        var began = false
        controller.actionModifierEngaged(isTranscribing: false, now: 10.03) {
            began = true
            ETest.eq(controller.activeMode, .hold, "the hold is still running when the session begins")
        }
        TestSupport.expect(began, "the Rio action session begins")
        ETest.eq(controller.handle(event: .holdDeactivated, isTranscribing: false, now: 10.15), .cancelSilently)
        TestSupport.expect(controller.lastSilentCancelWasActionKeyTap, "a quick Fn + Control tap brakes the task")
        // A plain Fn tap is still not the brake.
        _ = controller.handle(event: .holdActivated, isTranscribing: false, now: 20)
        ETest.eq(controller.handle(event: .holdDeactivated, isTranscribing: false, now: 20.1), .cancelSilently)
        TestSupport.expect(!controller.lastSilentCancelWasActionKeyTap, "plain Fn tap")
    }

    // MARK: Finding 97a

    @MainActor private static func rioRefusesToQuitOrHideWithoutAPanel() async {
        let cases: [(RioAction, RioCommandSource, String)] = [
            (.quitApp(name: "Rio"), .actionKey, RioSelfApp.quitRefusalMessage),
            (.quitApp(name: "Rio Dictate"), .conversation, RioSelfApp.refusalMessage),
            (.hideApp(name: "Rio"), .conversation, RioSelfApp.hideRefusalMessage),
            (.hideApp(name: "Rio"), .actionKey, RioSelfApp.hideRefusalMessage),
        ]
        for (action, source, message) in cases {
            let executor = Executor()
            let confirmer = Confirmer(answer: true)
            let coordinator = RioActionCoordinator(
                parser: FixedParser(result: .actions([action])), executor: executor, confirmer: confirmer,
                isTrustingConversation: { true }, followUps: RioFollowUpMemory()
            )
            let outcome = await coordinator.run("Rio do it", source: source)
            ETest.eq(outcome, .failed(message), "\(action) from \(source)")
            TestSupport.expect(confirmer.plain.isEmpty && confirmer.single.isEmpty, "no panel for \(action)")
            ETest.eq(executor.executed, [])
        }
    }

    // MARK: Finding 95

    private static func stopAfterRioFinishedPausesMedia() {
        // "Playing", then "Rio stop" said after he finished: delivered ~2 s after his last word.
        ETest.eq(
            RioConversationStopForward.forwardedCommand(for: "stop", stoppedSomething: false, isRioSpeaking: false, secondsSinceRioSpoke: 2.0),
            "stop"
        )
        // Said while he was still talking: only acknowledged.
        ETest.eq(
            RioConversationStopForward.forwardedCommand(for: "stop", stoppedSomething: false, isRioSpeaking: false, secondsSinceRioSpoke: 0.8),
            nil
        )
        TestSupport.expect(RioConversationStopForward.overlappedRioSpeech(isRioSpeaking: true, secondsSinceRioSpoke: nil), "talking")
        TestSupport.expect(!RioConversationStopForward.overlappedRioSpeech(isRioSpeaking: false, secondsSinceRioSpoke: nil), "never spoke")
    }

    // MARK: Finding 47d

    private static func actionKeyBareStops() {
        let table: [(String, RioConversationCommands.BareStop)] = [
            ("Rio stop stop stop", .stop), ("Rio no no no", .abort), ("Rio hold on", .abort), ("Rio abort", .abort),
            ("Rio cancel", .abort), ("ريو لا لا", .abort),
        ]
        for (heard, kind) in table {
            ETest.eq(RioConversationCommands.bareStop(heard), kind, heard)
        }
        // On the action key nothing is speaking, so a plain stop goes on to pause media when
        // nothing of Rio's was running, and an abort never does.
        ETest.eq(
            RioConversationStopForward.forwardedCommand(for: "Rio stop stop stop", stoppedSomething: false, isRioSpeaking: false, secondsSinceRioSpoke: nil),
            "stop"
        )
        ETest.eq(
            RioConversationStopForward.forwardedCommand(for: "Rio hold on", stoppedSomething: false, isRioSpeaking: false, secondsSinceRioSpoke: nil),
            nil
        )
    }

    // MARK: Finding 58

    private static func gulfYesAndThanks() {
        for yes in ["ريو ايه", "ريو إيه", "ريو تمام", "ريو ايوه", "ريو يب"] {
            ETest.eq(RioConversationCommands.spokenAnswer(yes), .yes, yes)
            ETest.eq(
                RioConversationCommands.quickReply(yes, isConfirmationShowing: false), RioConversationCommands.nothingToConfirmLine, yes
            )
        }
        ETest.eq(RioConversationCommands.spokenAnswer("ريو لا لا"), .no)
        TestSupport.expect(RioConversationCommands.declinesBySpeech("لا"), "a spoken no declines")
        TestSupport.expect(!RioConversationCommands.declinesBySpeech("ايه"), "a spoken yes never approves")
        for thanks in ["ريو تسلم", "ريو ما قصرت", "ريو الله يعطيك العافية", "ريو يعطيك ألف عافية", "ريو مشكور", "ريو يعطيك العافيه"] {
            TestSupport.expect(RioConversationCommands.isThanks(thanks), "\(thanks) is thanks")
        }
        TestSupport.expect(!RioConversationCommands.isThanks("ريو الله"), "a filler alone is not thanks")
    }

    // MARK: Finding 59+70

    private static func arabicLocalReplies() {
        ETest.eq(RioConversationCommands.quickReply("Rio thanks", isConfirmationShowing: false), "You're welcome")
        ETest.eq(RioConversationCommands.quickReply("ريو شكرا", isConfirmationShowing: false), "العفو")
        ETest.eq(RioConversationCommands.quickReply("ريو يعطيك العافية", isConfirmationShowing: false), "الله يعافيك")

        let cases: [(RioActionOutcome, String?)] = [
            (.succeeded("It's 3:40 PM"), "الساعة 3:40 المسا"),
            (.succeeded("It's 9 AM"), "الساعة 9 الصبح"),
            (.succeeded("You're at 64%, charging, about 1 hour to full"), "البطارية 64٪، وتشحن، تتعبى بعد 1 ساعة تقريباً"),
            (.succeeded("You're at 30% on battery, about 2 hours and 5 minutes left"),
             "البطارية 30٪، على البطارية، باقي 2 ساعة و 5 دقايق تقريباً"),
            (.succeeded("You're at 100% and fully charged"), "البطارية 100٪، ومشحونة بالكامل"),
            (.succeeded("4 minutes and 30 seconds left"), "باقي 4 دقايق و 30 ثانية"),
            (.succeeded("Timer set for 5 minutes"), "ضبطت التايمر على 5 دقايق"),
            (.failed("There's no timer running"), "ما في تايمر شغال"),
            (.succeeded("Stopped"), "وقفت"),
            // Anything else keeps Rio's English line.
            (.succeeded("Opened Google Chrome"), nil),
            (.failed("I couldn't find an app called Foo"), nil),
            (.unknown, nil),
        ]
        for (outcome, expected) in cases {
            ETest.eq(RioArabicReplies.line(for: outcome), expected, "\(outcome)")
        }
    }
}
