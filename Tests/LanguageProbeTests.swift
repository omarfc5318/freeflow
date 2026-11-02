import Foundation

/// Live language checks: timing, audio packing and reading Whisper's answer. Synthetic audio.
enum LanguageProbeTests {
    static func run() {
        testFirstProbeWaitsForSpeech()
        testSilenceNeverProbes()
        testOneProbeInFlight()
        testLaterProbesAndCap()
        testWindowTrim()
        testRMS()
        testWAVHeader()
        testModelAndEndpoint()
        testParseResponse()
        testLookFromResponse()
        testMultipartHasNoPromptOrLanguage()
    }

    private static let chunk = 0.1

    /// Feeds `seconds` of audio at `rms`; returns the plan and how many probes fired.
    private static func feed(_ plan: LanguageProbePlan, seconds: Double, rms: Float) -> (LanguageProbePlan, Int) {
        var plan = plan
        var fired = 0
        for _ in 0..<Int((seconds / chunk).rounded()) {
            let step = plan.adding(chunkSeconds: chunk, rms: rms)
            plan = step.plan
            if step.shouldProbe { fired += 1 }
        }
        return (plan, fired)
    }

    private static func testFirstProbeWaitsForSpeech() {
        let (early, none) = feed(LanguageProbePlan(), seconds: 1.2, rms: 0.05)
        TestSupport.expect(none == 0, "No check before 1.4 s of speech")
        let (after, one) = feed(early, seconds: 0.3, rms: 0.05)
        TestSupport.expect(one == 1, "First check fires at about 1.4 s of speech")
        TestSupport.expect(after.isInFlight, "The check is marked in flight")
    }

    private static func testSilenceNeverProbes() {
        let (_, fired) = feed(LanguageProbePlan(), seconds: 20, rms: 0.002)
        TestSupport.expect(fired == 0, "Silence is never sent")
    }

    private static func testOneProbeInFlight() {
        let (plan, first) = feed(LanguageProbePlan(), seconds: 1.5, rms: 0.05)
        let (_, more) = feed(plan, seconds: 10, rms: 0.05)
        TestSupport.expect(first == 1 && more == 0, "Only one check at a time")
    }

    private static func testLaterProbesAndCap() {
        var plan = LanguageProbePlan()
        var fired = 0
        for _ in 0..<600 {
            let step = plan.adding(chunkSeconds: chunk, rms: 0.05)
            plan = step.shouldProbe ? step.plan.finishingProbe() : step.plan
            if step.shouldProbe { fired += 1 }
        }
        TestSupport.expect(fired == LanguageProbePlan.maxProbes, "A long dictation stops at the cap, got \(fired)")

        let (afterFirst, _) = feed(LanguageProbePlan(), seconds: 1.5, rms: 0.05)
        let (_, early) = feed(afterFirst.finishingProbe(), seconds: 3.2, rms: 0.05)
        TestSupport.expect(early == 0, "Later checks wait 3.5 s of speech")
    }

    private static func testWindowTrim() {
        let long = Data(repeating: 1, count: LanguageProbePlan.bytesPerSecond * 5 + 1)
        let trimmed = LanguageProbeCore.trimmedToWindow(long)
        TestSupport.expect(trimmed.count == LanguageProbePlan.bytesPerSecond * 3, "Keeps the last 3 s")
        TestSupport.expect(trimmed.count % 2 == 0, "Cut on a sample boundary")
        let short = Data(repeating: 1, count: 100)
        TestSupport.expect(LanguageProbeCore.trimmedToWindow(short) == short, "Short audio is untouched")
    }

