import AVFoundation
import Foundation
import Speech

enum WakeWordListenerStartResult: Equatable {
    case started
    case permissionDenied
    /// `String` is user-facing: why listening can't run.
    case unavailable(String)
}

/// Always-on "Rio" listening for conversation mode. Strictly on-device: it refuses to run
/// unless the recognizer can work without the network, so audio never leaves the Mac.
/// It keeps no transcript: speech without the name is dropped on the spot, and only the text
/// after "Rio" is handed to `onCommand`.
///
/// One AVAudioEngine tap runs for the whole session. The recognition task is replaced (not
/// the engine) after each command, after an error, and every `taskLifetime` seconds, so it
/// never hits Apple's roughly one-minute task limit.
@MainActor final class WakeWordListener {
    /// Silence after the last new word that ends a command.
    static let silenceToEndCommand: TimeInterval = 1.2
    /// Replace the recognition task before Apple's ~1 minute limit.
    static let taskLifetime: TimeInterval = 50
    private static let maxConsecutiveFailures = 5
    /// Speech heard before the recognizer first shows "Rio" (partial results lag the voice).
    private static let commandLeadSeconds = 1.5

    private let onCommand: @MainActor (String) -> Void
    private let engine = AVAudioEngine()
    private let requestBox = RecognitionRequestBox()
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var wantsListening = false
    private var isPaused = false
    private var pendingCommand: String?
    /// Where in the recent audio the command began (for the Arabic second listen).
    private var commandAudioMark: Int?
    private var consecutiveFailures = 0
    private var silenceTimer: Task<Void, Never>?
    private var lifetimeTimer: Task<Void, Never>?
    private var configObserver: NSObjectProtocol?

    init(onCommand: @escaping @MainActor (String) -> Void) {
        self.onCommand = onCommand
    }

    /// True while the microphone is open and recognition is running.
    var isListening: Bool { wantsListening && !isPaused && engine.isRunning }

    /// Asks for speech and microphone permission if needed (the only place that does), then
    /// starts listening.
    func start() async -> WakeWordListenerStartResult {
        if wantsListening { return .started }
        guard await Self.hasPermissions() else { return .permissionDenied }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            return .unavailable("Speech recognition isn't available for English on this Mac")
        }
        guard recognizer.isAvailable else {
            return .unavailable("Speech recognition isn't available right now")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            return .unavailable("On-device speech recognition isn't installed, so Rio won't listen (nothing may leave your Mac)")
        }
        self.recognizer = recognizer
        do {
            try startAudio()
        } catch {
            self.recognizer = nil
            return .unavailable("I couldn't open the microphone")
        }
        wantsListening = true
        isPaused = false
        consecutiveFailures = 0
        return .started
    }

    func stop() {
        wantsListening = false
        isPaused = false
        tearDown()
        recognizer = nil
    }

    /// Releases the microphone so dictation can use it. Anything heard but not yet finished
    /// is dropped.
    func pause() {
        guard wantsListening, !isPaused else { return }
        isPaused = true
        tearDown()
    }

    func resume() {
        guard wantsListening, isPaused else { return }
        isPaused = false
        do {
            try startAudio()
        } catch {
            stop()
        }
    }

    // MARK: Permissions

    private static func hasPermissions() async -> Bool {
        var speech = SFSpeechRecognizer.authorizationStatus()
        if speech == .notDetermined {
            speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard speech == .authorized else { return false }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: Audio engine

    private struct AudioUnavailable: Error {}

    private func startAudio() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioUnavailable() }
        input.removeTap(onBus: 0)
        let box = requestBox
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in box.append(buffer) }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.audioConfigurationChanged() }
        }
        beginRecognitionTask()
    }

    /// The input device changed (headphones, another mic): reopen the engine.
    private func audioConfigurationChanged() {
        guard wantsListening, !isPaused else { return }
        tearDown()
        do {
            try startAudio()
        } catch {
            stop()
        }
    }

    private func tearDown() {
        generation += 1
        silenceTimer?.cancel()
        lifetimeTimer?.cancel()
        silenceTimer = nil
        lifetimeTimer = nil
        pendingCommand = nil
        task?.cancel()
        task = nil
        requestBox.replace(with: nil)
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    // MARK: Recognition

    /// Starts a fresh recognition task on the running engine, discarding the old one.
    private func beginRecognitionTask() {
        generation += 1
        let current = generation
        silenceTimer?.cancel()
        lifetimeTimer?.cancel()
        pendingCommand = nil
        commandAudioMark = nil
        task?.cancel()
        task = nil
        guard let recognizer else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        request.contextualStrings = ["Rio", "Hey Rio"]
        if #available(macOS 13.0, *) { request.addsPunctuation = false }
        requestBox.replace(with: request)

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                self?.handleResult(generation: current, text: text, isFinal: isFinal, failed: failed)
            }
        }
        lifetimeTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.taskLifetime * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.lifetimeElapsed(generation: current)
        }
    }

    private func handleResult(generation: Int, text: String?, isFinal: Bool, failed: Bool) {
        guard generation == self.generation, wantsListening, !isPaused else { return }
        if let text {
            consecutiveFailures = 0
            if let command = WakePhraseExtractor.command(in: text), command != pendingCommand {
                if pendingCommand == nil { commandAudioMark = requestBox.mark(secondsBack: Self.commandLeadSeconds) }
                pendingCommand = command
                scheduleSilenceTimer(generation: generation)
            }
        }
        if isFinal {
            finishCommandAndRestart()
        } else if failed {
            recover()
        }
    }

    private func scheduleSilenceTimer(generation: Int) {
        silenceTimer?.cancel()
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.silenceToEndCommand * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.silenceElapsed(generation: generation)
        }
    }

    private func silenceElapsed(generation: Int) {
        guard generation == self.generation, wantsListening, !isPaused else { return }
        finishCommandAndRestart()
    }

    private func lifetimeElapsed(generation: Int) {
        guard generation == self.generation, wantsListening, !isPaused else { return }
        finishCommandAndRestart()
    }

    /// Hands over the finished command (if any), then starts a clean recognition task so the
    /// old words can't come back.
    private func finishCommandAndRestart() {
        let command = pendingCommand
        let mark = commandAudioMark
        pendingCommand = nil
        commandAudioMark = nil
        beginRecognitionTask()
        guard let command else { return }
        // Arabic after "Rio" comes out as nonsense from the English recognizer: read that
        // command's audio again with Whisper when the text doesn't look like a command.
        guard let mark, RioCommandAudioRecheck.isAvailable(forOnDeviceText: command),
              let audio = requestBox.recentAudio(since: mark) else {
            onCommand(command)
            return
        }
        Task { @MainActor [weak self] in
            let better = await RioCommandAudioRecheck.transcribe(pcm16: audio.pcm16, sampleRate: audio.sampleRate)
            guard let self, self.wantsListening, !self.isPaused else { return }
            self.onCommand(better ?? command)
        }
    }

    /// The recognizer failed (not by our own cancel): retry, and give up after repeated failures.
    private func recover() {
        consecutiveFailures += 1
        if consecutiveFailures > Self.maxConsecutiveFailures {
            stop()
            return
        }
        let delay = min(0.5 * Double(consecutiveFailures), 3)
        let current = generation
        pendingCommand = nil
        silenceTimer?.cancel()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, current == self.generation, self.wantsListening, !self.isPaused else { return }
            self.beginRecognitionTask()
        }
    }
}

