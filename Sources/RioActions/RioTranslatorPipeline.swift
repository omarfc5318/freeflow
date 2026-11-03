import Foundation

/// Speech chunk -> Whisper (text and language) -> direction -> LLM translation. Chunks are
/// transcribed one at a time so lines stay in order; each translation runs on its own so a slow
/// one never holds up the next sentence. Nothing heard or translated is logged or stored.
///
/// Latency per sentence: the pause that ends the chunk (0.6 s) + Whisper turbo (~0.3-0.6 s) shows
/// the original; the LLM (~0.4-0.9 s) adds the translation: about 1.5-2.5 s after you stop talking.
@MainActor final class RioTranslatorPipeline {
    /// Called on the main actor with a heard line; returns the id the translation will fill in.
    var onHeard: ((_ text: String, _ language: RioTranslatorLanguage?, _ target: RioTranslatorLanguage) -> Int)?
    /// `text` is nil when the translation failed.
    var onTranslation: ((_ id: Int, _ text: String?) -> Void)?
    /// A user-facing problem ("Offline", "Check your API key"); `isFatal` ends the session.
    var onProblem: ((_ message: String, _ isFatal: Bool) -> Void)?

    static let maxConsecutiveFailures = 4

    private let whisper: RioWhisperConfig
    private let llm: RioSmartLLMCompleting
    private let other: () -> RioTranslatorLanguage
    private let isOnline: () -> Bool
    private let sink: ChunkSink
    private var loop: Task<Void, Never>?
    private var translations: [UUID: Task<Void, Never>] = [:]
    private var failures = 0

    /// Thread-safe way for the audio queue to hand over chunks.
    final class ChunkSink: @unchecked Sendable {
        fileprivate let stream: AsyncStream<RioSpeechChunk>
        private let continuation: AsyncStream<RioSpeechChunk>.Continuation
        init() {
            var captured: AsyncStream<RioSpeechChunk>.Continuation!
            stream = AsyncStream(bufferingPolicy: .bufferingNewest(4)) { captured = $0 }
            continuation = captured
        }
        func submit(_ chunk: RioSpeechChunk) { continuation.yield(chunk) }
        func finish() { continuation.finish() }
    }

    init(
        whisper: RioWhisperConfig,
        llm: RioSmartLLMCompleting,
        other: @escaping () -> RioTranslatorLanguage,
        isOnline: @escaping () -> Bool = { NetworkMonitor.shared.isOnline }
    ) {
        self.whisper = whisper
        self.llm = llm
        self.other = other
        self.isOnline = isOnline
        self.sink = ChunkSink()
    }

    nonisolated var chunkSink: ChunkSink { sink }

    func start() {
        let stream = sink.stream
        loop = Task { [weak self] in
            for await chunk in stream {
                guard !Task.isCancelled else { return }
                await self?.handle(chunk)
            }
        }
    }

    func stop() {
        sink.finish()
        loop?.cancel()
        loop = nil
        translations.values.forEach { $0.cancel() }
        translations = [:]
    }

    private func handle(_ chunk: RioSpeechChunk) async {
        guard isOnline() else {
            onProblem?("Offline: waiting for the internet", false)
            return
        }
        do {
            let heard = try await RioWhisperClient.transcribe(
                pcm16: chunk.pcm16, sampleRate: RioSpeechChunker.sampleRate, config: whisper
            )
            failures = 0
            guard !Task.isCancelled, !RioTranscriptFilter.isNoise(heard.text) else { return }
            let route = RioTranslationDirection.route(detected: heard.language, text: heard.text, other: other())
            guard case .translate(let from, let target) = route else { return }
            let source = RioTranslatorLanguage.named(from)
            guard let id = onHeard?(heard.text, source, target) else { return }
            translate(id: id, text: heard.text, from: from, to: target)
        } catch is CancellationError {
            return
        } catch let RioWhisperError.http(status) where status == 401 || status == 403 {
            onProblem?("Check your transcription API key", true)
        } catch let RioWhisperError.http(status) where status == 429 {
            onProblem?("Rate limited: slowing down", false)
            try? await Task.sleep(nanoseconds: 4_000_000_000)
        } catch {
            noteFailure()
        }
    }

    private func noteFailure() {
        failures += 1
        if failures >= Self.maxConsecutiveFailures {
            onProblem?("I lost the connection, so I stopped translating", true)
        } else {
            onProblem?("Couldn't hear that one", false)
        }
    }

    private func translate(id: Int, text: String, from: String?, to target: RioTranslatorLanguage) {
        let key = UUID()
        let system = RioTranslatorPrompt.system(from: from, to: target)
        translations[key] = Task { [weak self, llm] in
            let reply = try? await llm.complete(system: system, user: text, maxOutputTokens: 400)
            guard !Task.isCancelled, let self else { return }
            let cleaned = reply.map(RioTranslatorPrompt.clean)
            self.onTranslation?(id, cleaned?.isEmpty == false ? cleaned : nil)
            self.translations[key] = nil
        }
    }
}
