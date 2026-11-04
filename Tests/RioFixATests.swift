import Foundation

/// Fixer A: the Fn double-tap, the Fn + Control + Option chord, the hallucination guard, the
/// command prompt, history privacy, conversation trust and the confirmation key policy.
enum RioFixATests {
    static func run() {
        testFnHold()
        testDoubleTapStartsAndStopsHandsFree()
        testDoubleTapStopTapDoesNotRestart()
        testDoubleTapFirstTapEndsSilently()
        testChordDuringHandsFreeKeepsRecording()
        testTapThenHoldTiming()
        testFnControlStillEngagesActionKey()
        testChordInEveryKeyOrder()
        testRightSideKeysNeverFormTheChord()
        testChordCancelsAHoldSilently()
        testLoneRightCommandFixLast()
        testToggleMigration()
        testHallucinationGuard()
        testCommandPromptFitsBudget()
        testHistoryPolicy()
        testConfirmationKeyPolicy()
        testConversationCommands()
        testUnknownMessage()
    }

    @MainActor static func runAsync() async {
        await testConversationTrust()
    }

    // MARK: Shortcut helpers

    private static let config = ShortcutConfiguration(
        hold: .defaultHold,
        toggle: .defaultToggle,
        fixLast: .defaultFixLast,
        holdActionModifiers: [.control],
        conversationChordEnabled: true
    )

    private struct Rig {
        var state = ShortcutInputState()
        var controller: DictationShortcutSessionController = {
            let controller = DictationShortcutSessionController()
            controller.discardsShortHoldTaps = DictationShortcutSessionController.shortHoldTapsMayStartDoubleTap(
                hold: config.hold, toggle: config.toggle
            )
            return controller
        }()
        var events: [ShortcutEvent] = []
        var actions: [DictationShortcutAction] = []
        /// Like AppState: a normal stop leaves a transcription running until `finishTranscribing`.
        var isTranscribing = false

        mutating func modifier(_ keyCode: UInt16, down: Bool, at time: TimeInterval) {
            let result = ShortcutMatcher.reduce(
                state: state,
                event: .modifierChanged(keyCode: keyCode, isDown: down),
                configuration: config,
                now: time
            )
            state = result.state
            events.append(contentsOf: result.emittedEvents)
            for event in result.emittedEvents {
                guard let action = controller.handle(event: event, isTranscribing: isTranscribing, now: time) else { continue }
                actions.append(action)
                if action == .stop { isTranscribing = true }
            }
        }

        mutating func take() -> [ShortcutEvent] {
            defer { events = [] }
            return events
        }

        mutating func takeActions() -> [DictationShortcutAction] {
            defer { actions = [] }
            return actions
        }
    }

    // MARK: Fn

    private static func testFnHold() {
        var rig = Rig()
        rig.modifier(63, down: true, at: 0)
        TestSupport.expectEqual(rig.take(), [.holdActivated])
        rig.modifier(63, down: false, at: 1.5)
        TestSupport.expectEqual(rig.take(), [.holdDeactivated])
        TestSupport.expectEqual(rig.takeActions(), [.start(.hold), .stop])
    }

    private static func testDoubleTapStartsAndStopsHandsFree() {
        var rig = Rig()
        rig.modifier(63, down: true, at: 0)
        rig.modifier(63, down: false, at: 0.1)
        _ = rig.take()
        _ = rig.takeActions()
        // Second press inside the gap: the toggle, never a second hold.
        rig.modifier(63, down: true, at: 0.25)
        TestSupport.expectEqual(rig.take(), [.toggleActivated])
        TestSupport.expectEqual(rig.takeActions(), [.start(.toggle)])
        rig.modifier(63, down: false, at: 0.35)
        TestSupport.expectEqual(rig.take(), [.toggleDeactivated])
        // Much later, one Fn press stops it (on release, so the chord can still claim the press).
        rig.modifier(63, down: true, at: 5)
        TestSupport.expectEqual(rig.takeActions(), [])
        rig.modifier(63, down: false, at: 5.05)
        TestSupport.expectEqual(rig.takeActions(), [.stop])
    }

