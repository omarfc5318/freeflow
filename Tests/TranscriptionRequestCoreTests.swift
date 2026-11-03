import AVFoundation
import Foundation

/// Tests for the vocabulary prompt, its derailment guard and the FLAC upload copy.
/// All inputs are synthetic.
enum TranscriptionRequestCoreTests {
    static func run() {
        testPromptIsPlainDedupedList()
        testPromptStaysWithinTokenBudget()
        testTokenEstimateIsAnUpperBound()
        testEmptyVocabularyHasNoPrompt()
        testLoopingTranscriptIsDerailed()
        testPromptEchoIsDerailed()
        testNormalTranscriptIsNotDerailed()
        testLongRepetitiveSpeechIsNotDerailed()
        testChoiceKeepsSilenceSilent()
        testChoicePrefersVocabularyForSpeech()
        testChoiceFallsBack()
        testLearnedWordReachesPromptBehindLiveDictionary()
        testOverBudgetKeepsContextThenNewestWords()
        testPromptDedupesAcrossContextAndVocabulary()
        testEstimateUsesTwoASCIICharsPerToken()
        testScriptMismatchPrefersPlain()
        testSameScriptKeepsPrompted()
        testOutcomeReporting()
        testFLACOnlyForKnownProviders()
        testFLACCopyKeepsEverySample()
    }

    private static let liveTerms = "Hala, Hala+, Supabase, Groq, Claude Code, Claude, Opus, Sonnet, Fable, Haiku, Anthropic, TestFlight, EAS, Expo, Doha, Dubai, Qatar, HyperFrames, Kokoro, Manim, Cloudflare, Wrangler, Rio, Dougie, Warp, GitHub, iOS, MAT108, ECS119, Taste Compass, Hala Hunt, shemagh"
        .components(separatedBy: ", ")

    /// Regression: learned words are appended to the Dictionary, so the old list-order cut
    /// (1.5 chars/token) dropped every one of them behind a 32-term Dictionary.
    private static func testLearnedWordReachesPromptBehindLiveDictionary() {
        let prompt = TranscriptionRequestCore.vocabularyPrompt(vocabulary: liveTerms + ["Tariqullah"], contextTerms: []) ?? ""
        TestSupport.expect(prompt.hasPrefix("Tariqullah, "), "Newest learned word comes first")
        for term in liveTerms + ["Tariqullah"] {
            TestSupport.expect(prompt.contains(term), "Prompt keeps \(term)")
        }
        TestSupport.expect(
            TranscriptionRequestCore.estimatedTokens(prompt) <= TranscriptionRequestCore.promptTokenBudget,
            "Still within budget"
        )
    }

    private static func testOverBudgetKeepsContextThenNewestWords() {
        let vocabulary = (1...300).map { "Word\($0)" }
        let prompt = TranscriptionRequestCore.vocabularyPrompt(vocabulary: vocabulary, contextTerms: ["Nadia Al-Thani", "Project Falcon"]) ?? ""
        TestSupport.expect(prompt.hasPrefix("Nadia Al-Thani, Project Falcon, Word300, Word299,"), "Context first, then newest")
        TestSupport.expect(!prompt.contains("Word1,") && !prompt.contains("Word1."), "Oldest words are the ones cut")
        TestSupport.expect(
            TranscriptionRequestCore.estimatedTokens(prompt) <= TranscriptionRequestCore.promptTokenBudget,
            "Over-budget list fits the budget"
        )
    }

    private static func testPromptDedupesAcrossContextAndVocabulary() {
        let prompt = TranscriptionRequestCore.vocabularyPrompt(vocabulary: ["Groq", "Claude"], contextTerms: ["claude", "Nadia"])
        TestSupport.expectEqual(prompt, "claude, Nadia, Groq.")
    }

    private static func testEstimateUsesTwoASCIICharsPerToken() {
        TestSupport.expectEqual(TranscriptionRequestCore.estimatedTokens("abcd"), 2)
        TestSupport.expectEqual(TranscriptionRequestCore.estimatedTokens("abcde"), 3)
        TestSupport.expectEqual(TranscriptionRequestCore.estimatedTokens("é"), 2)
    }

