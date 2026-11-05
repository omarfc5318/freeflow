import AVFoundation
import Foundation
import os
import Speech

/// Conversation-mode decisions only (word counts, never words), at info level, so they stay in
/// memory and show only in `log stream --level info --predicate 'category == "Conversation"'`.
let rioConversationLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "Conversation")

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
    /// Replace the recognition task before Apple's ~1 minute limit.
    static let taskLifetime: TimeInterval = 50
    private static let maxConsecutiveFailures = 5
    /// Speech heard before the recognizer first shows "Rio" (partial results lag the voice).
    private static let commandLeadSeconds = 1.5
    /// Sound this recent means the owner is still talking: the utterance doesn't end yet.
    static let stillTalkingSeconds: TimeInterval = 0.8
    /// ...but a noisy room can't keep an utterance open for more than this past the silence timer.
    static let maxTalkingExtension: TimeInterval = 3
    /// A command ends this long after it started even if speech goes on around it, so people
    /// talking nearby can't keep growing it (spoken commands take 1 to 3 seconds).
    static let maxCommandSeconds: TimeInterval = 5

    private let onCommand: @MainActor (String) -> Void
    /// Called when the listener stops ON ITS OWN (repeated recognizer failures, the microphone
    /// could not be reopened), with a user-facing reason, so conversation mode never keeps
    /// claiming to listen. Not called for a stop the owner of the listener asked for.
    var onStopped: (@MainActor (String) -> Void)?
    /// Called once when Rio hears just his name ("Rio" and a pause), so the owner of the
    /// listener can give a quick "yes?" cue while the listener waits for the command.
    var onBareName: (@MainActor () -> Void)?
    /// Whether a bare "Rio" may open the command window now (false while Rio is talking or just
    /// after; see `WakeListenTiming.bareNameOpensWindow`). Nil means always.
    var bareNameMayOpenWindow: (@MainActor () -> Bool)?
    /// What Rio's own voice is saying or just said (nil when he is quiet), so his words in front
    /// of the owner's "Rio" don't hide the name (`RioConversationEcho`).
    var echoReference: (@MainActor () -> String?)?
    /// Called as soon as a command starts to come in (before it is finished), so Rio can stop
    /// talking and the rest of his sentence doesn't run into the command.
    var onCommandStarted: (@MainActor (String) -> Void)?
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
    /// Finals with no words in a row; each one doubles the wait before listening again.
    private var consecutiveEmptyFinals = 0
    private var lastHeardText = ""
    /// When this recognition task heard a bare "Rio" (nothing after it yet).
    private var bareNameHeardAt: Date?
    /// Until when the next utterance counts as the command even without the name, after a
    /// bare "Rio" whose recognition task ended before the command came.
    private var commandExpectedUntil: Date?
    private var silenceTimer: Task<Void, Never>?
    /// When the silence timer first found the owner still talking (nil otherwise).
    private var talkingExtendedSince: Date?
    /// When the current command first showed up (nil when none is coming in).
    private var commandStartedAt: Date?
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
        os_log(.info, log: rioConversationLog, "paused")
        isPaused = true
        tearDown()
    }

    func resume() {
        guard wantsListening, isPaused else { return }
        os_log(.info, log: rioConversationLog, "resumed")
        isPaused = false
        do {
            try startAudio()
        } catch {
            stopItself("I couldn't reopen the microphone, so I stopped listening")
        }
    }

    /// Rio's own voice just started or stopped: start a fresh recognition task so what he said
    /// and what the owner says next are separate utterances. Measured 2026-11-04: right after
    /// he spoke, "Rio, what is 7 times 8" came out as "You got it it's what is 7×8"; his words
    /// in the same stream swallowed the name. A command already coming in is left alone.
    func startFreshUtterance() {
        guard wantsListening, !isPaused, engine.isRunning, pendingCommand == nil, bareNameHeardAt == nil else { return }
        os_log(.info, log: rioConversationLog, "fresh utterance at Rio's speech boundary")
        beginRecognitionTask()
    }

    /// Stops because something failed and says so (see `onStopped`).
    private func stopItself(_ reason: String) {
        guard wantsListening else { return }
        stop()
        onStopped?(reason)
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
        os_log(.info, log: rioConversationLog, "audio device configuration changed")
        guard wantsListening, !isPaused else { return }
        tearDown()
        do {
            try startAudio()
        } catch {
            stopItself("I lost the microphone, so I stopped listening")
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
        talkingExtendedSince = nil
        requestBox.replace(with: nil)
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    // MARK: Recognition

    /// Starts a fresh recognition task on the running engine, discarding the old one. With
    /// `replayingPreRoll`, the audio kept during an empty-final wait goes in first.
    private func beginRecognitionTask(replayingPreRoll: Bool = false) {
        generation += 1
        os_log(.info, log: rioConversationLog, "recognition task %d started (pre-roll: %d, engine running: %d)", generation, replayingPreRoll ? 1 : 0, engine.isRunning ? 1 : 0)
        let current = generation
        silenceTimer?.cancel()
        lifetimeTimer?.cancel()
        pendingCommand = nil
        commandAudioMark = nil
        lastHeardText = ""
        bareNameHeardAt = nil
        talkingExtendedSince = nil
        commandStartedAt = nil
        task?.cancel()
        task = nil
        guard let recognizer else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        request.contextualStrings = ["Rio", "Hey Rio"]
        if #available(macOS 13.0, *) { request.addsPunctuation = false }
        requestBox.replace(with: request, replayingPreRoll: replayingPreRoll)

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let timed = result?.bestTranscription.segments.map {
                WakePhraseExtractor.TimedWord(text: $0.substring, start: $0.timestamp, duration: $0.duration)
            } ?? []
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                self?.handleResult(generation: current, text: text, timed: timed, isFinal: isFinal, failed: failed)
            }
        }
        lifetimeTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.taskLifetime * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.lifetimeElapsed(generation: current)
        }
    }

    private func handleResult(
        generation: Int, text: String?, timed: [WakePhraseExtractor.TimedWord], isFinal: Bool, failed: Bool
    ) {
        guard generation == self.generation, wantsListening, !isPaused else { return }
        if isFinal || failed { os_log(.info, log: rioConversationLog, "task %d ended (final: %d, failed: %d, has text: %d)", generation, isFinal ? 1 : 0, failed ? 1 : 0, (text ?? "").isEmpty ? 0 : 1) }
        if let rawText = text {
            consecutiveFailures = 0
            if !rawText.isEmpty { consecutiveEmptyFinals = 0 }
            // Rio's own words in front of the owner's "Rio" (he just spoke) are not the start of
            // the utterance; timing is ignored then, the plain text already starts at the name.
            let reference = echoReference?()
            let text = RioConversationEcho.strippingLeadingEcho(rawText, reference: reference)
            let words = reference == nil ? timed : []
            if rawText != lastHeardText {
                os_log(.info, log: rioConversationLog, "heard %d words (%d after removing Rio's echo), echo line known: %d, final: %d",
                       rawText.split(separator: " ").count, text.split(separator: " ").count, reference == nil ? 0 : 1, isFinal ? 1 : 0)
            }
            // The name after a pause counts even when room speech ran into the same utterance.
            let withPauses = words.isEmpty ? text : WakePhraseExtractor.transcript(from: words)
            if let command = command(in: text, timed: words), command != pendingCommand {
                if pendingCommand == nil {
                    os_log(.info, log: rioConversationLog, "command started")
                    commandStartedAt = Date()
                    commandAudioMark = requestBox.mark(secondsBack: Self.commandLeadSeconds)
                    onCommandStarted?(command)
                }
                pendingCommand = command
                commandExpectedUntil = nil
                scheduleSilenceTimer(generation: generation, after: min(
                    WakeListenTiming.silenceToEnd(pendingCommand: command), max(0.2, commandTimeLeft())
                ))
            } else if pendingCommand == nil, WakePhraseExtractor.isBareName(withPauses),
                      bareNameHeardAt != nil || bareNameMayOpenWindow?() ?? true {
                // "Rio" and a thinking pause: keep listening for the command instead of ending
                // the utterance after the usual short silence.
                if bareNameHeardAt == nil {
                    bareNameHeardAt = Date()
                    onBareName?()
                }
                if rawText != lastHeardText { scheduleSilenceTimer(generation: generation, after: WakeListenTiming.bareNameWindow) }
            } else if pendingCommand == nil, rawText != lastHeardText {
                // Speech without the name: a pause ends the utterance, so the next "Rio" starts
                // a fresh one (the name only counts at the start of an utterance).
                scheduleSilenceTimer(generation: generation, after: WakeListenTiming.silenceWithoutCommand)
            }
            lastHeardText = rawText
        }
        if isFinal {
            if pendingCommand == nil && (text ?? "").isEmpty {
                restartAfterEmptyFinal()
            } else {
                finishUtteranceAndRestart()
            }
        } else if failed {
            recover()
        }
    }

    /// The command in what was heard: after the name (also after a pause mid-transcript), or the
    /// whole utterance shortly after a bare "Rio" from the previous utterance.
    private func command(in text: String, timed: [WakePhraseExtractor.TimedWord]) -> String? {
        if let command = WakePhraseExtractor.command(in: text) { return command }
        if !timed.isEmpty, let command = WakePhraseExtractor.command(in: timed) { return command }
        guard let until = commandExpectedUntil, Date() < until, !WakePhraseExtractor.isBareName(text) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return trimmed.contains { $0.isLetter || $0.isNumber } ? trimmed : nil
    }

    private func scheduleSilenceTimer(generation: Int, after seconds: TimeInterval) {
        silenceTimer?.cancel()
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.silenceElapsed(generation: generation)
        }
    }

    private func silenceElapsed(generation: Int) {
        guard generation == self.generation, wantsListening, !isPaused else { return }
        // The recognizer lags the voice: while the microphone still hears speech, the owner is
        // mid-sentence even if no new words have shown up yet.
        if requestBox.secondsSinceSound() < Self.stillTalkingSeconds, commandTimeLeft() > 0 {
            let since = talkingExtendedSince ?? Date()
            talkingExtendedSince = since
            if Date().timeIntervalSince(since) < Self.maxTalkingExtension {
                scheduleSilenceTimer(generation: generation, after: 0.4)
                return
            }
        }
        finishUtteranceAndRestart()
    }

    /// Seconds before the current command must end (infinite when no command is coming in).
    private func commandTimeLeft() -> TimeInterval {
        guard let commandStartedAt else { return .infinity }
        return Self.maxCommandSeconds - Date().timeIntervalSince(commandStartedAt)
    }

    private func lifetimeElapsed(generation: Int) {
        guard generation == self.generation, wantsListening, !isPaused else { return }
        finishUtteranceAndRestart()
    }

    /// Hands over the finished command (if any), then starts a clean recognition task so the
    /// old words can't come back.
    private func finishUtteranceAndRestart() {
        let command = pendingCommand
        let mark = commandAudioMark
        // A bare "Rio" whose utterance ended early (the recognizer's own final, the task's
        // lifetime): the next utterance within the window is the command.
        if command == nil, let heardAt = bareNameHeardAt {
            commandExpectedUntil = heardAt.addingTimeInterval(WakeListenTiming.bareNameWindow)
        } else if command != nil {
            commandExpectedUntil = nil
        }
        pendingCommand = nil
        commandAudioMark = nil
        beginRecognitionTask()
        guard let command else { return }
        deliver(command, mark: mark)
    }

    /// Hands the command over. Arabic after "Rio" comes out as nonsense from the English
    /// recognizer: that command's audio is read again with Whisper when the text doesn't look
    /// like a command.
    private func deliver(_ command: String, mark: Int?) {
        os_log(.info, log: rioConversationLog, "command finished: %d words", command.split(separator: " ").count)
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

    /// A final result with no words (silence): wait (`WakeListenTiming.emptyFinalDelay`: fast
    /// at first, then backing off to a few seconds) instead of restarting recognition in a tight
    /// loop, and listen again at once when sustained sound arrives, so a "Rio" said in a quiet
    /// room is not missed while a fan or a key click doesn't keep the recognizer churning. The
    /// audio heard during the wait (up to `WakeListenTiming.preRollSeconds`) is replayed into the
    /// new recognition, so the start of what woke it ("Rio") is not clipped. Memory only.
    private func restartAfterEmptyFinal() {
        consecutiveEmptyFinals += 1
        let delay = WakeListenTiming.emptyFinalDelay(consecutive: consecutiveEmptyFinals)
        os_log(.info, log: rioConversationLog, "empty final #%d, waiting up to %.1f s for sound", consecutiveEmptyFinals, delay)
        let current = generation
        silenceTimer?.cancel()
        task?.cancel()
        task = nil
        _ = requestBox.takeHeardSound()
        requestBox.keepPreRoll(seconds: WakeListenTiming.preRollSeconds)
        Task { [weak self] in
            // Check for sound often while the wait is short, less often once it has backed off.
            let step: TimeInterval = delay > 1 ? 0.1 : 0.05
            var waited: TimeInterval = 0
            while waited < delay {
                try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                waited += step
                guard let self, current == self.generation else { return }
                if self.requestBox.takeHeardSound() {
                    self.consecutiveEmptyFinals = 0
                    break
                }
            }
            guard let self, current == self.generation, self.wantsListening, !self.isPaused else { return }
            self.beginRecognitionTask(replayingPreRoll: true)
        }
    }

    /// The recognizer failed (not by our own cancel): retry, and give up after repeated failures.
    private func recover() {
        consecutiveFailures += 1
        os_log(.info, log: rioConversationLog, "recognizer failed (%d in a row)", consecutiveFailures)
        if consecutiveFailures > Self.maxConsecutiveFailures {
            stopItself("Speech recognition kept failing, so I stopped listening")
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
    private var ring = [Int16](repeating: 0, count: recentSeconds * 16_000)
    private var ringHead = 0 // next write position
    private var ringCount = 0
    private var written = 0
    private var recentRate = 16_000
    /// Set when sustained sound arrives (`WakeSoundGate`, not one loud sample); read and
    /// cleared by the listener.
    private var heardSound = false
    private var soundGate = WakeSoundGate()
    /// System uptime of the last loud buffer (0: none yet).
    private var lastSoundUptime: TimeInterval = 0
    /// While the listener waits after an empty final: copies of the latest tap buffers (at most
    /// `preRollLimit` seconds), replayed into the next request. Empty and off otherwise.
    private var preRoll: [AVAudioPCMBuffer] = []
    private var preRollFrames: Double = 0
    private var preRollLimit: Double = 0

    /// `replayingPreRoll` feeds the kept audio to `newRequest` first. Either way the kept audio
    /// is dropped and keeping stops.
    func replace(with newRequest: SFSpeechAudioBufferRecognitionRequest?, replayingPreRoll: Bool = false) {
        lock.lock()
        let old = request
        request = newRequest
        if replayingPreRoll, let newRequest { preRoll.forEach { newRequest.append($0) } }
        preRoll = []
        preRollFrames = 0
        preRollLimit = 0
        lock.unlock()
        old?.endAudio()
    }

    /// Starts keeping the last `seconds` of microphone audio for `replace(with:replayingPreRoll:)`.
    func keepPreRoll(seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        preRoll = []
        preRollFrames = 0
        preRollLimit = seconds
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        request?.append(buffer)
        keepRecent(buffer)
        storePreRoll(buffer)
        lock.unlock()
    }

    /// Caller holds the lock.
    private func storePreRoll(_ buffer: AVAudioPCMBuffer) {
        guard preRollLimit > 0, buffer.format.sampleRate > 0, let copy = Self.copy(buffer) else { return }
        preRoll.append(copy)
        preRollFrames += Double(copy.frameLength)
        let limit = preRollLimit * buffer.format.sampleRate
        while preRollFrames > limit, preRoll.count > 1 {
            preRollFrames -= Double(preRoll.removeFirst().frameLength)
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let fromData = from.mData, let toData = to.mData else { return nil }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }

    /// True when sound (not silence) arrived since the last call.
    func takeHeardSound() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let heard = heardSound
        heardSound = false
        return heard
    }

    /// Seconds since the microphone last heard sustained sound (infinite before any).
    func secondsSinceSound() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard lastSoundUptime > 0 else { return .infinity }
        return ProcessInfo.processInfo.systemUptime - lastSoundUptime
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
        let start = max(mark, written - ringCount)
        let count = written - start
        guard count >= recentRate / 3 else { return nil }
        var data = Data(capacity: count * 2)
        var index = (ringHead - count + ring.count * 2) % ring.count
        for _ in 0..<count {
            withUnsafeBytes(of: ring[index].littleEndian) { data.append(contentsOf: $0) }
            index = (index + 1) % ring.count
        }
        return (data, recentRate)
    }

    /// Caller holds the lock. Averages down to about 16 kHz into a fixed ring (no shifting).
    private func keepRecent(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let step = max(1, Int(buffer.format.sampleRate / 16_000))
        let rate = Int(buffer.format.sampleRate) / step
        if rate != recentRate {
            recentRate = rate
            ring = [Int16](repeating: 0, count: Self.recentSeconds * max(rate, 1))
            ringHead = 0
            ringCount = 0
        }
        let frames = Int(buffer.frameLength)
        var index = 0
        var squares: Float = 0
        var kept = 0
        while index + step <= frames {
            var sum: Float = 0
            for offset in 0..<step { sum += channel[index + offset] }
            let sample = max(-1, min(1, sum / Float(step)))
            squares += sample * sample
            kept += 1
            ring[ringHead] = Int16(sample * 32_767)
            ringHead = (ringHead + 1) % ring.count
            ringCount = min(ringCount + 1, ring.count)
            index += step
            written += 1
        }
        if kept > 0 {
            let rms = (squares / Float(kept)).squareRoot()
            if soundGate.feed(rms: rms, seconds: Double(frames) / max(buffer.format.sampleRate, 1)) {
                heardSound = true
                lastSoundUptime = ProcessInfo.processInfo.systemUptime
            }
        }
    }
}
