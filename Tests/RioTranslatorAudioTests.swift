import Foundation

/// The translator's pure machinery: speech chunking on synthetic audio, subtitle lines,
/// pause and idle rules, Whisper noise filtering and the LLM prompt.
enum RioTranslatorAudioTests {
    private static let rate = RioSpeechChunker.sampleRate

    /// `seconds` of a 220 Hz tone (loud) or silence, little-endian PCM16 mono.
    private static func audio(_ seconds: Double, loud: Bool) -> Data {
        let count = Int(seconds * Double(rate))
        var data = Data(capacity: count * 2)
        for index in 0..<count {
            let value: Int16 = loud ? Int16(8_000 * sin(2 * Double.pi * 220 * Double(index) / Double(rate))) : 0
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func run() {
        testChunkerSilence()
        testChunkerCuts()
        testChunkerLimits()
        testChunkerInputSlicing()
        testSubtitleBoard()
        testSession()
        testNoiseFilter()
        testPrompt()
        testLayout()
        testRecheckGate()
    }

    // MARK: Chunker

    private static func chunks(_ parts: [Data]) -> [RioSpeechChunk] {
        var chunker = RioSpeechChunker()
        var out: [RioSpeechChunk] = []
        for part in parts { out += chunker.feed(part) }
        if let last = chunker.flush() { out.append(last) }
        return out
    }

    private static func testChunkerSilence() {
        TestSupport.expectEqual(chunks([audio(5, loud: false)]).count, 0)
        TestSupport.expectEqual(chunks([]).count, 0)
    }

    private static func testChunkerCuts() {
        // One utterance followed by a pause is cut once the pause is long enough.
        var chunker = RioSpeechChunker()
        TestSupport.expectEqual(chunker.feed(audio(1.5, loud: true)).count, 0)
        TestSupport.expectEqual(chunker.feed(audio(0.3, loud: false)).count, 0)
        let cut = chunker.feed(audio(0.5, loud: false))
        TestSupport.expectEqual(cut.count, 1)
        if let first = cut.first {
            TestSupport.expect(first.voicedSeconds > 1.4 && first.voicedSeconds < 1.6, "voiced seconds \(first.voicedSeconds)")
            TestSupport.expect(first.seconds >= 1.5 && first.seconds <= 2.2, "chunk seconds \(first.seconds)")
            TestSupport.expectEqual(first.pcm16.count % 2, 0)
        }
        TestSupport.expect(chunker.flush() == nil, "nothing left after the cut")

        // Two utterances with a 1 s gap make two chunks.
        let two = chunks([audio(1.2, loud: true), audio(1.0, loud: false), audio(1.2, loud: true), audio(1.0, loud: false)])
        TestSupport.expectEqual(two.count, 2)

        // A trailing utterance with no pause yet comes out on flush.
        TestSupport.expectEqual(chunks([audio(1.0, loud: true)]).count, 1)

        // A short pause inside a sentence does not cut it.
        let joined = chunks([audio(1.0, loud: true), audio(0.3, loud: false), audio(1.0, loud: true), audio(1.0, loud: false)])
        TestSupport.expectEqual(joined.count, 1)

        // A cough (0.1 s) is dropped; a short real word (0.4 s) is kept.
        TestSupport.expectEqual(chunks([audio(0.1, loud: true), audio(2.0, loud: false)]).count, 0)
        TestSupport.expectEqual(chunks([audio(0.4, loud: true), audio(2.0, loud: false)]).count, 1)

        // Speech after a long silence still starts a clean chunk and keeps its first moment.
        let late = chunks([audio(4.0, loud: false), audio(1.0, loud: true), audio(1.0, loud: false)])
        TestSupport.expectEqual(late.count, 1)
        TestSupport.expect((late.first?.seconds ?? 0) < 2.0, "silence before speech is not sent")
    }

    private static func testChunkerLimits() {
        // Ten seconds of unbroken speech is cut into pieces of at most 6 s, losing no audio.
        let long = chunks([audio(10, loud: true), audio(1.0, loud: false)])
        TestSupport.expect(long.count >= 2, "long speech is split, got \(long.count)")
        for chunk in long { TestSupport.expect(chunk.seconds <= 6.01, "chunk of \(chunk.seconds)s is too long") }
        let total = long.reduce(0.0) { $0 + $1.voicedSeconds }
        TestSupport.expect(total > 9.6 && total < 10.1, "voiced audio kept: \(total)")
        // Every chunk except possibly the last is a decent length (no 0.2 s slivers from a cut).
        for chunk in long.dropLast() { TestSupport.expect(chunk.seconds >= 1.0, "sliver of \(chunk.seconds)s") }
    }

    private static func testChunkerInputSlicing() {
        // The same audio fed in odd-sized slices (even an odd byte count) gives the same chunks.
        let whole = audio(1.2, loud: true) + audio(1.0, loud: false) + audio(2.0, loud: true) + audio(1.0, loud: false)
        let expected = chunks([whole])
        var sliced: [Data] = []
        var offset = 0
        let sizes = [333, 1_001, 4_097, 7]
        var turn = 0
        while offset < whole.count {
            let size = min(sizes[turn % sizes.count], whole.count - offset)
            sliced.append(Data(whole[offset..<(offset + size)]))
            offset += size
            turn += 1
        }
        let actual = chunks(sliced)
        TestSupport.expectEqual(actual.count, expected.count)
        TestSupport.expectEqual(actual.map { $0.pcm16.count }, expected.map { $0.pcm16.count })
    }

    // MARK: Subtitles

    private static func testSubtitleBoard() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var board = RioSubtitleBoard()
        var ids: [Int] = []
        for index in 0..<5 {
            let step = board.adding(
                original: "line \(index)", language: .arabic, target: .english, now: t0.addingTimeInterval(Double(index))
            )
            board = step.board
            ids.append(step.id)
        }
        TestSupport.expectEqual(board.lines.count, RioSubtitleBoard.maxLines)
        TestSupport.expectEqual(board.lines.map { $0.original }, ["line 2", "line 3", "line 4"])
        TestSupport.expect(Set(ids).count == 5, "ids are unique")

        // A translation fills in its own line only.
        board = board.settingTranslation(id: ids[3], text: "three")
        TestSupport.expectEqual(board.lines.map { $0.translation }, [nil, "three", nil])
        // A translation for a line that already scrolled away is ignored.
        TestSupport.expectEqual(board.settingTranslation(id: ids[0], text: "gone").lines, board.lines)

        // "Say it" speaks the newest translation, in its language, even after lines expire.
        board = board.settingTranslation(id: ids[4], text: "four")
        TestSupport.expectEqual(board.lastTranslation?.text, "four")
        TestSupport.expectEqual(board.lastTranslation?.language, .english)
        let later = board.pruned(now: t0.addingTimeInterval(500))
        TestSupport.expectEqual(later.lines.count, 0)
        TestSupport.expectEqual(later.lastTranslation?.text, "four")

        // Pruning only removes old lines.
        let partial = board.pruned(now: t0.addingTimeInterval(4 + RioSubtitleBoard.maxAge - 1))
        TestSupport.expectEqual(partial.lines.map { $0.original }, ["line 4"])

        // Empty translations don't count as the last one.
        let empty = RioSubtitleBoard().adding(original: "x", language: .arabic, target: .english, now: t0)
        let blank = empty.board.settingTranslation(id: empty.id, text: "   ")
        TestSupport.expect(blank.lastTranslation == nil, "blank translation ignored")
    }

    // MARK: Session

    private static func testSession() {
        let t0 = Date(timeIntervalSince1970: 5_000)
        var session = RioTranslatorSession()
        TestSupport.expect(!session.isActive, "starts off")
        TestSupport.expect(!session.shouldAutoStop(now: t0.addingTimeInterval(99_999)), "off never auto-stops")
        session = session.starting(now: t0)
        TestSupport.expect(session.isActive, "on")
        TestSupport.expect(!session.shouldAutoStop(now: t0.addingTimeInterval(RioTranslatorSession.idleLimit - 1)), "not yet")
        TestSupport.expect(session.shouldAutoStop(now: t0.addingTimeInterval(RioTranslatorSession.idleLimit + 1)), "10 minutes of silence")
        TestSupport.expectEqual(RioTranslatorSession.idleLimit, 600)

        // Speech resets the idle clock.
        session = session.speechHeard(now: t0.addingTimeInterval(500))
        TestSupport.expect(!session.shouldAutoStop(now: t0.addingTimeInterval(700)), "speech reset the clock")
        TestSupport.expect(session.shouldAutoStop(now: t0.addingTimeInterval(1_101)), "10 minutes after the last speech")

        // Pausing: any reason pauses, all must clear to resume, and paused time is not idle time.
        session = session.setting(.rioSpeaking, active: true, now: t0.addingTimeInterval(520))
        session = session.setting(.dictation, active: true, now: t0.addingTimeInterval(521))
        TestSupport.expect(session.isPaused, "paused")
        session = session.setting(.rioSpeaking, active: false, now: t0.addingTimeInterval(530))
        TestSupport.expect(session.isPaused, "still paused for dictation")
        TestSupport.expect(!session.shouldAutoStop(now: t0.addingTimeInterval(5_000)), "paused never auto-stops")
        session = session.setting(.dictation, active: false, now: t0.addingTimeInterval(2_000))
        TestSupport.expect(!session.isPaused, "resumed")
        TestSupport.expect(!session.shouldAutoStop(now: t0.addingTimeInterval(2_000 + 599)), "idle clock restarts on resume")
        TestSupport.expect(session.shouldAutoStop(now: t0.addingTimeInterval(2_000 + 601)), "then 10 minutes pass")

        // Pauses before start or after stop do nothing; stopping clears everything.
        let off = RioTranslatorSession().setting(.dictation, active: true, now: t0)
        TestSupport.expect(!off.isPaused && !off.isActive, "pause while off is ignored")
        let stopped = session.setting(.conversationCommand, active: true, now: t0).stopping()
        TestSupport.expect(!stopped.isActive && !stopped.isPaused, "stop clears pauses")
        // Turning it on again starts clean.
        TestSupport.expect(!stopped.starting(now: t0).isPaused, "restart is not paused")
    }

    // MARK: Whisper noise

    private static func testNoiseFilter() {
        let noise = [
            "", "   ", "...", "[Music]", "(music)", "♪♪", "Thanks for watching!", "Thank you for watching.",
            "Please subscribe to my channel", "Like and subscribe", "Subtitles by the Amara.org community",
            "ترجمة نانسي قنقر", "شكرا على المشاهدة", "اشتركوا في القناة", "you you you you you you",
            "Subtitles by Amara.org",
        ]
        for text in noise { TestSupport.expect(RioTranscriptFilter.isNoise(text), "noise: \(text)") }
        let speech = [
            "Where is the train station?", "Thank you.", "مرحبا كيف حالك", "I love watching football",
            "Please pass the salt", "شكرا", "Can you subscribe me to the newsletter",
        ]
        for text in speech { TestSupport.expect(!RioTranscriptFilter.isNoise(text), "speech: \(text)") }
    }

    // MARK: Prompt

    private static func testPrompt() {
        let toEnglish = RioTranslatorPrompt.system(from: "arabic", to: .english)
        TestSupport.expect(toEnglish.contains("English"), "names the target")
        TestSupport.expect(toEnglish.lowercased().contains("only"), "asks for the translation only")
        TestSupport.expect(toEnglish.contains("arabic") || toEnglish.contains("Arabic"), "names the source")
        let toArabic = RioTranslatorPrompt.system(from: nil, to: .arabic)
        TestSupport.expect(toArabic.contains("Arabic"), "target Arabic")
        TestSupport.expect(toArabic.lowercased().contains("gulf") || toArabic.lowercased().contains("natural"), "asks for natural Arabic")

        TestSupport.expectEqual(RioTranslatorPrompt.clean("  \"Hello there\"  "), "Hello there")
        TestSupport.expectEqual(RioTranslatorPrompt.clean("Translation: Hello there"), "Hello there")
        TestSupport.expectEqual(RioTranslatorPrompt.clean("English: Hello there\n"), "Hello there")
        TestSupport.expectEqual(RioTranslatorPrompt.clean("مرحبا"), "مرحبا")
        TestSupport.expectEqual(RioTranslatorPrompt.clean("«مرحبا»"), "مرحبا")
        TestSupport.expectEqual(RioTranslatorPrompt.clean("Hello\nworld"), "Hello world")
    }

    // MARK: Layout and recheck

    private static func testLayout() {
        let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let visible = CGRect(x: 0, y: 70, width: 1_440, height: 805)
        let frame = RioTranslatorLayout.captionFrame(screenFrame: screen, visibleFrame: visible, height: 150)
        TestSupport.expect(frame.minX > 80, "clear of the bear")
        TestSupport.expectEqual(frame.minY, 4)
        TestSupport.expectEqual(frame.width, RioTranslatorLayout.captionWidth)
        TestSupport.expectEqual(frame.height, 150)
        // A left-side Dock moves the card with the visible area.
        let docked = RioTranslatorLayout.captionFrame(
            screenFrame: screen, visibleFrame: CGRect(x: 80, y: 0, width: 1_360, height: 875), height: 100
        )
        TestSupport.expect(docked.minX > frame.minX, "moves right of a left Dock")
        // A narrow screen shrinks the card but keeps it inside.
        let narrow = RioTranslatorLayout.captionFrame(
            screenFrame: CGRect(x: 0, y: 0, width: 500, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 800), height: 100
        )
        TestSupport.expect(narrow.maxX <= 500 - RioTranslatorLayout.edgeInset + 0.5, "stays on screen")
        TestSupport.expect(narrow.width >= 200, "still readable")
        // A very tall card is clamped to the screen.
        TestSupport.expect(
            RioTranslatorLayout.captionFrame(screenFrame: screen, visibleFrame: visible, height: 5_000).height <= visible.height,
            "height clamped"
        )
    }

    private static func testRecheckGate() {
        // English commands are never listened to twice.
        for text in ["open Chrome", "Open chrome and Spotify", "volume up", "what's the weather", "turn on wifi",
                     "type hello", "translate what is being said", "stop listening", "set a timer for five minutes"] {
            TestSupport.expect(!RioCommandRecheckGate.shouldRecheck(onDeviceText: text), "no recheck: \(text)")
        }
        // Nothing heard, or something that doesn't begin like a command: ask Whisper.
        for text in ["", "   ", "afta crow", "cola madhow sota", "fatah chrome", "123"] {
            TestSupport.expect(RioCommandRecheckGate.shouldRecheck(onDeviceText: text), "recheck: \(text)")
        }
    }
}
