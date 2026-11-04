import Foundation

/// Meeting copilot (ring buffer, mixing, auto-stop rules, phrases) and Claude Code by voice
/// (screen detection, permission prompts, session choice), all from synthetic data.
enum RioMeetingTests {
    static func run() {
        testRingBasics()
        testRingWraparound()
        testRingLastSeconds()
        testMix()
        testSilence()
        testResample()
        testAutoStopMaxDuration()
        testAutoStopCallEnded()
        testAutoStopUnknownMic()
        testMeetingPhrases()
        testClaudePhrases()
        testPhrasesDontSteal()
        testLooksLikeClaudeCode()
        testPromptBoxedBash()
        testPromptEditNoBox()
        testPromptTwoOptions()
        testPromptYesNo()
        testPromptCursorOnSecond()
        testPromptPlan()
        testPromptOnlyPersistentYes()
        testPromptStale()
        testNoPrompt()
        testPicker()
        testSendSanitising()
        testPromptTextForConfirmation()
        testMeetingPrompts()
    }

    // MARK: Audio ring

    private static func pcm(_ values: [Int16]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func samples(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    private static func testRingBasics() {
        var ring = RioAudioRing(capacitySeconds: 1, sampleRate: 10)
        TestSupport.expectEqual(ring.sampleCount, 0)
        TestSupport.expect(ring.last(seconds: 1).isEmpty, "empty ring gives no audio")
        ring.append(pcm([1, 2, 3]))
        TestSupport.expectEqual(ring.sampleCount, 3)
        TestSupport.expectEqual(samples(ring.last(seconds: 1)), [1, 2, 3])
        ring.reset()
        TestSupport.expectEqual(ring.sampleCount, 0)
    }

    private static func testRingWraparound() {
        var ring = RioAudioRing(capacitySeconds: 1, sampleRate: 4) // 4 samples
        ring.append(pcm([1, 2, 3]))
        ring.append(pcm([4, 5, 6]))
        TestSupport.expectEqual(ring.sampleCount, 4)
        TestSupport.expectEqual(samples(ring.last(seconds: 1)), [3, 4, 5, 6])
        // A slice longer than the whole ring keeps only its tail.
        ring.append(pcm([10, 11, 12, 13, 14, 15, 16]))
        TestSupport.expectEqual(samples(ring.last(seconds: 1)), [13, 14, 15, 16])
        ring.append(pcm([17]))
        TestSupport.expectEqual(samples(ring.last(seconds: 1)), [14, 15, 16, 17])
        // An odd trailing byte is ignored, never half a sample.
        var odd = pcm([20])
        odd.append(0x7F)
        ring.append(odd)
        TestSupport.expectEqual(samples(ring.last(seconds: 1)), [15, 16, 17, 20])
    }

    private static func testRingLastSeconds() {
        var ring = RioAudioRing(capacitySeconds: 3, sampleRate: 2) // 6 samples
        ring.append(pcm([1, 2, 3, 4, 5]))
        TestSupport.expectEqual(samples(ring.last(seconds: 1)), [4, 5])
        TestSupport.expectEqual(samples(ring.last(seconds: 2)), [2, 3, 4, 5])
        TestSupport.expectEqual(samples(ring.last(seconds: 60)), [1, 2, 3, 4, 5])
        TestSupport.expect(ring.last(seconds: 0).isEmpty, "zero seconds is empty")
        TestSupport.expect(abs(ring.seconds - 2.5) < 0.0001, "seconds held")
        ring.append(pcm([6, 7, 8]))
        TestSupport.expectEqual(samples(ring.last(seconds: 1.5)), [6, 7, 8])
        TestSupport.expectEqual(samples(ring.last(seconds: 3)), [3, 4, 5, 6, 7, 8])
        // Real size: five minutes at 16 kHz.
        var real = RioAudioRing(capacitySeconds: 300)
        real.append(Data(count: 16_000 * 2 * 400))
        TestSupport.expectEqual(real.sampleCount, 16_000 * 300)
    }

    private static func testMix() {
        TestSupport.expectEqual(samples(RioAudioMix.mix(pcm([1, 2, 3]), pcm([10, 20, 30]))), [11, 22, 33])
        // Different lengths are aligned at the end (both streams end "now").
        TestSupport.expectEqual(samples(RioAudioMix.mix(pcm([5]), pcm([1, 2, 3]))), [1, 2, 8])
        TestSupport.expectEqual(samples(RioAudioMix.mix(Data(), pcm([1, 2]))), [1, 2])
        TestSupport.expectEqual(samples(RioAudioMix.mix(pcm([30_000]), pcm([30_000]))), [Int16.max])
        TestSupport.expectEqual(samples(RioAudioMix.mix(pcm([-30_000]), pcm([-30_000]))), [Int16.min])
    }

    private static func testSilence() {
        TestSupport.expect(RioAudioLevel.isSilent(Data()), "empty is silent")
        TestSupport.expect(RioAudioLevel.isSilent(pcm([Int16](repeating: 3, count: 1000))), "near zero is silent")
        let loud = (0..<1000).map { Int16($0 % 2 == 0 ? 8_000 : -8_000) }
        TestSupport.expect(!RioAudioLevel.isSilent(pcm(loud)), "speech level is not silent")
    }

    private static func testResample() {
        let same = RioPCMConvert.resample([0.1, 0.2, 0.3], from: 16_000, to: 16_000)
        TestSupport.expectEqual(same, [0.1, 0.2, 0.3])
        let down = RioPCMConvert.resample([Float](repeating: 0.5, count: 480), from: 48_000, to: 16_000)
        TestSupport.expectEqual(down.count, 160)
        TestSupport.expect(down.allSatisfy { abs($0 - 0.5) < 0.0001 }, "constant stays constant")
        TestSupport.expectEqual(RioPCMConvert.int16([1.5, -1.5, 0, 0.5]), [Int16.max, -Int16.max, 0, 16_383])
        let mono = RioPCMConvert.downmix([[1, 0], [0, 1]])
        TestSupport.expectEqual(mono, [0.5, 0.5])
    }

    // MARK: Auto-stop

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func testAutoStopMaxDuration() {
        var rule = RioMeetingAutoStop(start: t0)
        TestSupport.expect(rule.tick(now: t0.addingTimeInterval(60), micInUse: true) == nil, "running")
        TestSupport.expect(rule.tick(now: t0.addingTimeInterval(7_199), micInUse: true) == nil, "just under 2 h")
        TestSupport.expectEqual(rule.tick(now: t0.addingTimeInterval(7_200), micInUse: true), .tooLong)
        for reason in [RioMeetingStopReason.callEnded, .tooLong, .captureStopped] {
            TestSupport.expect(reason.spokenLine.contains("wiped"), "auto-stop line says the audio is gone: \(reason)")
        }
    }

    private static func testAutoStopCallEnded() {
        var rule = RioMeetingAutoStop(start: t0)
        TestSupport.expect(rule.tick(now: t0.addingTimeInterval(30), micInUse: true) == nil, "call going")
        TestSupport.expect(rule.tick(now: t0.addingTimeInterval(100), micInUse: false) == nil, "just quiet")
        TestSupport.expect(rule.tick(now: t0.addingTimeInterval(129), micInUse: false) == nil, "99 s quiet")
        // A blip of mic use restarts the 2-minute clock.
        TestSupport.expect(rule.tick(now: t0.addingTimeInterval(140), micInUse: true) == nil, "blip")
        TestSupport.expect(rule.tick(now: t0.addingTimeInterval(259), micInUse: false) == nil, "119 s after the blip")
        TestSupport.expectEqual(rule.tick(now: t0.addingTimeInterval(260), micInUse: false), .callEnded)
        // Never a call at all: stops two minutes after start.
        var idle = RioMeetingAutoStop(start: t0)
        TestSupport.expect(idle.tick(now: t0.addingTimeInterval(119), micInUse: false) == nil, "still within grace")
        TestSupport.expectEqual(idle.tick(now: t0.addingTimeInterval(120), micInUse: false), .callEnded)
    }

    private static func testAutoStopUnknownMic() {
        // macOS 13 can't list audio clients: only the 2-hour cap applies.
        var rule = RioMeetingAutoStop(start: t0)
        TestSupport.expect(rule.tick(now: t0.addingTimeInterval(3_000), micInUse: nil) == nil, "unknown mic never ends it")
        TestSupport.expectEqual(rule.tick(now: t0.addingTimeInterval(7_300), micInUse: nil), .tooLong)
    }

    // MARK: Phrases

    private static func parse(_ raw: String) -> RioAction? {
        RioMeetingPhrases.parse(raw: raw, simplified: RioText.simplify(raw))
    }

    private static func testMeetingPhrases() {
        let table: [(MeetingCommand, [String])] = [
            (.start, ["start the meeting copilot", "Start meeting copilot.", "turn on the meeting copilot",
                      "start listening to the meeting", "start listening to this call", "record this meeting",
                      "start recording the call", "meeting copilot on", "start the copilot"]),
            (.stop, ["stop the meeting copilot", "stop meeting copilot", "turn off the meeting copilot",
                     "stop listening to the meeting", "stop listening to the call", "end the meeting copilot",
                     "stop recording the meeting", "meeting copilot off"]),
            (.whatWasSaid, ["what did they just say", "What did he just say?", "what did she say", "what was just said",
                            "what was that they said", "what did I miss", "what have I missed", "catch me up",
                            "what did they say just now", "repeat what they just said"]),
            (.actionItems, ["action items", "what are the action items", "what are my action items",
                            "list the action items", "any action items", "give me the action items from the meeting",
                            "what are the action items from this call"]),
            (.recap, ["recap the meeting", "recap this call", "meeting recap", "give me a recap of the meeting",
                      "summarize the meeting", "summarise this call", "give me a meeting recap", "recap of the call"]),
        ]
        for (command, phrases) in table {
            for phrase in phrases {
                TestSupport.expectEqualNamed(parse(phrase), .meeting(command), phrase)
            }
        }
    }

    private static func testClaudePhrases() {
        let sends: [(String, String)] = [
            ("tell Claude to fix the failing tests", "fix the failing tests"),
            ("Tell Claude to run the build.", "run the build"),
            ("tell Claude Code to add a README", "add a README"),
            ("ask Claude to refactor the parser", "refactor the parser"),
            ("ask Claude Code why the build failed", "why the build failed"),
            ("ask Claude Code what the plan is?", "what the plan is?"),
            ("ask Claude Code about the tests", "about the tests"),
            ("tell Claude that the API key is in the env file", "the API key is in the env file"),
            // "cloud" is how speech-to-text often hears "Claude".
            ("tell cloud to fix the failing test", "fix the failing test"),
            ("tell cloud code to fix the failing test", "fix the failing test"),
            ("ask cloud code to summarize this repo", "summarize this repo"),
            ("tell claude no, use supabase instead", "no, use supabase instead"),
        ]
        for (phrase, text) in sends {
            TestSupport.expectEqualNamed(parse(phrase), .claudeCode(.send(text)), phrase)
        }
        for phrase in ["approve that", "Approve it.", "approve this", "approve Claude's request", "approve the permission",
                       "say yes to Claude", "Claude, approve", "yes approve it", "approve cloud", "yes, approve that",
                       "cloud code approve"] {
            TestSupport.expectEqualNamed(parse(phrase), .claudeCode(.approve), phrase)
        }
        for phrase in ["deny that", "Deny it", "reject that", "decline that", "deny the permission", "tell Claude no",
                       "say no to Claude", "no, don't approve that", "don't approve it", "deny it", "tell cloud no"] {
            TestSupport.expectEqualNamed(parse(phrase), .claudeCode(.deny), phrase)
        }
        for phrase in ["what's Claude doing", "What is Claude doing?", "what's Claude Code doing", "what is Claude up to",
                       "how's Claude doing", "check on Claude", "is Claude done", "check on cloud", "is Claude done yet?",
                       "what is Claude asking me?", "what's cloud code doing", "is Claude waiting"] {
            TestSupport.expectEqualNamed(parse(phrase), .claudeCode(.status), phrase)
        }
        TestSupport.expect(parse("approve that").map { $0.requiresConfirmation } == true, "approve confirms")
        // A plain question to Claude is for the Claude app or the resolver, never typed into a
        // tool-using Claude Code session.
        for phrase in ["ask Claude what a monoid is", "Rio, ask Claude what a monoid is", "ask Claude why the sky is blue",
                       "ask cloud what a monoid is"] {
            TestSupport.expect(RioMeetingPhrases.parse(raw: RioActionParser.stripEnvelope(phrase), simplified: RioText.simplify(RioActionParser.stripEnvelope(phrase))) == nil,
                               "a question to Claude must not reach Claude Code: \(phrase)")
        }
    }

    private static func testPhrasesDontSteal() {
        let others = [
            "stop listening", "stop recording", "start recording", "record a macro", "translate this to French",
            "summarize this", "summarise the selection", "what did you say", "what did I say on Monday",
            "open Claude", "quit Claude", "open the meeting link", "join my next meeting", "what's my next meeting",
            "recap", "approve", "deny", "ask Siri what time it is", "tell Ali I'm late", "ask Ali to call me",
            "action items for tomorrow", "add an action item", "what's the weather", "what are they saying about the weather",
            "start the timer", "what did I miss in my email", "remind me to recap the meeting", "what's Claude's phone number",
            "I need to tell Claude about this", "stop the music", "end the call",
        ]
        for phrase in others {
            TestSupport.expect(parse(phrase) == nil, "must not claim: \(phrase) -> \(String(describing: parse(phrase)))")
        }
        let parser = RioActionParser(installedApps: [])
        TestSupport.expectEqual(parser.parse("Rio, tell Claude to fix the tests"), .actions([.claudeCode(.send("fix the tests"))]))
        TestSupport.expectEqual(parser.parse("Rio approve that"), .actions([.claudeCode(.approve)]))
        TestSupport.expectEqual(parser.parse("Rio tell cloud to fix the failing test"), .actions([.claudeCode(.send("fix the failing test"))]))
        TestSupport.expectEqual(parser.parse("Rio check on cloud"), .actions([.claudeCode(.status)]))
        TestSupport.expectEqual(parser.parse("Rio, recap the meeting"), .actions([.meeting(.recap)]))
        TestSupport.expectEqual(parser.parse("Rio stop listening"), .actions([.stopListening]))
    }

    // MARK: Claude Code screens

    private static let idleScreen = """
    ╭───────────────────────────────────────────────────╮
    │ ✻ Welcome to Claude Code!                         │
    ╰───────────────────────────────────────────────────╯

    > fix the tests

    ⏺ I'll look at the failing tests first.

    ⏺ Read(Tests/RioMeetingTests.swift)
      ⎿  Read 120 lines

    ╭───────────────────────────────────────────────────╮
    │ >                                                 │
    ╰───────────────────────────────────────────────────╯
      ? for shortcuts
    """

    private static let busyScreen = """
    ⏺ Update(Sources/App.swift)
      ⎿  Updated Sources/App.swift with 3 additions

    ✻ Pondering… (12s · ↑ 1.2k tokens · esc to interrupt)

    ╭───────────────────────────────────────────────────╮
    │ >                                                 │
    ╰───────────────────────────────────────────────────╯
    """

    private static let boxedBash = """
    ⏺ I'll clean up the build folder.

    ╭──────────────────────────────────────────────────────────────╮
    │ Bash command                                                 │
    │                                                              │
    │   rm -rf build                                               │
    │   Remove the build directory                                 │
    │                                                              │
    │ Do you want to proceed?                                      │
    │ ❯ 1. Yes                                                     │
    │   2. Yes, and don't ask again for rm commands in /Users/o/x  │
    │   3. No, and tell Claude what to do differently (esc)        │
    ╰──────────────────────────────────────────────────────────────╯
    """

    private static func testLooksLikeClaudeCode() {
        TestSupport.expect(RioClaudeScreen.looksLikeClaudeCode(idleScreen), "idle session")
        TestSupport.expect(RioClaudeScreen.looksLikeClaudeCode(busyScreen), "busy session")
        TestSupport.expect(RioClaudeScreen.looksLikeClaudeCode(boxedBash), "permission prompt")
        TestSupport.expect(RioClaudeScreen.looksLikeClaudeCode("foo\n  ⏵⏵ accept edits on (shift+tab to cycle)\n"), "mode line")
        TestSupport.expect(!RioClaudeScreen.looksLikeClaudeCode(""), "empty")
        TestSupport.expect(!RioClaudeScreen.looksLikeClaudeCode("ofarhan@mac ~ % ls\nREADME.md Sources\nofarhan@mac ~ % "), "plain shell")
        TestSupport.expect(
            !RioClaudeScreen.looksLikeClaudeCode("ofarhan@mac ~ % cat README.md\nClaude Code is a CLI tool.\nofarhan@mac ~ % "),
            "the words alone are not a session"
        )
        // A finished Claude Code session that dropped back to the shell is not a session.
        let old = idleScreen + "\n" + (0..<60).map { "line \($0)" }.joined(separator: "\n") + "\nofarhan@mac ~ % "
        TestSupport.expect(!RioClaudeScreen.looksLikeClaudeCode(old), "chrome far above the shell prompt")
        TestSupport.expect(!RioClaudeScreen.looksLikeClaudeCode("echo '? for shortcuts' in a zsh tutorial"), "inline mention")
    }

    private static func testPromptBoxedBash() {
        guard let prompt = RioClaudeScreen.permissionPrompt(in: boxedBash) else {
            TestSupport.expect(false, "boxed bash prompt not found")
            return
        }
        TestSupport.expectEqual(prompt.question, "Do you want to proceed?")
        TestSupport.expectEqual(prompt.approveKey, "1")
        TestSupport.expectEqual(prompt.denyKey, "3")
        TestSupport.expect(prompt.context.contains("rm -rf build"), "context has the command")
        TestSupport.expect(!prompt.context.contains("│"), "box characters stripped")
        TestSupport.expect(prompt.detail.contains("rm -rf build") && prompt.detail.contains("Do you want to proceed?"), "detail")
        TestSupport.expectEqual(prompt.options.count, 3)
    }

    private static func testPromptEditNoBox() {
        let screen = """
        ⏺ Update(Sources/App.swift)

         Edit file
         Sources/App.swift
          12   let a = 1
          13 - let b = 2
          13 + let b = 3

         Do you want to make this edit to App.swift?
         ❯ 1. Yes
           2. Yes, allow all edits during this session (shift+tab)
           3. No, and tell Claude what to do differently (esc)
        """
        let prompt = RioClaudeScreen.permissionPrompt(in: screen)
        TestSupport.expectEqual(prompt?.approveKey, "1")
        TestSupport.expectEqual(prompt?.denyKey, "3")
        TestSupport.expectEqual(prompt?.question, "Do you want to make this edit to App.swift?")
        TestSupport.expect(prompt?.context.contains("let b = 3") == true, "diff in context")
    }

    private static func testPromptTwoOptions() {
        let screen = """
        │ Fetch                                    │
        │   https://example.com/docs               │
        │ Do you want to allow Claude to fetch this content? │
        │ ❯ 1. Yes                                 │
        │   2. No, and tell Claude what to do differently (esc) │
        """
        let prompt = RioClaudeScreen.permissionPrompt(in: screen)
        TestSupport.expectEqual(prompt?.approveKey, "1")
        TestSupport.expectEqual(prompt?.denyKey, "2")
    }

    private static func testPromptYesNo() {
        let screen = """
        ⏺ Bash(git push origin main)

          Allow Claude to run: git push origin main? (y/n)
        """
        let prompt = RioClaudeScreen.permissionPrompt(in: screen)
        TestSupport.expectEqual(prompt?.approveKey, "y")
        TestSupport.expectEqual(prompt?.denyKey, "n")
        let bracket = RioClaudeScreen.permissionPrompt(in: "Do you want to continue? [y/N]")
        TestSupport.expectEqual(bracket?.approveKey, "y")
        TestSupport.expectEqual(bracket?.denyKey, "n")
    }

    private static func testPromptCursorOnSecond() {
        let screen = """
         Do you want to proceed?
           1. Yes
         ❯ 2. Yes, and don't ask again for npm test commands in /x
           3. No, and tell Claude what to do differently (esc)
        """
        let prompt = RioClaudeScreen.permissionPrompt(in: screen)
        TestSupport.expectEqual(prompt?.approveKey, "1")
        TestSupport.expectEqual(prompt?.denyKey, "3")
    }

    private static func testPromptPlan() {
        let screen = """
        │ Ready to code?                                    │
        │ Here is Claude's plan: …                          │
        │ Would you like to proceed?                        │
        │ ❯ 1. Yes, and auto-accept edits                   │
        │   2. Yes, and manually approve edits              │
        │   3. No, keep planning                            │
        """
        let prompt = RioClaudeScreen.permissionPrompt(in: screen)
        TestSupport.expectEqual(prompt?.approveKey, "2")
        TestSupport.expectEqual(prompt?.denyKey, "3")
    }

    private static func testPromptOnlyPersistentYes() {
        let screen = """
         Do you want to proceed?
         ❯ 1. Yes, and don't ask again for this command
           2. No
        """
        let prompt = RioClaudeScreen.permissionPrompt(in: screen)
        TestSupport.expect(prompt != nil, "still a prompt")
        TestSupport.expect(prompt?.approveKey == nil, "never picks a standing permission")
        TestSupport.expectEqual(prompt?.denyKey, "2")
    }

    private static func testPromptStale() {
        let answered = boxedBash + "\n\n⏺ Bash(rm -rf build)\n  ⎿  (No content)\n\n⏺ Done. The build folder is gone.\n\n"
            + "╭───────────────────────────────────────────────────╮\n│ >                                                 │\n╰───────────────────────────────────────────────────╯\n  ? for shortcuts"
        TestSupport.expect(RioClaudeScreen.permissionPrompt(in: answered) == nil, "answered prompt is not pending")
    }

    private static func testNoPrompt() {
        TestSupport.expect(RioClaudeScreen.permissionPrompt(in: idleScreen) == nil, "idle")
        TestSupport.expect(RioClaudeScreen.permissionPrompt(in: busyScreen) == nil, "busy")
        TestSupport.expect(RioClaudeScreen.permissionPrompt(in: "") == nil, "empty")
        // A numbered list in normal output is not a prompt.
        let list = "⏺ Here are the options:\n\n  1. Yes\n  2. No\n\n⏺ Which do you prefer?\n"
        TestSupport.expect(RioClaudeScreen.permissionPrompt(in: list) == nil, "numbered list in prose")
        TestSupport.expect(RioClaudeScreen.permissionPrompt(in: "Should I continue (y/n)? maybe") == nil, "y/n mid-sentence")
    }

    private static func testPromptTextForConfirmation() {
        let detail = RioClaudeScreen.permissionPrompt(in: boxedBash)?.detail ?? ""
        TestSupport.expect(detail.count <= RioClaudePrompt.maxDetailLength, "detail is bounded")
        let long = "Do you want to proceed?\n" + (0..<200).map { "│ line \($0) of a very long command │" }.joined(separator: "\n")
            + "\n│ Do you want to proceed? │\n│ ❯ 1. Yes │\n│   2. No │"
        let prompt = RioClaudeScreen.permissionPrompt(in: long)
        TestSupport.expect((prompt?.detail.count ?? 0) <= RioClaudePrompt.maxDetailLength, "long detail is cut")
        TestSupport.expect(prompt?.detail.contains("Do you want to proceed?") == true, "question kept when cut")
        TestSupport.expectEqual(prompt?.fingerprint == RioClaudeScreen.permissionPrompt(in: long)?.fingerprint, true)
        TestSupport.expect(prompt?.fingerprint != RioClaudeScreen.permissionPrompt(in: boxedBash)?.fingerprint, "different prompts differ")
    }

    private static func testPicker() {
        typealias C = RioClaudeCandidate
        let idle = idleScreen
        TestSupport.expect(RioClaudeSessionPicker.pick([]) == nil, "none")
        TestSupport.expect(
            RioClaudeSessionPicker.pick([C(id: 1, text: "ofarhan@mac % ls", isFrontmostApp: true, isFocusedWindow: true)]) == nil,
            "no Claude Code anywhere"
        )
        TestSupport.expectEqual(
            RioClaudeSessionPicker.pick([
                C(id: 1, text: "% ls", isFrontmostApp: true, isFocusedWindow: true),
                C(id: 2, text: idle, isFrontmostApp: false, isFocusedWindow: true),
            ])?.id, 2
        )
        // Several: the frontmost app's window wins, then a focused window, then the first.
        TestSupport.expectEqual(
            RioClaudeSessionPicker.pick([
                C(id: 1, text: idle, isFrontmostApp: false, isFocusedWindow: true),
                C(id: 2, text: busyScreen, isFrontmostApp: true, isFocusedWindow: false),
                C(id: 3, text: idle, isFrontmostApp: true, isFocusedWindow: true),
            ])?.id, 3
        )
        TestSupport.expectEqual(
            RioClaudeSessionPicker.pick([
                C(id: 1, text: idle, isFrontmostApp: false, isFocusedWindow: false),
                C(id: 2, text: idle, isFrontmostApp: false, isFocusedWindow: true),
            ])?.id, 2
        )
        TestSupport.expectEqual(
            RioClaudeSessionPicker.pick([
                C(id: 4, text: idle, isFrontmostApp: false, isFocusedWindow: false),
                C(id: 5, text: idle, isFrontmostApp: false, isFocusedWindow: false),
            ])?.id, 4
        )
        // For approve/deny a window with a pending prompt beats one without, even if it isn't frontmost.
        TestSupport.expectEqual(
            RioClaudeSessionPicker.pick([
                C(id: 1, text: idle, isFrontmostApp: true, isFocusedWindow: true),
                C(id: 2, text: boxedBash, isFrontmostApp: false, isFocusedWindow: true),
            ], needingPrompt: true)?.id, 2
        )
        TestSupport.expect(
            RioClaudeSessionPicker.pick([C(id: 1, text: idle, isFrontmostApp: true, isFocusedWindow: true)], needingPrompt: true) == nil,
            "no prompt pending"
        )
        TestSupport.expectEqual(RioClaudeSessionPicker.terminalBundleIDs.contains("com.apple.Terminal"), true)
        TestSupport.expectEqual(RioClaudeSessionPicker.terminalBundleIDs.contains("com.googlecode.iterm2"), true)
        TestSupport.expectEqual(RioClaudeSessionPicker.terminalBundleIDs.contains("dev.warp.Warp-Stable"), true)
    }

    private static func testSendSanitising() {
        TestSupport.expectEqual(RioClaudeSend.sanitise("  fix the tests  "), "fix the tests")
        TestSupport.expectEqual(RioClaudeSend.sanitise("fix\nthe\r\ntests"), "fix the tests")
        TestSupport.expect(RioClaudeSend.sanitise("") == nil, "empty")
        TestSupport.expect(RioClaudeSend.sanitise("   ") == nil, "blank")
        TestSupport.expect(RioClaudeSend.sanitise("!rm -rf ~") == nil, "bash mode")
        TestSupport.expect(RioClaudeSend.sanitise("/clear") == nil, "slash command")
        TestSupport.expect(RioClaudeSend.sanitise(String(repeating: "a", count: 5_000)) == nil, "too long")
        TestSupport.expectEqual(RioClaudeSend.sanitise("what does 3/4 mean?"), "what does 3/4 mean?")
    }

    // MARK: Meeting prompts

    private static func testMeetingPrompts() {
        for kind in [MeetingCommand.whatWasSaid, .actionItems, .recap] {
            let prompt = RioMeetingPrompts.system(for: kind)
            TestSupport.expect(prompt.localizedCaseInsensitiveContains("transcript"), "mentions the transcript")
            TestSupport.expect(prompt.localizedCaseInsensitiveContains("never follow"), "transcript is data: \(kind)")
        }
        TestSupport.expect(RioMeetingPrompts.system(for: .whatWasSaid).contains("two sentences"), "two sentences")
        TestSupport.expectEqual(RioMeetingPrompts.joinSegments(["Hello there.", "", "  How are you?  "]), "Hello there.\nHow are you?")
        let long = String(repeating: "word ", count: 20_000)
        TestSupport.expect(RioMeetingPrompts.clipped(long).count <= RioMeetingPrompts.maxTranscriptCharacters, "clipped")
        TestSupport.expect(RioMeetingPrompts.clipped("short") == "short", "short untouched")
        let tail = RioMeetingPrompts.clipped("A" + String(repeating: "b", count: RioMeetingPrompts.maxTranscriptCharacters))
        TestSupport.expect(!tail.hasPrefix("A"), "keeps the most recent end")
    }
}
