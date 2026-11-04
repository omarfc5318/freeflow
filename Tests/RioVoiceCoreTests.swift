import Foundation

/// Pure tests for voice choice, the silence policy, the mouth level and undo phrases. No audio.
enum RioVoiceCoreTests {
    private typealias Candidate = RioVoiceCandidate

    private static func candidate(
        _ name: String, _ language: String = "en-US", quality: RioVoiceQuality = .standard, id: String? = nil
    ) -> Candidate {
        Candidate(
            identifier: id ?? "com.apple.voice.\(quality).\(language).\(name)",
            name: name, language: language, quality: quality
        )
    }

    static func run() {
        testVoiceChoice()
        testVoiceChoiceAvoidsNoveltyVoices()
        testSilencePolicy()
        testMouthLevel()
        testUndoAndStopPhrases()
        testPhrasesDoNotStealOthers()
        testDeliveryParameters()
    }

    private static func testVoiceChoice() {
        // This Mac: only compact voices. Samantha is the warm, clear one.
        let thisMac = [
            candidate("Daniel", "en-GB"), candidate("Samantha"), candidate("Karen", "en-AU"),
            candidate("Eddy", id: "com.apple.eloquence.en-US.Eddy"),
            candidate("Fred", id: "com.apple.speech.synthesis.voice.Fred"),
        ]
        TestSupport.expectEqual(RioVoiceChooser.pick(from: thisMac)?.name, "Samantha")
        // A premium voice beats a compact one.
        let withPremium = thisMac + [candidate("Ava", quality: .premium)]
        TestSupport.expectEqual(RioVoiceChooser.pick(from: withPremium)?.name, "Ava")
        // Enhanced beats compact but loses to premium.
        let enhanced = thisMac + [candidate("Allison", quality: .enhanced)]
        TestSupport.expectEqual(RioVoiceChooser.pick(from: enhanced)?.name, "Allison")
        TestSupport.expectEqual(RioVoiceChooser.pick(from: enhanced + [candidate("Zoe", quality: .premium)])?.name, "Zoe")
        // Quality beats the name preference: an unknown enhanced voice outranks compact Samantha.
        TestSupport.expectEqual(RioVoiceChooser.pick(from: thisMac + [candidate("Zed", quality: .enhanced)])?.name, "Zed")
        // US English before other English when quality ties.
        TestSupport.expectEqual(RioVoiceChooser.pick(from: [candidate("Moira", "en-IE"), candidate("Nobody")])?.name, "Nobody")
        // Non-English voices are never picked.
        TestSupport.expect(RioVoiceChooser.pick(from: [candidate("Amelie", "fr-FR", quality: .premium)]) == nil, "English only")
        TestSupport.expect(RioVoiceChooser.pick(from: []) == nil, "no voices")
        // Deterministic.
        TestSupport.expectEqual(RioVoiceChooser.pick(from: thisMac), RioVoiceChooser.pick(from: thisMac.reversed()))
    }

    private static func testVoiceChoiceAvoidsNoveltyVoices() {
        let novelty = ["Bad News", "Bahh", "Bells", "Boing", "Bubbles", "Cellos", "Wobble", "Good News", "Jester",
                       "Organ", "Superstar", "Trinoids", "Whisper", "Zarvox", "Albert", "Fred", "Junior", "Ralph"]
        let only = novelty.map { candidate($0, id: "com.apple.speech.synthesis.voice.\($0.replacingOccurrences(of: " ", with: ""))") }
        TestSupport.expect(RioVoiceChooser.pick(from: only) == nil, "novelty voices are never Rio")
        TestSupport.expect(
            RioVoiceChooser.pick(from: only + [candidate("Eddy", id: "com.apple.eloquence.en-US.Eddy")])?.name == "Eddy",
            "falls back to a plain voice"
        )
    }

    private static func testSilencePolicy() {
        func speak(
            enabled: Bool = true, otherMic: Bool = false, recording: Bool = false, text: String = "Done!"
        ) -> Bool {
            RioVoicePolicy.shouldSpeak(
                text: text, isEnabled: enabled, isOtherAppUsingMicrophone: otherMic, isRioRecording: recording
            )
        }
        TestSupport.expect(speak(), "speaks normally")
        TestSupport.expect(!speak(enabled: false), "Settings toggle off")
        TestSupport.expect(!speak(otherMic: true), "silent during a call")
        TestSupport.expect(!speak(recording: true), "silent while Rio records")
        TestSupport.expect(!speak(text: "   "), "nothing to say")
        TestSupport.expect(!speak(enabled: false, otherMic: true, recording: true), "all of them")
    }

