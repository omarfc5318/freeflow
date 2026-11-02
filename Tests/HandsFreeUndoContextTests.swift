import Foundation

/// Tests for hands-free auto-stop, Undo Last Dictation and names from the window context.
/// All inputs are synthetic.
enum HandsFreeUndoContextTests {
    static func run() {
        testAutoStopWaitsOutNaturalPauses()
        testAutoStopNeedsSpeechFirst()
        testAutoStopIgnoresNoiseFlicker()
        testAutoStopOffNeverStops()
        testAutoStopIgnoresDeviceWarmUpZeros()
        testAutoStopKeepsRecordingFastConnectedSpeech()
        testAutoStopSkipsMicrophoneRampUp()
        testContextTermsFindNames()
        testContextTermsSkipFailuresAndOrdinaryWords()
        testContextTermsHandlePunctuationAndAddresses()
        testContextTermsAreCapped()
        testUndoFindsDictationAtCursor()
        testUndoAcceptsTrimmedTrailingSpace()
        testUndoLeavesEditedTextAlone()
        testUndoOnlyMatchesAtCursor()
        testUndoCountsUTF16()
        testUndoShortcutFiresOnLeadingEdgeOnly()
    }

    // MARK: Hands-free

    private static let bufferSeconds = 0.02

    /// Feeds (level in dBFS, seconds) segments in 20 ms buffers; returns when it stopped.
    private static func stopTime(delay: TimeInterval, _ segments: [(db: Float, seconds: Double)]) -> Double? {
        var detector = SilenceAutoStop(delay: delay)
        var elapsed = 0.0
        for segment in segments {
            let rms: Float = segment.db <= -200 ? 0 : powf(10, segment.db / 20)
            for _ in 0..<Int((segment.seconds / bufferSeconds).rounded()) {
                elapsed += bufferSeconds
                if detector.shouldStop(afterBufferWithRMS: rms, duration: bufferSeconds) { return elapsed }
            }
        }
        return nil
    }

    private static func testAutoStopWaitsOutNaturalPauses() {
        let stop = stopTime(delay: 3, [(-60, 1), (-20, 2), (-60, 1.5), (-20, 1), (-60, 10)])
        TestSupport.expect(stop != nil, "Stops after the speaker goes quiet")
        TestSupport.expect(abs((stop ?? 0) - 8.5) < 0.05, "Stops the chosen delay after the last speech, not in the 1.5 s pause")
    }

    private static func testAutoStopNeedsSpeechFirst() {
        TestSupport.expect(stopTime(delay: 3, [(-60, 20)]) == nil, "Never stops before anything was said")
        TestSupport.expect(stopTime(delay: 3, [(-60, 1), (-20, 0.2), (-60, 10)]) == nil, "A short click does not arm it")
    }

    private static func testAutoStopIgnoresNoiseFlicker() {
        var segments: [(db: Float, seconds: Double)] = [(-60, 1), (-20, 2)]
        for _ in 0..<12 { segments += [(-60, 0.48), (-40, 0.02)] }
        let stop = stopTime(delay: 3, segments)
        TestSupport.expect(stop != nil && abs((stop ?? 0) - 6.0) < 0.1, "Single-buffer noise spikes do not keep it recording")
    }

    private static func testAutoStopOffNeverStops() {
        TestSupport.expect(stopTime(delay: 0, [(-60, 1), (-20, 2), (-60, 20)]) == nil, "Off means off")
    }

    private static func testAutoStopIgnoresDeviceWarmUpZeros() {
        let stop = stopTime(delay: 3, [(-300, 0.5), (-60, 1), (-20, 2), (-60, 10)])
        TestSupport.expect(stop != nil && abs((stop ?? 0) - 6.5) < 0.05, "Zeros from the device do not distort the noise floor")
    }

    /// Regression (review): with short, raised gaps between syllables the floor used to creep
    /// up until speech counted as silence and the recording stopped mid-sentence.
    private static func testAutoStopKeepsRecordingFastConnectedSpeech() {
        var segments: [(db: Float, seconds: Double)] = [(-55, 1)]
        for _ in 0..<60 { segments += [(-30, 0.3), (-42, 0.08)] }
        let speechEnds = 1 + 60 * 0.38
        let stop = stopTime(delay: 5, segments + [(-55, 10)])
        TestSupport.expect(stop != nil && (stop ?? 0) > speechEnds + 4.9, "Never stops while the speaker is still talking")
    }

    /// Regression: a recording that opened at -73 dB before settling at -55 dB never stopped,
    /// because the floor was learned from the ramp-up and the room then read as speech.
    private static func testAutoStopSkipsMicrophoneRampUp() {
        let stop = stopTime(delay: 3, [(-73, 0.02), (-65, 0.02), (-55, 1.5), (-35, 3), (-55, 10)])
        TestSupport.expect(stop != nil && abs((stop ?? 0) - 7.54) < 0.05, "Stops after speech despite the ramp-up")
    }

    // MARK: Names from the window context

    private static func testContextTermsFindNames() {
        let summary = "The user is replying to a Slack direct message from Siobhan Ní Bhriain about the Q3 roadmap. They are likely confirming that Tadhg will review the Figma file."
        TestSupport.expectEqual(
            ContextVocabularyCore.terms(fromSummary: summary),
            ["Slack", "Siobhan Ní Bhriain", "Q3", "Tadhg", "Figma"]
        )
    }