/// The audio tap runs on a realtime thread, so it reaches the current request through a lock
/// instead of through the main-actor listener.
private final class RecognitionRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    // A short rolling copy of the microphone (mono PCM16, about 16 kHz), in memory only, so a
    // command's audio can be read again. `written` counts samples since the engine started.
    private static let recentSeconds = 12
    private var recent: [Int16] = []
    private var written = 0
    private var recentRate = 16_000

    func replace(with newRequest: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        let old = request
        request = newRequest
        lock.unlock()
        old?.endAudio()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        request?.append(buffer)
        keepRecent(buffer)
        lock.unlock()
    }

    /// A position `secondsBack` before now, for `recentAudio(since:)`.
    func mark(secondsBack: Double) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return max(0, written - Int(secondsBack * Double(recentRate)))
    }

    /// Audio from `mark` to now, or nil when it is too short or has already scrolled out.
    func recentAudio(since mark: Int) -> (pcm16: Data, sampleRate: Int)? {
        lock.lock()
        defer { lock.unlock() }
        let start = max(mark, written - recent.count)
        let count = written - start
        guard count >= recentRate / 3 else { return nil }
        var data = Data(capacity: count * 2)
        for sample in recent.suffix(count) {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return (data, recentRate)
    }

    /// Caller holds the lock. Averages down to about 16 kHz and keeps the last few seconds.
    private func keepRecent(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let step = max(1, Int(buffer.format.sampleRate / 16_000))
        let rate = Int(buffer.format.sampleRate) / step
        if rate != recentRate {
            recent = []
            recentRate = rate
        }
        let frames = Int(buffer.frameLength)
        var index = 0
        while index + step <= frames {
            var sum: Float = 0
            for offset in 0..<step { sum += channel[index + offset] }
            recent.append(Int16(max(-1, min(1, sum / Float(step))) * 32_767))
            index += step
            written += 1
        }
        let limit = Self.recentSeconds * recentRate
        if recent.count > limit { recent.removeFirst(recent.count - limit) }
    }
}