    private static func pcm(_ samples: [Int16]) -> Data {
        var data = Data()
        for sample in samples { withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    private static func testRMS() {
        TestSupport.expect(LanguageProbeCore.rms(ofPCM16: Data()) == 0, "Empty audio is silent")
        TestSupport.expect(LanguageProbeCore.rms(ofPCM16: pcm([0, 0, 0])) == 0, "Zeros are silent")
        let full = LanguageProbeCore.rms(ofPCM16: pcm([Int16.max, -Int16.max]))
        TestSupport.expectApproximatelyEqual(Double(full), 1, accuracy: 0.001)
    }

    private static func testWAVHeader() {
        let wav = LanguageProbeCore.wav(pcm16: pcm([1, 2, 3, 4]))
        TestSupport.expect(wav.count == 44 + 8, "44-byte header plus samples")
        TestSupport.expect(String(data: wav.prefix(4), encoding: .ascii) == "RIFF", "RIFF tag")
        TestSupport.expect(String(data: wav.subdata(in: 8..<12), encoding: .ascii) == "WAVE", "WAVE tag")
        let rate = wav.subdata(in: 24..<28).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        TestSupport.expect(rate == 24_000, "Sample rate in header")
    }

    private static func testModelAndEndpoint() {
        TestSupport.expect(
            LanguageProbeCore.probeModel(baseURL: "https://api.groq.com/openai/v1", configuredModel: "whisper-large-v3")
                == "whisper-large-v3-turbo",
            "Groq checks use turbo"
        )
        TestSupport.expect(
            LanguageProbeCore.probeModel(baseURL: "https://api.openai.com/v1", configuredModel: "whisper-1") == "whisper-1",
            "Other providers keep their model"
        )
        TestSupport.expect(
            LanguageProbeCore.endpoint(baseURL: "https://api.groq.com/openai/v1/")?.absoluteString
                == "https://api.groq.com/openai/v1/audio/transcriptions",
            "Endpoint joins cleanly"
        )
        TestSupport.expect(LanguageProbeCore.endpoint(baseURL: "not a url") == nil, "Bad base URL gives no endpoint")
    }

    private static func testParseResponse() {
        let verbose = Data(#"{"text":" مرحبا","language":"arabic","duration":2.1}"#.utf8)
        let parsed = LanguageProbeCore.parseResponse(verbose)
        TestSupport.expect(parsed?.language == "arabic" && parsed?.text == " مرحبا", "Reads verbose_json")
        let plain = LanguageProbeCore.parseResponse(Data(#"{"text":"hello"}"#.utf8))
        TestSupport.expect(plain?.language == nil && plain?.text == "hello", "Plain json has no language")
        TestSupport.expect(LanguageProbeCore.parseResponse(Data("oops".utf8)) == nil, "Garbage is nil")
    }

    private static func testLookFromResponse() {
        TestSupport.expect(LanguageProbeCore.look(language: "arabic", text: "") == .shemagh, "Arabic language")
        TestSupport.expect(LanguageProbeCore.look(language: "urdu", text: "مرحبا") == .turban, "Whisper's Urdu beats shared script")
        TestSupport.expect(LanguageProbeCore.look(language: "hindi", text: "") == .turban, "Hindi language")
        TestSupport.expect(LanguageProbeCore.look(language: "english", text: "hello there") == SpokenLook.none, "English")
        TestSupport.expect(LanguageProbeCore.look(language: nil, text: "كيف حالك") == .shemagh, "No language: script decides")
        TestSupport.expect(LanguageProbeCore.look(language: nil, text: "") == nil, "Nothing to go on")
    }

    private static func testMultipartHasNoPromptOrLanguage() {
        let body = LanguageProbeCore.multipartBody(wav: Data([1, 2]), model: "m", responseFormat: "verbose_json", boundary: "B")
        let text = String(decoding: body, as: UTF8.self)
        TestSupport.expect(text.contains("name=\"model\"\r\n\r\nm\r\n"), "Has model")
        TestSupport.expect(text.contains("verbose_json"), "Has response format")
        TestSupport.expect(!text.contains("name=\"prompt\"") && !text.contains("name=\"language\""), "No bias fields")
        TestSupport.expect(text.hasSuffix("--B--\r\n"), "Closed boundary")
    }
}