    private static func testScriptMismatchPrefersPlain() {
        let prompt = "Hala, Supabase."
        let arabic = "مرحبا كيف حالك اليوم يا صديقي"
        TestSupport.expectEqual(
            TranscriptionRequestCore.choose(prompted: "Marhaba kayf halak alyawm ya sadiqi", plain: arabic, prompt: prompt, isSilencePhrase: silence),
            .plain
        )
        let urdu = "آپ کیسے ہیں آج کا دن کیسا رہا"
        TestSupport.expectEqual(
            TranscriptionRequestCore.choose(prompted: "How are you, how was your day today", plain: urdu, prompt: prompt, isSilencePhrase: silence),
            .plain
        )
        let hindi = "आप कैसे हैं आज का दिन कैसा रहा"
        TestSupport.expectEqual(
            TranscriptionRequestCore.choose(prompted: "Aap kaise hain", plain: hindi, prompt: prompt, isSilencePhrase: silence),
            .plain
        )
    }

    private static func testSameScriptKeepsPrompted() {
        let prompt = "Hala, Supabase."
        TestSupport.expectEqual(
            TranscriptionRequestCore.choose(
                prompted: "ارسل الرابط على Supabase اليوم يا صديقي",
                plain: "ارسل الرابط على سوبابيس اليوم يا صديقي",
                prompt: prompt, isSilencePhrase: silence
            ),
            .prompted
        )
        TestSupport.expectEqual(
            TranscriptionRequestCore.choose(prompted: "Ship it to Groq", plain: "Ship it to Grok", prompt: prompt, isSilencePhrase: silence),
            .prompted
        )
    }

    private static func testOutcomeReporting() {
        let prompt = "Hala, Supabase, Groq."
        let arabic = "مرحبا كيف حالك اليوم يا صديقي"
        func outcome(_ prompted: String?, _ plain: String?) -> TranscriptionRequestCore.VocabularyOutcome? {
            TranscriptionRequestCore.decide(prompted: prompted, plain: plain, prompt: prompt, isSilencePhrase: silence)
        }
        TestSupport.expectEqual(outcome("Ship it", "Ship it"), .usedVocabulary)
        TestSupport.expectEqual(outcome("Hala", "Thank you."), .plainChosen(.silence))
        TestSupport.expectEqual(outcome(Array(repeating: "Cine", count: 80).joined(separator: ", "), "Ship it today."), .plainChosen(.derailed))
        TestSupport.expectEqual(outcome("Marhaba", arabic), .plainChosen(.scriptMismatch))
        TestSupport.expectEqual(outcome(nil, "Ship it today."), .promptedFailed)
        TestSupport.expect(outcome(nil, nil) == nil, "Nothing usable")
        TestSupport.expectEqual(
            TranscriptionRequestCore.statusSuffix(outcome: .usedVocabulary, prompt: prompt),
            " · Vocabulary: used (3 terms)"
        )
        TestSupport.expectEqual(
            TranscriptionRequestCore.statusSuffix(outcome: .promptedFailed, prompt: prompt),
            " · Vocabulary: skipped — prompted request failed"
        )
        TestSupport.expectEqual(
            TranscriptionRequestCore.statusSuffix(outcome: .plainChosen(.scriptMismatch), prompt: prompt),
            " · Vocabulary: skipped — script mismatch"
        )
        TestSupport.expectEqual(TranscriptionRequestCore.statusSuffix(outcome: .noPrompt, prompt: nil), " · Vocabulary: none")
    }

    private static func testPromptIsPlainDedupedList() {
        let prompt = TranscriptionRequestCore.vocabularyPrompt(terms: ["Supabase", " Groq ", "supabase", "", "Claude"])
        TestSupport.expectEqual(prompt, "Supabase, Groq, Claude.")
    }

    private static func testPromptStaysWithinTokenBudget() {
        let terms = (1...400).map { "Term\($0)" }
        guard let prompt = TranscriptionRequestCore.vocabularyPrompt(terms: terms) else {
            TestSupport.expect(false, "A long vocabulary still yields a prompt")
            return
        }
        TestSupport.expect(
            TranscriptionRequestCore.estimatedTokens(prompt) <= TranscriptionRequestCore.promptTokenBudget,
            "Prompt fits the token budget"
        )
        TestSupport.expect(prompt.hasPrefix("Term1, Term2,"), "Earlier terms are kept first")
    }