    private static func testMouthLevel() {
        for since in stride(from: 0.0, through: 1.0, by: 0.05) {
            for length in [1, 4, 9, 20] {
                let level = RioMouthLevel.level(secondsSinceWord: since, wordLength: length, time: since * 3)
                TestSupport.expect(level >= 0 && level <= 1, "level in range: \(level)")
            }
        }
        let fresh = RioMouthLevel.level(secondsSinceWord: 0, wordLength: 6, time: 0.1)
        let stale = RioMouthLevel.level(secondsSinceWord: 0.6, wordLength: 6, time: 0.1)
        TestSupport.expect(fresh > 0.3, "mouth opens on a word: \(fresh)")
        TestSupport.expect(stale < fresh, "mouth relaxes between words")
        TestSupport.expect(RioMouthLevel.level(secondsSinceWord: 5, wordLength: 6, time: 0.3) < 0.1, "closes in silence")
        let short = RioMouthLevel.level(secondsSinceWord: 0, wordLength: 1, time: 0.2)
        let long = RioMouthLevel.level(secondsSinceWord: 0, wordLength: 12, time: 0.2)
        TestSupport.expect(long >= short, "longer words open wider")
        TestSupport.expectEqual(RioMouthLevel.restingLevel, 0)
    }

    private static func testUndoAndStopPhrases() {
        let undo = [
            "undo", "undo that", "undo it", "Undo the last thing", "undo the last action", "put it back",
            "put that back", "revert that", "take that back", "oops undo",
            "undo the last command", "reverse that",
        ]
        for text in undo {
            TestSupport.expectEqualNamed(
                RioVoicePhrases.parse(raw: text, simplified: RioText.simplify(text)), .undoLast, "undo phrase \"\(text)\""
            )
        }
        let notUndo = [
            "undo typing", "undo that typing", "press command z", "undo my typing", "undo the typing",
            "never mind the timer", "undo send", "undo changes in Word", "go back",
            // "Never mind" means do nothing (the coordinator drops it), never undo (F13/K20).
            "never mind", "nevermind",
        ]
        for text in notUndo {
            TestSupport.expect(
                RioVoicePhrases.parse(raw: text, simplified: RioText.simplify(text)) != .undoLast,
                "\"\(text)\" must not be Rio's undo"
            )
        }
    }

    private static func testPhrasesDoNotStealOthers() {
        let parser = RioActionParser(installedApps: [
            InstalledApp(name: "Google Chrome", bundleIdentifier: nil, url: URL(fileURLWithPath: "/Applications/Google Chrome.app")),
            InstalledApp(name: "Spotify", bundleIdentifier: nil, url: URL(fileURLWithPath: "/Applications/Spotify.app")),
        ])
        TestSupport.expectEqual(parser.parse("open Chrome"), .actions([.openApp(name: "Google Chrome")]))
        TestSupport.expectEqual(parser.parse("close Spotify"), .actions([.quitApp(name: "Spotify")]))
        TestSupport.expectEqual(parser.parse("open YouTube"), .actions([.openURL(URL(string: "https://www.youtube.com")!)]))
        TestSupport.expectEqual(parser.parse("stop listening"), .actions([.stopListening]))
        TestSupport.expectEqual(parser.parse("undo"), .actions([.undoLast]))
        TestSupport.expectEqual(parser.parse("what can you do"), .actions([.showHelp]))
        // Compound commands keep working around the new phrases.
        TestSupport.expectEqual(
            parser.parse("open Chrome and set a 5 minute timer"),
            .actions([.openApp(name: "Google Chrome"), .startTimer(seconds: 300, label: nil)])
        )
    }

    private static func testDeliveryParameters() {
        TestSupport.expect(RioVoiceStyle.pitch > 1.0 && RioVoiceStyle.pitch <= 1.5, "a little higher: small bear")
        TestSupport.expect(RioVoiceStyle.rate > 0.5 && RioVoiceStyle.rate < 0.62, "a touch quicker than default")
        TestSupport.expect(RioVoiceStyle.volume > 0.5 && RioVoiceStyle.volume <= 1, "audible")
    }
}