    private static func testDoubleTapStopTapDoesNotRestart() {
        var rig = Rig()
        rig.modifier(63, down: true, at: 0)
        rig.modifier(63, down: false, at: 0.1)
        rig.modifier(63, down: true, at: 0.2)
        rig.modifier(63, down: false, at: 0.3)
        _ = rig.takeActions()
        // Double-tap to stop: the first press stops, the second must not start a new session.
        rig.modifier(63, down: true, at: 3)
        rig.modifier(63, down: false, at: 3.1)
        rig.modifier(63, down: true, at: 3.2)
        rig.modifier(63, down: false, at: 3.3)
        TestSupport.expectEqual(rig.takeActions(), [.stop])
        TestSupport.expect(rig.controller.activeMode == nil, "no session after the stop double-tap")
    }

    /// The first tap of a double-tap must not start a transcription (Pop, a shrug, and
    /// `isTranscribing` blocking the second press while the microphone shuts down).
    private static func testDoubleTapFirstTapEndsSilently() {
        var rig = Rig()
        rig.modifier(63, down: true, at: 0)
        rig.modifier(63, down: false, at: 0.12)
        TestSupport.expectEqual(rig.takeActions(), [.start(.hold), .cancelSilently])
        TestSupport.expect(!rig.isTranscribing, "a tap never starts a transcription")
        rig.modifier(63, down: true, at: 0.3)
        TestSupport.expectEqual(rig.takeActions(), [.start(.toggle)])

        // Even if a transcription were still finishing, a plain hold is unaffected.
        var hold = Rig()
        hold.modifier(63, down: true, at: 0)
        hold.modifier(63, down: false, at: 1.2)
        TestSupport.expectEqual(hold.takeActions(), [.start(.hold), .stop])

        // With a different toggle key, a short Fn hold still ends normally.
        let other = DictationShortcutSessionController()
        other.discardsShortHoldTaps = DictationShortcutSessionController.shortHoldTapsMayStartDoubleTap(
            hold: .defaultHold, toggle: ShortcutPreset.f5.binding
        )
        TestSupport.expectEqual(other.handle(event: .holdActivated, isTranscribing: false, now: 0), .start(.hold))
        TestSupport.expectEqual(other.handle(event: .holdDeactivated, isTranscribing: false, now: 0.1), .stop)
    }

    /// Fn first in the chord during a hands-free session: the Fn press must not stop (and paste)
    /// the session before Control and Option arrive.
    private static func testChordDuringHandsFreeKeepsRecording() {
        var rig = Rig()
        rig.modifier(63, down: true, at: 0)
        rig.modifier(63, down: false, at: 0.1)
        rig.modifier(63, down: true, at: 0.25)
        rig.modifier(63, down: false, at: 0.35)
        _ = rig.takeActions()
        rig.modifier(63, down: true, at: 5)
        rig.modifier(59, down: true, at: 5.05)
        rig.modifier(58, down: true, at: 5.1)
        TestSupport.expect(!rig.takeActions().contains(.stop), "the chord never stops a hands-free session")
        rig.modifier(58, down: false, at: 5.3)
        rig.modifier(59, down: false, at: 5.35)
        rig.modifier(63, down: false, at: 5.4)
        TestSupport.expect(!rig.takeActions().contains(.stop), "nor does letting go of it")
        TestSupport.expectEqual(rig.controller.activeMode, .toggle)
        // A plain Fn press still stops it, on release.
        rig.modifier(63, down: true, at: 8)
        TestSupport.expectEqual(rig.takeActions(), [])
        rig.modifier(63, down: false, at: 8.1)
        TestSupport.expectEqual(rig.takeActions(), [.stop])
    }

    private static func testTapThenHoldTiming() {
        // A long first press is a hold, not a tap: the next press is a plain hold.
        var rig = Rig()
        rig.modifier(63, down: true, at: 0)
        rig.modifier(63, down: false, at: 0.5)
        rig.modifier(63, down: true, at: 0.6)
        TestSupport.expectEqual(rig.take(), [.holdActivated, .holdDeactivated, .holdActivated])
        rig.modifier(63, down: false, at: 2)

        // A short tap followed by a press after the gap is a plain hold too.
        var late = Rig()
        late.modifier(63, down: true, at: 0)
        late.modifier(63, down: false, at: 0.1)
        late.modifier(63, down: true, at: 0.1 + ShortcutTiming.doubleTapGap + 0.05)
        TestSupport.expect(!late.take().contains(.toggleActivated), "a late second press is not a double-tap")

        // Tap, then press-and-hold inside the gap: still the toggle (it fires on the press).
        var held = Rig()
        held.modifier(63, down: true, at: 0)
        held.modifier(63, down: false, at: 0.1)
        held.modifier(63, down: true, at: 0.3)
        TestSupport.expect(held.take().contains(.toggleActivated), "tap then hold inside the gap toggles")
        TestSupport.expectEqual(held.controller.activeMode, .toggle)
    }

