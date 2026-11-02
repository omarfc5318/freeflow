import Foundation
import os
import os.log

private let probeLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "LanguageProbe")

/// Listens to the live audio of one dictation and, as soon as enough speech is heard, asks
/// Whisper which language it is, so Rio can change outfit mid-dictation. Feed it with
/// `append` from the recorder's PCM16 tap; `stop()` when the recording ends.
/// `@unchecked Sendable`: mutable state lives on `queue`, the stop flag behind a lock.
final class LanguageProbeService: @unchecked Sendable {
    struct Configuration {
        let endpoint: URL
        let apiKey: String
        let model: String
    }

    /// After a 429 every dictation skips checks for a while, so they never use up the rate
    /// limit the real transcription needs.
    private static let rateLimitBackoff: TimeInterval = 300
    private static let requestTimeout: TimeInterval = 4
    private static let pausedUntil = OSAllocatedUnfairLock<Date?>(initialState: nil)

    static var isPausedForRateLimit: Bool {
        pausedUntil.withLock { until in until.map { $0 > Date() } ?? false }
    }

    private let config: Configuration
    private let onLook: (SpokenLook) -> Void
    private let queue = DispatchQueue(label: "com.zachlatta.freeflow.language-probe")
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    // Touched only on `queue`.
    private var plan = LanguageProbePlan()
    private var recent = Data()
    private var requests: [Task<Void, Never>] = []

    /// `onLook` runs on the main queue with each detected look, only while not stopped.
    init(config: Configuration, onLook: @escaping (SpokenLook) -> Void) {
        self.config = config
        self.onLook = onLook
    }

    private var isStopped: Bool { stopped.withLock { $0 } }

    /// One chunk of 24 kHz mono PCM16 from the recorder's sample-buffer queue.
    func append(_ chunk: Data) {
        guard !isStopped else { return }
        queue.async { [weak self] in self?.handle(chunk) }
    }

    func stop() {
        stopped.withLock { $0 = true }
        queue.async { [weak self] in
            guard let self else { return }
            self.requests.forEach { $0.cancel() }
            self.requests = []
            self.recent = Data()
        }
    }

    private func handle(_ chunk: Data) {
        guard !isStopped, !chunk.isEmpty else { return }
        recent = LanguageProbeCore.trimmedToWindow(recent + chunk)
        let seconds = Double(chunk.count) / Double(LanguageProbePlan.bytesPerSecond)
        let step = plan.adding(chunkSeconds: seconds, rms: LanguageProbeCore.rms(ofPCM16: chunk))
        plan = step.plan
        guard step.shouldProbe else { return }
        guard !Self.isPausedForRateLimit else {
            plan = plan.finishingProbe()
            return
        }
        send(clip: recent)
    }

    private func send(clip: Data) {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: config.endpoint, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = LanguageProbeCore.multipartBody(
            wav: LanguageProbeCore.wav(pcm16: clip),
            model: config.model,
            responseFormat: TranscriptionService.responseFormat(forModel: config.model),
            boundary: boundary
        )
        let task = Task { [weak self] in
            let look = await Self.detectLook(for: request)
            self?.queue.async { [weak self] in self?.finish(with: look) }
        }
        requests.append(task)
    }

    private func finish(with look: SpokenLook?) {
        plan = plan.finishingProbe()
        guard !isStopped, let look else { return }
        DispatchQueue.main.async { [weak self] in
            // Checked again on main: `stop()` may have run while this hop was queued.
            guard let self, !self.isStopped else { return }
            self.onLook(look)
        }
    }

    /// Sends one clip. Errors are logged and return nil: a failed check just keeps the look.
    private static func detectLook(for request: URLRequest) async -> SpokenLook? {
        do {
            let (data, response) = try await LLMAPITransport.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 {
                pausedUntil.withLock { $0 = Date().addingTimeInterval(rateLimitBackoff) }
                os_log(.info, log: probeLog, "language check rate limited; pausing checks for %.0fs", rateLimitBackoff)
                return nil
            }
            guard (200..<300).contains(status), let parsed = LanguageProbeCore.parseResponse(data) else {
                os_log(.info, log: probeLog, "language check failed with HTTP %d", status)
                return nil
            }
            os_log(.info, log: probeLog, "language check: %{public}@", parsed.language ?? "no language field")
            return LanguageProbeCore.look(language: parsed.language, text: parsed.text)
        } catch is CancellationError {
            return nil
        } catch {
            os_log(.info, log: probeLog, "language check error: %{public}@", error.localizedDescription)
            return nil
        }
    }
}