    private static func testContextTermsSkipFailuresAndOrdinaryWords() {
        TestSupport.expectEqual(
            ContextVocabularyCore.terms(fromSummary: ContextInferenceFailure.timeout.summary), []
        )
        TestSupport.expectEqual(ContextVocabularyCore.terms(fromSummary: "Maybe I will email Zoë today."), ["Zoë"])
        TestSupport.expectEqual(ContextVocabularyCore.terms(fromSummary: ""), [])
    }

    private static func testContextTermsHandlePunctuationAndAddresses() {
        TestSupport.expectEqual(
            ContextVocabularyCore.terms(fromSummary: "The user is in Krzysztof's thread, with Ana and the Next.js docs."),
            ["Krzysztof", "Ana", "Next.js"]
        )
        TestSupport.expectEqual(
            ContextVocabularyCore.terms(fromSummary: "The user is emailing Bob@Example.com about https://Example.com today."),
            []
        )
    }

    private static func testContextTermsAreCapped() {
        let names = (1...20).map { "Name\($0)" }.joined(separator: ", ")
        let terms = ContextVocabularyCore.terms(fromSummary: "The user wrote to \(names).")
        TestSupport.expectEqual(terms.count, ContextVocabularyCore.maximumTerms)
        TestSupport.expectEqual(terms.first, "Name1")
    }

    // MARK: Undo Last Dictation

    private static func undoRange(_ inserted: String, in value: String, cursor: Int) -> NSRange? {
        UndoDictationCore.rangeEndingAtCursor(
            inserted: inserted, fieldValue: value, selection: NSRange(location: cursor, length: 0)
        )
    }

    private static func testUndoFindsDictationAtCursor() {
        TestSupport.expectEqual(
            undoRange("Thanks Siobhan. ", in: "Hello. Thanks Siobhan. ", cursor: 23),
            NSRange(location: 7, length: 16)
        )
    }

    private static func testUndoAcceptsTrimmedTrailingSpace() {
        TestSupport.expectEqual(
            undoRange("Thanks Siobhan. ", in: "Thanks Siobhan.", cursor: 15),
            NSRange(location: 0, length: 15)
        )
    }

    private static func testUndoLeavesEditedTextAlone() {
        TestSupport.expect(
            undoRange("Thanks Siobhan. ", in: "Thanks Siobhán. ", cursor: 16) == nil,
            "Edited dictation is never removed"
        )
        TestSupport.expect(undoRange(" ", in: "a b", cursor: 2) == nil, "Whitespace-only text is never matched")
        TestSupport.expect(
            UndoDictationCore.rangeEndingAtCursor(
                inserted: "Hi. ", fieldValue: "Hi. ", selection: NSRange(location: 0, length: 4)
            ) == nil,
            "A selection instead of a cursor is not a fresh paste"
        )
    }

    /// Regression: an earlier version also removed a copy found anywhere in the field.
    private static func testUndoOnlyMatchesAtCursor() {
        TestSupport.expect(
            undoRange("Thanks Siobhan. ", in: "Thanks Siobhan. More text", cursor: 25) == nil,
            "A copy away from the cursor is left alone"
        )
        TestSupport.expect(undoRange("yes", in: "I said yesterday", cursor: 16) == nil, "Never part of a word elsewhere")
        TestSupport.expectEqual(undoRange("Ok. ", in: "Ok. Ok. ", cursor: 8), NSRange(location: 4, length: 4))
        TestSupport.expect(undoRange("Ok. ", in: "Ok. Ok. ", cursor: 2) == nil, "Cursor inside other text")
    }

    private static func testUndoCountsUTF16() {
        TestSupport.expectEqual(undoRange("Hi. ", in: "👋 Hi. ", cursor: 7), NSRange(location: 3, length: 4))
        TestSupport.expect(undoRange("Hi. ", in: "Hi. ", cursor: 99) == nil, "Out-of-range cursor")
    }

    private static func testUndoShortcutFiresOnLeadingEdgeOnly() {
        let binding = ShortcutBinding(keyCode: 97, keyDisplay: "F6", modifiers: [], kind: .key, preset: nil)
        let configuration = ShortcutConfiguration(hold: .disabled, toggle: .disabled, undoLast: binding)
        let down = ShortcutMatcher.reduce(
            state: ShortcutInputState(),
            event: .keyChanged(keyCode: 97, isDown: true, isRepeat: false),
            configuration: configuration
        )
        let repeated = ShortcutMatcher.reduce(
            state: down.state,
            event: .keyChanged(keyCode: 97, isDown: true, isRepeat: true),
            configuration: configuration
        )
        let up = ShortcutMatcher.reduce(
            state: repeated.state,
            event: .keyChanged(keyCode: 97, isDown: false, isRepeat: false),
            configuration: configuration
        )
        TestSupport.expectEqual(down.emittedEvents, [.undoLastTriggered])
        TestSupport.expectEqual(down.consumeDecision, .consume)
        TestSupport.expectEqual(repeated.emittedEvents, [])
        TestSupport.expectEqual(up.emittedEvents, [])
        TestSupport.expectEqual(
            DictationShortcutSessionController().handle(event: .undoLastTriggered, isTranscribing: false), nil
        )
    }
}
