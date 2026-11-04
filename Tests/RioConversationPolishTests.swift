import Foundation

/// Builder V: conversation mode you can see and hear (its own chime, the spoken line after the
/// silent cancel, the bear's listening and paused-for-a-call poses, the recording badge), quick
/// spoken answers to "Rio, <question>", and the help-sheet phrase fixes. Fakes only: no audio,
/// no AppKit, no LLM.
enum RioConversationPolishTests {
    private typealias Machine = RioCompanionMachine

    @MainActor static func run() async {
        RioFollowUpMemory.shared.clear()
        testCues()
        testChimeSoundsDistinct()
        testPausedForCallIsOnlyACall()
        testBearListensWhileConversationIsOn()
        testBearShowsPausedForACall()
        testListeningYieldsToEverythingElse()
        testRedrawStaysCheapWhileListening()
        testRecordingBadge()
        testRecheckGateLetsQuestionsThrough()
        testGeneralQuestionShape()
        await testQuestionInConversationGoesStraightToTheBrain()
        await testQuestionAboutTheMacKeepsContext()
        testShortAnswerIsSpokenAsItself()
        testHelpSheetPhraseFixes()
        RioFollowUpMemory.shared.clear()
    }

    // MARK: Sound and voice

    private static func testCues() {
        let on = RioConversationCue.cue(for: .announceOn)
        TestSupport.expect(on?.line == "I'm listening", "on says I'm listening")
        TestSupport.expect(on?.chime == .conversationOn, "on has its own chime")
        TestSupport.expect(on?.announcesOn == true, "on announces the on state")
        for reason in [RioConversationCore.OffReason.chord, .menu, .stopListening, .idleTimeout, .settings] {
            let off = RioConversationCue.cue(for: .announceOff(reason))
            TestSupport.expect(off?.line == "Going to sleep", "off says Going to sleep (\(reason))")
            TestSupport.expect(off?.chime == .conversationOff, "off has its own chime (\(reason))")
            TestSupport.expect(off?.announcesOn == false, "off announces the off state")
        }
        // A failed start already played the error sound and shows why; no sleepy line.
        TestSupport.expect(RioConversationCue.cue(for: .announceOff(.unavailable)) == nil, "no cue when it couldn't start")
        // The line waits for the silent cancel of the chord's Fn / Fn + Control session, so it isn't
        // dropped as "Rio is recording".
        TestSupport.expect(RioConversationCue.speechDelay >= 0.25 && RioConversationCue.speechDelay <= 0.5, "about 0.3 s")
        // A line is only said if the mode is still in the state it announces.
        TestSupport.expect(on.map { RioConversationCue.stillApplies($0, isOn: true) } == true, "on, still on")
        TestSupport.expect(on.map { RioConversationCue.stillApplies($0, isOn: false) } == false, "on, but already off again")
    }