    private static func testFnControlStillEngagesActionKey() {
        var fnFirst = Rig()
        fnFirst.modifier(63, down: true, at: 0)
        fnFirst.modifier(59, down: true, at: 0.2)
        TestSupport.expectEqual(fnFirst.take(), [.holdActivated, .holdActionModifierEngaged])
        fnFirst.modifier(59, down: false, at: 1)
        fnFirst.modifier(63, down: false, at: 1.1)

        var controlFirst = Rig()
        controlFirst.modifier(59, down: true, at: 0)
        controlFirst.modifier(63, down: true, at: 0.2)
        TestSupport.expect(controlFirst.take().contains(.holdActionModifierEngaged), "Control then Fn engages too")
    }

    // MARK: Chord

    private static func testChordInEveryKeyOrder() {
        let orders: [[UInt16]] = [
            [63, 59, 58], [63, 58, 59], [59, 63, 58], [59, 58, 63], [58, 63, 59], [58, 59, 63]
        ]
        for order in orders {
            var rig = Rig()
            var time = 0.0
            for key in order {
                rig.modifier(key, down: true, at: time)
                time += 0.05
            }
            TestSupport.expectEqual(rig.events.filter { $0 == .conversationChord }.count, 1, line: #line)
            TestSupport.expect(rig.controller.activeMode == nil, "chord \(order) leaves no dictation session")
            // Releasing one key at a time never restarts a hold or an action session.
            _ = rig.take()
            for key in order {
                rig.modifier(key, down: false, at: time)
                time += 0.05
            }
            TestSupport.expect(
                !rig.events.contains(.holdActivated) && !rig.events.contains(.holdActionModifierEngaged),
                "releasing chord \(order) must not start anything"
            )
            // A second press fires again.
            for key in order { rig.modifier(key, down: true, at: time); time += 0.05 }
            TestSupport.expectEqual(rig.events.filter { $0 == .conversationChord }.count, 1, line: #line)
        }
    }

    private static func testRightSideKeysNeverFormTheChord() {
        for keys: [UInt16] in [[63, 62, 61], [63, 59, 61], [63, 62, 58], [62, 61]] {
            var rig = Rig()
            for key in keys { rig.modifier(key, down: true, at: 0) }
            TestSupport.expect(!rig.events.contains(.conversationChord), "\(keys) is not the chord")
        }
    }

    private static func testChordCancelsAHoldSilently() {
        var rig = Rig()
        rig.modifier(63, down: true, at: 0)
        rig.modifier(59, down: true, at: 0.1)
        _ = rig.takeActions()
        rig.modifier(58, down: true, at: 0.2)
        let actions = rig.takeActions()
        TestSupport.expectEqual(actions, [.cancelSilently])
        TestSupport.expect(rig.controller.activeMode == nil, "the hold is gone")
        TestSupport.expect(!actions.contains(.stop), "a chord never ends as a normal stop (no paste)")
    }

    private static func testLoneRightCommandFixLast() {
        var rig = Rig()
        rig.modifier(54, down: true, at: 0)
        rig.modifier(54, down: false, at: 0.1)
        TestSupport.expectEqual(rig.take(), [.fixLastTriggered])
        // Right Command during an Fn hold is a chord, not Fix Last.
        var chorded = Rig()
        chorded.modifier(63, down: true, at: 0)
        chorded.modifier(54, down: true, at: 0.1)
        chorded.modifier(54, down: false, at: 0.2)
        TestSupport.expect(!chorded.events.contains(.fixLastTriggered), "Right Command inside an Fn hold is not Fix Last")
    }

    private static func testToggleMigration() {
        let migrated = ShortcutPreset.rightOption.binding.migratedToggleShortcut()
        TestSupport.expectEqual(migrated, ShortcutBinding.defaultToggle)
        TestSupport.expectEqual(migrated.displayName, "Double-tap Fn")
        TestSupport.expectEqual(ShortcutBinding.defaultToggle.tapPhrase, "double-tap Fn")
        let custom = ShortcutPreset.f5.binding
        TestSupport.expectEqual(custom.migratedToggleShortcut(), custom)
        let data = try? JSONEncoder().encode(ShortcutBinding.defaultToggle)
        let decoded = data.flatMap { try? JSONDecoder().decode(ShortcutBinding.self, from: $0) }
        TestSupport.expectEqual(decoded, ShortcutBinding.defaultToggle)
    }

    // MARK: Hallucinations

    private static func testHallucinationGuard() {
        let quiet = WhisperHallucinationGuard.SpeechEvidence(recordedSeconds: 4, heardSpeechSeconds: 0.2)
        let bad = [
            "Thanks for watching!", "Thank you for watching.", "We are hoping for a win.",
            "MBC 뉴스 이덕영입니다.", "Subtitles by the Amara.org community", "Please subscribe to my channel",
            "[Music]", "Captions by John", "Thanks for watching, everyone"
        ]
        for text in bad {
            TestSupport.expect(WhisperHallucinationGuard.isHallucination(text), "should reject: \(text)")
            TestSupport.expect(WhisperHallucinationGuard.isHallucination(text, evidence: quiet), "quiet audio, should reject: \(text)")
        }
        let good = [
            "Open Chrome", "Thank you", "you", "", "Remind me to subscribe to the newsletter after the meeting ends today because I keep forgetting about it entirely",
            "Rio open Spotify", "set a timer for five minutes",
            // Real dictations that merely contain a listed phrase.
            "The book was translated by my professor.",
            "Thank you for listening, I'll send the notes tonight.",
            "Thank you for watching the kids yesterday.",
            "Captions by the design team are due Friday."
        ]
        for text in good {
            TestSupport.expect(!WhisperHallucinationGuard.isHallucination(text), "should keep: \(text)")
            TestSupport.expect(!WhisperHallucinationGuard.isHallucination(text, evidence: quiet), "quiet audio, should keep: \(text)")
        }
        // A recording full of speech is never second-guessed, whatever Whisper wrote.
        let spoken = WhisperHallucinationGuard.SpeechEvidence(recordedSeconds: 3, heardSpeechSeconds: 2.2)
        TestSupport.expect(!WhisperHallucinationGuard.isHallucination("Thanks for watching!", evidence: spoken), "said out loud, it is kept")
        // Speech that is a small share of a long recording (a TV in the room) still counts as quiet.
        let background = WhisperHallucinationGuard.SpeechEvidence(recordedSeconds: 30, heardSpeechSeconds: 3)
        TestSupport.expect(WhisperHallucinationGuard.isHallucination("Thanks for watching!", evidence: background), "background noise")
    }

    private static func testCommandPromptFitsBudget() {
        let apps = (0..<300).map { "Application Number \($0)" }
        let terms = RioCommandPrompt.terms(runningAppNames: ["Google Chrome", "Safari"], installedAppNames: apps)
        let prompt = TranscriptionRequestCore.vocabularyPrompt(terms: terms) ?? ""
        TestSupport.expect(prompt.contains("open"), "command verbs lead the prompt")
        TestSupport.expect(prompt.contains("Google Chrome"), "running apps are in the prompt")
        TestSupport.expect(
            TranscriptionRequestCore.estimatedTokens(prompt) <= TranscriptionRequestCore.promptTokenBudget,
            "prompt stays within the token budget"
        )
    }

    // MARK: History

    private static func testHistoryPolicy() {
        let read = RioHistoryPolicy.entry(
            transcript: "read my last message", actions: [.readAloud(.lastMessage)],
            outcomeText: "Ali says dinner at 8", didSucceed: true
        )
        TestSupport.expectEqual(read.outcome, "Read your last message")
        let memory = RioHistoryPolicy.entry(
            transcript: "remember my locker code is 4417", actions: [.remember(fact: "locker code 4417")],
            outcomeText: "Got it: locker code 4417", didSucceed: true
        )
        TestSupport.expectEqual(memory.transcript, RioHistoryPolicy.redactedTranscript)
        TestSupport.expectEqual(memory.outcome, "Saved a memory")
        let clip = RioHistoryPolicy.entry(
            transcript: "what's on my clipboard", actions: [.clipboard(.readCurrent)],
            outcomeText: "secret", didSucceed: false
        )
        TestSupport.expectEqual(clip.outcome, "Used the clipboard (didn't work)")
        let screen = RioHistoryPolicy.entry(
            transcript: "what's on my screen", actions: [.describeScreen(question: nil)],
            outcomeText: RioVisionMessages.needsScreenRecording, didSucceed: false
        )
        TestSupport.expectEqual(screen.outcome, RioHistoryPolicy.screenPermissionFailure)
        let screenOther = RioHistoryPolicy.entry(
            transcript: "what's on my screen", actions: [.describeScreen(question: nil)],
            outcomeText: "The screen says something private", didSucceed: false
        )
        TestSupport.expectEqual(screenOther.outcome, "Couldn't look at your screen")
        TestSupport.expectEqual(clip.transcript, RioHistoryPolicy.redactedTranscript)
        let plain = RioHistoryPolicy.entry(
            transcript: "open chrome", actions: [.openApp(name: "Google Chrome")],
            outcomeText: "Opened Google Chrome", didSucceed: true
        )
        TestSupport.expectEqual(plain.outcome, "Opened Google Chrome")
        TestSupport.expectEqual(plain.transcript, "open chrome")
        for action in [RioAction.describeScreen(question: nil), .startTranslation, .runTask(goal: "x"), .speakLastTranslation] {
            TestSupport.expect(RioHistoryPolicy.sensitiveLabel(for: action) != nil, "\(action) has a fixed label")
        }
    }

    // MARK: Confirmation keys

    private static func testConfirmationKeyPolicy() {
        func accepts(_ key: UInt16, pid: Int64 = 1, panelAge: TimeInterval = 5, sinceOwnPost: TimeInterval = 60) -> Bool {
            RioConfirmationKeyPolicy.accepts(
                keyCode: key, eventSourcePID: pid, ownPID: 99,
                secondsSincePanelShown: panelAge, secondsSinceOwnSyntheticPost: sinceOwnPost
            )
        }
        TestSupport.expect(accepts(36), "a real Return confirms")
        TestSupport.expect(accepts(53), "a real Escape cancels")
        TestSupport.expect(!accepts(36, pid: 99), "a Return Rio posted himself is ignored")
        TestSupport.expect(!accepts(36, sinceOwnPost: 0.1), "a Return right after Rio posted keys is ignored")
        TestSupport.expect(!accepts(36, panelAge: 0.1), "Return in the first 300 ms is ignored")
        TestSupport.expect(accepts(53, panelAge: 0.1), "Escape is allowed immediately")
        TestSupport.expect(!accepts(12), "other keys do nothing")
    }

    // MARK: Conversation commands

    private static func testConversationCommands() {
        for text in ["Rio, stop", "stop", "Stop it.", "rio cancel that"] {
            TestSupport.expect(RioConversationCommands.isBareStop(text), "bare stop: \(text)")
        }
        for text in ["stop the timer", "stop music", "open chrome", "stop listening"] {
            TestSupport.expect(!RioConversationCommands.isBareStop(text), "not a bare stop: \(text)")
        }
        // A spoken yes never approves; only a spoken no can decline.
        for text in ["Rio, yes", "yes", "yeah", "do it", "confirm", "go ahead"] {
            TestSupport.expect(!RioConversationCommands.declinesBySpeech(text), "\(text) must not decline")
        }
        for text in ["Rio, no", "cancel", "never mind"] {
            TestSupport.expect(RioConversationCommands.declinesBySpeech(text), "\(text) declines")
        }
    }

    private static func testUnknownMessage() {
        TestSupport.expectEqual(
            RioActionText.unknownMessage(heard: "We are hoping for a win."),
            "I heard \"We are hoping for a win.\". Try again?"
        )
        TestSupport.expectEqual(RioActionText.unknownMessage(heard: "  "), RioActionText.unknownMessage)
    }

    // MARK: Coordinator: source and trust

    private struct FixedParser: RioActionParsing {
        let result: RioActionParse
        func parse(_ transcript: String) -> RioActionParse { result }
    }

    @MainActor private final class CountingExecutor: RioActionExecuting {
        var executed: [RioAction] = []
        func execute(_ action: RioAction) async -> RioActionResult {
            executed.append(action)
            return .done(summary: "ok")
        }
    }

    @MainActor private final class FakeConfirmer: RioConfirming, RioConversationConfirming {
        var answer: Bool
        var plainAsked: [RioAction] = []
        var conversationAsked: [RioAction] = []
        init(answer: Bool) { self.answer = answer }
        func confirm(_ action: RioAction) async -> Bool { plainAsked.append(action); return answer }
        func confirmConversationAction(_ action: RioAction) async -> Bool { conversationAsked.append(action); return answer }
    }

    @MainActor private static func makeCoordinator(
        action: RioAction, trusting: Bool, confirmer: RioConfirming?
    ) -> (RioActionCoordinator, CountingExecutor) {
        let executor = CountingExecutor()
        let coordinator = RioActionCoordinator(
            parser: FixedParser(result: .actions([action])),
            executor: executor,
            confirmer: confirmer,
            isTrustingConversation: { trusting }
        )
        return (coordinator, executor)
    }

    @MainActor private static func testConversationTrust() async {
        let typing = RioAction.typeText("hello")

        // Trusted (the default): conversation runs like the action key, no question.
        let trusted = makeCoordinator(action: typing, trusting: true, confirmer: nil)
        let r1 = await trusted.0.run("rio type hello", source: .conversation)
        TestSupport.expectEqual(r1, .succeeded("ok"))

        // Untrusted: conversation needs the confirmer, and a no stops it.
        let no = FakeConfirmer(answer: false)
        let untrusted = makeCoordinator(action: typing, trusting: false, confirmer: no)
        let r2 = await untrusted.0.run("rio type hello", source: .conversation)
        TestSupport.expectEqual(r2, .cancelled)
        TestSupport.expectEqual(untrusted.1.executed.count, 0)
        TestSupport.expectEqual(no.conversationAsked, [typing])

        // Untrusted with no confirmer at all: never runs.
        let nobody = makeCoordinator(action: typing, trusting: false, confirmer: nil)
        let r3 = await nobody.0.run("rio type hello", source: .conversation)
        TestSupport.expectEqual(r3, .cancelled)

        // Approved by Return/click: runs.
        let yes = FakeConfirmer(answer: true)
        let approved = makeCoordinator(action: typing, trusting: false, confirmer: yes)
        let r4 = await approved.0.run("rio type hello", source: .conversation)
        TestSupport.expectEqual(r4, .succeeded("ok"))

        // The action key is unaffected by the setting.
        let key = makeCoordinator(action: typing, trusting: false, confirmer: nil)
        let r5 = await key.0.run("rio type hello", source: .actionKey)
        TestSupport.expectEqual(r5, .succeeded("ok"))

        // Harmless actions never ask.
        let open = makeCoordinator(action: .openApp(name: "Notes"), trusting: false, confirmer: nil)
        let r6 = await open.0.run("rio open notes", source: .conversation)
        TestSupport.expectEqual(r6, .succeeded("ok"))

        // Translator start from conversation always asks, trusted or not; the action key does not.
        let askTrusted = FakeConfirmer(answer: false)
        let translate = makeCoordinator(action: .startTranslation, trusting: true, confirmer: askTrusted)
        let r7 = await translate.0.run("rio translate", source: .conversation)
        TestSupport.expectEqual(r7, .cancelled)
        TestSupport.expectEqual(askTrusted.conversationAsked, [.startTranslation])
        let viaKey = makeCoordinator(action: .startTranslation, trusting: true, confirmer: nil)
        let r8 = await viaKey.0.run("rio translate", source: .actionKey)
        TestSupport.expectEqual(r8, .succeeded("ok"))

        // Every untrusted-gated action is covered.
        let gated: [RioAction] = [
            .typeText("x"), .pressKeys(KeyCombo(key: "a", command: true, shift: false, option: false, control: false)),
            .fillField(label: "a", text: "b"), .click(label: "ok", ordinal: nil), .runTask(goal: "x"),
            .systemToggle(.wifi, isOn: true), .quitApp(name: "Notes"), .clipboard(.pasteRecent(matching: nil))
        ]
        for action in gated {
            TestSupport.expect(action.conversationNeedsConfirmationWhenUntrusted, "\(action) is gated")
        }
        TestSupport.expect(!RioAction.clipboard(.readCurrent).conversationNeedsConfirmationWhenUntrusted, "reading is not gated")

        // The unrecognized text is kept for "I heard ...".
        let coordinator = RioActionCoordinator(
            parser: FixedParser(result: .unknown("we are hoping for a win")), executor: CountingExecutor()
        )
        let r9 = await coordinator.run("rio we are hoping for a win")
        TestSupport.expectEqual(r9, .unknown)
        TestSupport.expectEqual(coordinator.lastUnrecognized, "we are hoping for a win")
    }
}