    /// Token counts measured with Whisper's own tokenizer for these strings.
    private static func testTokenEstimateIsAnUpperBound() {
        let measured: [(String, Int)] = [
            ("Supabase, Zustand, Claude, Vercel, Groq, Fireworks, pnpm, Expo, Kubernetes, Postgres, Figma, Nadia, Tariq, FreeFlow, codesign, Hala, TestFlight, Tailwind, shadcn, Kokoro, ElevenLabs, Anthropic, OpenAI, Gemini, Cloudflare, Wrangler, Hyperframes, GSAP, Manim, Playwright, Xcode, SwiftUI.", 103),
            ("kAudioFormatFLAC, AVAudioPCMBuffer, useEffect, getServerSideProps, x86_64, OAuth2, JWT, gRPC, k8s.", 48),
            ("حلا، مرحبا، الدوحة، الرياض، عبدالله", 22),
            ("Zoë, José, François, Søren, Łukasz, Dvořák", 21)
        ]
        for (text, tokens) in measured {
            TestSupport.expect(
                TranscriptionRequestCore.estimatedTokens(text) >= tokens,
                "Estimate is at least the real token count for \(text.prefix(20))"
            )
        }
    }

    private static func testEmptyVocabularyHasNoPrompt() {
        TestSupport.expect(TranscriptionRequestCore.vocabularyPrompt(terms: []) == nil, "No terms, no prompt")
        TestSupport.expect(TranscriptionRequestCore.vocabularyPrompt(terms: [" ", "\n"]) == nil, "Blank terms, no prompt")
    }

    /// The output Whisper produced on room noise with a labelled vocabulary prompt.
    private static func testLoopingTranscriptIsDerailed() {
        let looping = "Vocabulary, " + Array(repeating: "Cine", count: 60).joined(separator: ", ")
        TestSupport.expect(
            TranscriptionRequestCore.promptDerailed(transcript: looping, prompt: "Supabase, Groq, Claude."),
            "A looping transcript is redone without the prompt"
        )
    }

    private static func testPromptEchoIsDerailed() {
        TestSupport.expect(
            TranscriptionRequestCore.promptDerailed(
                transcript: "Supabase, Groq, Claude, Vercel.",
                prompt: "Supabase, Groq, Claude, Vercel, Figma."
            ),
            "An echoed prompt is redone without the prompt"
        )
    }

    private static func testNormalTranscriptIsNotDerailed() {
        let normal = [
            "Kubernetes pods keep restarting because the Postgres pool is exhausted.",
            "Ask Claude to review the pull request before we deploy to Vercel, then ping Groq support about the rate limit we hit yesterday afternoon.",
            "Thank you.",
            ""
        ]
        for transcript in normal {
            TestSupport.expect(
                !TranscriptionRequestCore.promptDerailed(transcript: transcript, prompt: "Supabase, Groq, Claude, Vercel."),
                "Normal speech keeps the prompted transcript: \(transcript.prefix(20))"
            )
        }
    }

    /// Regression: the ratio of a whole transcript grows with length; this measured 7.85 overall.
    private static func testLongRepetitiveSpeechIsNotDerailed() {
        let paragraph = "So I think what we should do is, um, I think we should just go ahead and ship the thing, and then, you know, I think we can fix the rest later, because honestly I think the team is ready and I think the users are ready. Okay so the next thing is the meeting on Thursday, I think we should move it, I think Friday works better for everyone."
        let long = Array(repeating: paragraph, count: 6).joined(separator: " ")
        TestSupport.expect(
            !TranscriptionRequestCore.promptDerailed(transcript: long, prompt: "Supabase, Groq, Claude."),
            "A long, repetitive dictation is not mistaken for a loop"
        )
    }

    private static let silence: (String) -> Bool = TranscriptionResponseParser.isStockSilencePhrase