    private static func testChimeSoundsDistinct() {
        let on = RioChime.conversationOn.wavData()
        let off = RioChime.conversationOff.wavData()
        for data in [on, off] {
            TestSupport.expect(String(data: data.prefix(4), encoding: .ascii) == "RIFF", "a WAV file")
            TestSupport.expect(String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WAVE", "a WAV file")
            let samples = (data.count - 44) / 2
            let seconds = Double(samples) / Double(RioChime.sampleRate)
            TestSupport.expect(seconds > 0.15 && seconds < 0.6, "a short chime: \(seconds) s")
            let peak = pcm(data).map { abs(Int($0)) }.max() ?? 0
            TestSupport.expect(peak > 2_000 && peak < Int(Int16.max) * 7 / 10, "audible, never harsh: \(peak)")
        }
        TestSupport.expect(on != off, "on and off sound different")
        TestSupport.expect(RioChime.conversationOn.notes.first! < RioChime.conversationOn.notes.last!, "on rises")
        TestSupport.expect(RioChime.conversationOff.notes.first! > RioChime.conversationOff.notes.last!, "off falls")
        // Measured from the samples, not just the note table.
        let onPitches = notePitches(pcm(on), notes: RioChime.conversationOn.notes.count)
        TestSupport.expect(onPitches.first! < onPitches.last!, "on really rises: \(onPitches)")
        let offPitches = notePitches(pcm(off), notes: RioChime.conversationOff.notes.count)
        TestSupport.expect(offPitches.first! > offPitches.last!, "off really falls: \(offPitches)")
    }

    private static func pcm(_ data: Data) -> [Int16] {
        let body = [UInt8](data.subdata(in: 44..<data.count))
        return stride(from: 0, to: body.count - 1, by: 2).map { index in
            Int16(bitPattern: UInt16(body[index]) | UInt16(body[index + 1]) << 8)
        }
    }

    /// Zero crossings per second in the middle of each note's slot: a rough pitch.
    private static func notePitches(_ samples: [Int16], notes: Int) -> [Double] {
        let slot = Int(RioChime.noteDuration * Double(RioChime.sampleRate))
        return (0..<notes).map { index in
            let start = index * slot + slot / 4
            let end = min(samples.count, start + slot / 2)
            var crossings = 0
            for i in (start + 1)..<end where (samples[i - 1] < 0) != (samples[i] < 0) { crossings += 1 }
            return Double(crossings) / 2 / (Double(end - start) / Double(RioChime.sampleRate))
        }
    }

    private static func testPausedForCallIsOnlyACall() {
        let start = Date(timeIntervalSince1970: 1_000)
        var core = RioConversationCore()
        _ = core.turnOn(now: start)
        TestSupport.expect(!core.isPausedForCall, "listening")
        core.setDictationActive(true, now: start)
        TestSupport.expect(core.isPaused && !core.isPausedForCall, "dictating (or Rio talking) is not a call")
        core.setDictationActive(false, now: start)
        core.setOtherAppUsingMic(true, now: start)
        TestSupport.expect(core.isPaused && core.isPausedForCall, "another app has the mic: a call")
        _ = core.turnOff(.menu)
        TestSupport.expect(!core.isPausedForCall, "off is never paused")
    }

    // MARK: The corner bear

    private static func testBearListensWhileConversationIsOn() {
        var machine = Machine()
        machine.conversationChanged(.listening, at: 0)
        TestSupport.expectEqual(machine.mode(at: 1), .conversing)
        // Persistent: long past the 20 s doze-off.
        TestSupport.expectEqual(machine.mode(at: Machine.idleTimeout * 30), .conversing)
        machine.conversationChanged(.off, at: 700)
        TestSupport.expectEqual(machine.mode(at: 701), .resting)
        TestSupport.expectEqual(machine.mode(at: 700 + Machine.idleTimeout + 1), .asleep)
        TestSupport.expectEqual(Machine.Conversation(isOn: true, isPausedForCall: false), .listening)
        TestSupport.expectEqual(Machine.Conversation(isOn: true, isPausedForCall: true), .pausedForCall)
        TestSupport.expectEqual(Machine.Conversation(isOn: false, isPausedForCall: true), .off)
    }

    private static func testBearShowsPausedForACall() {
        var machine = Machine()
        machine.conversationChanged(.pausedForCall, at: 0)
        TestSupport.expectEqual(machine.mode(at: 1), .conversingPaused)
        TestSupport.expectEqual(machine.mode(at: 600), .conversingPaused)
        machine.conversationChanged(.listening, at: 601)
        TestSupport.expectEqual(machine.mode(at: 602), .conversing)
    }

    private static func testListeningYieldsToEverythingElse() {
        var machine = Machine()
        machine.conversationChanged(.listening, at: 0)
        machine.actionPhaseChanged(.listening, at: 1)
        TestSupport.expectEqual(machine.mode(at: 1.1), .alert)
        machine.actionPhaseChanged(.working("Thinking"), at: 2)
        TestSupport.expectEqual(machine.mode(at: 2.1), .thinking)
        machine.actionPhaseChanged(.succeeded("About 384,000 kilometres."), at: 3)
        TestSupport.expectEqual(machine.mode(at: 3.1), .happy)
        machine.actionPhaseChanged(.idle, at: 4)
        machine.speakingChanged(true, at: 4)
        TestSupport.expect(machine.mode(at: 4.1) == .talking, "he talks while answering")
        machine.speakingChanged(false, at: 5)
        TestSupport.expect(machine.mode(at: 5.1) == .conversing, "and goes back to listening")
        machine.voiceChanged(.recording, at: 6)
        TestSupport.expect(machine.mode(at: 6.5) != .conversing, "dictation shows the dictation pose")
        machine.voiceChanged(.none, at: 7)
        machine.helpChanged(true, at: 8)
        TestSupport.expectEqual(machine.mode(at: 8.1), .help)
        machine.helpChanged(false, at: 9)
        machine.timerChanged(remaining: 60, ringing: false, at: 10)
        TestSupport.expect(machine.mode(at: 10.1) == .conversing, "a running timer doesn't hide the listening pose")
        machine.timerChanged(remaining: 0, ringing: true, at: 11)
        TestSupport.expectEqual(machine.mode(at: 11.1), .ringing)
    }

    private static func testRedrawStaysCheapWhileListening() {
        let gate = RioRedrawGate()
        let listening = RioRedrawPolicy.schedule(mode: .conversing, hasTimer: false, hasErrorCard: false, gate: gate)
        TestSupport.expect(listening.redrawsPerSecond <= 10, "listening for minutes stays cheap: \(listening)")
        TestSupport.expect(listening.redrawsPerSecond >= 2, "but the waves still move")
        let paused = RioRedrawPolicy.schedule(mode: .conversingPaused, hasTimer: false, hasErrorCard: false, gate: gate)
        TestSupport.expect(paused.redrawsPerSecond <= 2, "a long call costs almost nothing: \(paused)")
        // Once the on-pose has settled, listening costs about as little as sleeping.
        let settled = RioRedrawPolicy.schedule(
            mode: .conversing, hasTimer: false, hasErrorCard: false, gate: gate,
            secondsSinceLastEvent: RioRedrawPolicy.conversingSettleSeconds + 1
        )
        TestSupport.expectEqual(settled, .periodic(RioRedrawPolicy.sleepyInterval))
        TestSupport.expectEqual(RioRedrawPolicy.housekeepingInterval(schedule: settled, hasPendingExpiry: false), nil)
        let fresh = RioRedrawPolicy.schedule(
            mode: .conversing, hasTimer: false, hasErrorCard: false, gate: gate, secondsSinceLastEvent: 0.5
        )
        TestSupport.expectEqual(fresh, listening)
        // The model passes the machine's own clock: 3 s after an event the pose settles.
        var machine = RioCompanionMachine()
        machine.showMoment(.undone, at: 10)
        TestSupport.expectEqual(machine.secondsSinceLastEvent(at: 14), 4)
        TestSupport.expectEqual(machine.secondsSinceLastEvent(at: 10.5), 0.5)
        var hidden = gate
        hidden.displayAsleep = true
        TestSupport.expectEqual(RioRedrawPolicy.schedule(mode: .conversing, hasTimer: false, hasErrorCard: false, gate: hidden), .paused)
    }

    private static func testRecordingBadge() {
        var machine = Machine()
        TestSupport.expect(!machine.showsRecordingBadge(at: 0), "no badge by default")
        machine.recordingChanged(macro: true, meeting: false, at: 0)
        TestSupport.expect(machine.showsRecordingBadge(at: 1), "recording a macro shows the red dot")
        TestSupport.expect(machine.showsRecordingBadge(at: Machine.idleTimeout * 10), "even while he sleeps")
        machine.trickChanged(isAway: true, at: 2)
        TestSupport.expect(!machine.showsRecordingBadge(at: 3), "nothing in an empty corner")
        machine.trickChanged(isAway: false, at: 4)
        machine.recordingChanged(macro: false, meeting: true, at: 5)
        TestSupport.expect(machine.showsRecordingBadge(at: 6), "the meeting copilot's rolling audio shows it too")
        machine.recordingChanged(macro: false, meeting: false, at: 7)
        TestSupport.expect(!machine.showsRecordingBadge(at: 8), "gone when nothing records")
    }

    // MARK: Questions

    private static func testRecheckGateLetsQuestionsThrough() {
        // English questions and wave 4-5 commands are not re-read by Whisper (that costs up to 3 s).
        for text in [
            "which planet is the biggest", "should I bring an umbrella", "did the Lakers win", "was Einstein German",
            "will it rain tomorrow", "define ephemeral", "answer this", "approve that", "deny that",
            "watch me", "every weekday at 9 open Zoom", "clean up my downloads", "organize my downloads",
            "list my automations", "record a macro", "who's playing tonight", "whose phone is this",
        ] {
            TestSupport.expect(!RioCommandRecheckGate.shouldRecheck(onDeviceText: text), "\"\(text)\" is already English")
        }
        TestSupport.expect(RioCommandRecheckGate.shouldRecheck(onDeviceText: "yalla eftah chrome"), "mangled Arabic is re-read")
        TestSupport.expect(RioCommandRecheckGate.shouldRecheck(onDeviceText: ""), "nothing heard is re-read")
    }

    private static func testGeneralQuestionShape() {
        for text in [
            "how far is the moon", "how far is the moon?", "who was the first president of the United States",
            "what is the capital of France", "what's the speed of light", "why is the sky blue", "when did World War 2 end",
            "which planet is the biggest", "is a tomato a fruit", "how many ounces in a cup", "define ephemeral",
            "tell me how far the moon is", "answer this: how far is the moon",
        ] {
            TestSupport.expect(RioQuestionShape.isGeneralQuestion(text), "\"\(text)\" is a general question")
        }
        for text in [
            "what's up", "what's playing", "what's on my screen", "what is this", "how do I close this window",
            "what time is my meeting", "who sent me that email", "can you open another Chrome window",
            "open another Chrome window", "what does this button do", "where is my resume", "is Spotify playing",
            "how loud is the volume", "what's in this tab", "do the same for Safari", "make it bigger",
        ] {
            TestSupport.expect(!RioQuestionShape.isGeneralQuestion(text), "\"\(text)\" is about the Mac or the owner")
        }
    }

    @MainActor private final class CountingContext: RioSmartContextProviding {
        var calls = 0
        func currentContext() async -> RioSmartContext {
            calls += 1
            return RioSmartContext(
                frontApp: "Google Chrome", frontWindowTitle: "Docs", runningApps: ["Google Chrome"], installedApps: ["Google Chrome"]
            )
        }
    }

    private final class RecordingResolver: RioSmartResolving, @unchecked Sendable {
        var requests: [RioSmartRequest] = []
        let resolution: RioSmartResolution
        init(_ resolution: RioSmartResolution) { self.resolution = resolution }
        func resolve(_ text: String) async throws -> [RioAction] { [] }
        func resolve(_ request: RioSmartRequest) async -> RioSmartResolution {
            requests.append(request)
            return resolution
        }
    }

    @MainActor private final class AnsweringExecutor: RioActionExecuting {
        var executed: [RioAction] = []
        func execute(_ action: RioAction) async -> RioActionResult {
            executed.append(action)
            if case .answer(let text) = action { return .done(summary: text) }
            return .done(summary: "ok")
        }
    }

    /// The real local parser behind the coordinator's protocol (the app target adds the conformance).
    private struct RealParser: RioActionParsing {
        let parser = RioActionParser(installedApps: [])
        func parse(_ transcript: String) -> RioActionParse { parser.parse(transcript) }
        func analyze(_ transcript: String) -> RioParseAnalysis { parser.analyze(transcript) }
    }

    private struct UnknownParser: RioActionParsing {
        func parse(_ transcript: String) -> RioActionParse { .unknown(RioActionTranscript.stripName(from: transcript)) }
    }

    @MainActor private static func testQuestionInConversationGoesStraightToTheBrain() async {
        let answer = "About 384,000 kilometres away."
        let context = CountingContext()
        let resolver = RecordingResolver(.actions([.answer(answer)]))
        let executor = AnsweringExecutor()
        let coordinator = RioActionCoordinator(
            parser: RealParser(), executor: executor, smartResolver: resolver,
            smartContext: context, isTrustingConversation: { true }
        )
        let outcome = await coordinator.run("Rio, how far is the moon", source: .conversation)
        TestSupport.expectEqual(resolver.requests.map(\.command), ["how far is the moon"])
        TestSupport.expect(context.calls == 0, "no Accessibility walk for a general question")
        let sent = resolver.requests.first?.context
        TestSupport.expect(
            sent?.frontApp == nil && sent?.frontWindowTitle == nil && sent?.installedApps.isEmpty == true
                && sent?.runningApps.isEmpty == true,
            "a general question goes out without the Mac's context (smaller and faster)"
        )
        TestSupport.expectEqual(executor.executed, [.answer(answer)])
        TestSupport.expectEqual(outcome, .succeeded(answer))
        // The previous command still rides along, so "and how far is Mars" can follow it.
        _ = await coordinator.run("Rio, and how far is Mars from the sun", source: .conversation)
        TestSupport.expect(resolver.requests.last?.context.previousCommand == "how far is the moon", "previous command kept")
    }

    @MainActor private static func testQuestionAboutTheMacKeepsContext() async {
        let context = CountingContext()
        let resolver = RecordingResolver(.actions([.answer("It's a Google Doc.")]))
        let coordinator = RioActionCoordinator(
            parser: UnknownParser(), executor: AnsweringExecutor(), smartResolver: resolver,
            smartContext: context, isTrustingConversation: { true }
        )
        _ = await coordinator.run("Rio, what is this window", source: .conversation)
        TestSupport.expect(context.calls == 1, "the Mac's context is gathered")
        TestSupport.expect(resolver.requests.first?.context.frontApp == "Google Chrome", "and sent")
    }

    private static func testShortAnswerIsSpokenAsItself() {
        // The undo journal registers an answer's text; the outcome is then said as itself, with no
        // "Done!" in front, however short.
        for answer in ["Paris.", "About 384,000 kilometres away."] {
            var state = RioPersonalityState()
            state.verbatim = [answer]
            let line = RioPersonality.line(for: .succeeded(answer), hour: 15, day: 1, seed: 42, state: &state)
            TestSupport.expect(line == RioSpeechText.prepare(answer), "\"\(answer)\" is spoken as itself, got \(line ?? "nil")")
        }
    }

    // MARK: Phrase fixes found while checking the help sheet

    private static func testHelpSheetPhraseFixes() {
        let parser = RioActionParser(installedApps: [])
        func parsed(_ text: String) -> RioActionParse { parser.parse(text) }
        TestSupport.expectEqual(parsed("search my history for the budget"), .actions([.searchHistory(query: "the budget")]))
        TestSupport.expectEqual(parsed("search my dictations for the lease"), .actions([.searchHistory(query: "the lease")]))
        TestSupport.expectEqual(parsed("search for my history homework"), .actions([.webSearch(query: "my history homework")]))
        for text in [
            "copy the text from this image", "copy the text from this PDF", "grab the text from the video",
            "copy the text from this picture to my clipboard",
        ] {
            TestSupport.expectEqual(parsed(text), .actions([.copyTextFromScreen]))
        }
        TestSupport.expectEqual(
            parsed("add call Ali to my Hala roadmap in Notion"), .actions([.notionAdd(text: "call Ali", page: "Hala roadmap")])
        )
        TestSupport.expectEqual(
            parsed("add call Ali to the Hala roadmap page in Notion"), .actions([.notionAdd(text: "call Ali", page: "Hala roadmap")])
        )
        TestSupport.expectEqual(parsed("add buy milk to Notion"), .actions([.notionAdd(text: "buy milk", page: nil)]))
        TestSupport.expectEqual(parsed("add milk to my notion"), .actions([.notionAdd(text: "milk", page: nil)]))
    }
}