    /// Measured: with a vocabulary prompt, accidental taps came back as "Tariq, Hala." or an
    /// invented sentence, while the plain request said "Thank you.".
    private static func testChoiceKeepsSilenceSilent() {
        let prompt = "Nadia, Tariq, Hala."
        for plain in ["Thank you.", "", "  "] {
            TestSupport.expectEqual(
                TranscriptionRequestCore.choose(prompted: "Tariq, Hala.", plain: plain, prompt: prompt, isSilencePhrase: silence),
                .plain
            )
        }
        TestSupport.expectEqual(
            TranscriptionRequestCore.choose(prompted: "I'm going to go to the next one.", plain: "Thank you.", prompt: prompt, isSilencePhrase: silence),
            .plain
        )
    }

    private static func testChoicePrefersVocabularyForSpeech() {
        TestSupport.expectEqual(
            TranscriptionRequestCore.choose(
                prompted: "Ask Claude to review it before we deploy to Vercel.",
                plain: "Ask Claw to review it before we deploy to Versal.",
                prompt: "Claude, Vercel, Groq.",
                isSilencePhrase: silence
            ),
            .prompted
        )
    }

    private static func testChoiceFallsBack() {
        let prompt = "Supabase, Groq, Claude."
        let looping = Array(repeating: "Cine", count: 80).joined(separator: ", ")
        TestSupport.expectEqual(
            TranscriptionRequestCore.choose(prompted: looping, plain: "Ship it today.", prompt: prompt, isSilencePhrase: silence),
            .plain
        )
        TestSupport.expectEqual(
            TranscriptionRequestCore.choose(prompted: nil, plain: "Ship it today.", prompt: prompt, isSilencePhrase: silence),
            .plain
        )
        TestSupport.expectEqual(
            TranscriptionRequestCore.choose(prompted: "Ship it to Groq today.", plain: nil, prompt: prompt, isSilencePhrase: silence),
            .prompted
        )
        TestSupport.expect(
            TranscriptionRequestCore.choose(prompted: looping, plain: nil, prompt: prompt, isSilencePhrase: silence) == nil,
            "Both unusable: report the plain request's error"
        )
    }

    private static func testFLACOnlyForKnownProviders() {
        TestSupport.expect(TranscriptionRequestCore.acceptsFLAC(host: "api.groq.com"), "Groq takes FLAC")
        TestSupport.expect(TranscriptionRequestCore.acceptsFLAC(host: "API.OpenAI.com"), "OpenAI takes FLAC")
        TestSupport.expect(!TranscriptionRequestCore.acceptsFLAC(host: "localhost"), "Unknown servers get WAV")
        TestSupport.expect(!TranscriptionRequestCore.acceptsFLAC(host: nil), "No host, no FLAC")
    }

    /// Regression: Apple's FLAC encoder drops a trailing partial packet unless it is padded.
    private static func testFLACCopyKeepsEverySample() {
        let frameCount = 16_000 * 30 + 234
        let samples = (0..<frameCount).map { Int16(8_000 * sin(Double($0) * 0.07)) }
        let wavURL = FileManager.default.temporaryDirectory.appendingPathComponent("flac-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }
        do {
            let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
            buffer.frameLength = AVAudioFrameCount(frameCount)
            for (index, sample) in samples.enumerated() { buffer.int16ChannelData![0][index] = sample }
            do {
                let wav = try AVAudioFile(forWriting: wavURL, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: false)
                try wav.write(from: buffer)
            }

            let flacURL = try FLACUploadAudio.flacCopy(of: wavURL)
            defer { try? FileManager.default.removeItem(at: flacURL) }
            let decoded = try AVAudioFile(forReading: flacURL, commonFormat: .pcmFormatInt16, interleaved: false)
            let readBack = AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: AVAudioFrameCount(decoded.length))!
            try decoded.read(into: readBack)
            let channel = readBack.int16ChannelData![0]
            TestSupport.expect(Int(readBack.frameLength) >= frameCount, "FLAC keeps the final partial packet")
            let restored = (0..<min(frameCount, Int(readBack.frameLength))).map { channel[$0] }
            TestSupport.expect(restored == samples, "FLAC round trip is bit-exact")
            let padding = (frameCount..<Int(readBack.frameLength)).map { channel[$0] }
            TestSupport.expect(padding.allSatisfy { $0 == 0 }, "Padding is silence")
        } catch {
            TestSupport.expect(false, "FLAC round trip failed: \(error)")
        }
    }
}
