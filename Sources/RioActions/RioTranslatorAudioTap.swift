import AVFoundation
import Foundation

/// Opens the microphone, converts it to 16 kHz mono PCM16 and cuts it into speech chunks.
/// Audio never touches disk; chunks go to `onChunk` and nowhere else. `@unchecked Sendable`:
/// the chunker lives on `queue`, the engine is only started and stopped from the main actor.
final class RioTranslatorAudioTap: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.zachlatta.freeflow.translator-audio")
    private let onChunk: @Sendable (RioSpeechChunk) -> Void
    private let onConfigurationChange: @Sendable () -> Void
    private var chunker = RioSpeechChunker()  // touched only on `queue`
    private var observer: NSObjectProtocol?

    struct Unavailable: Error {}

    init(onChunk: @escaping @Sendable (RioSpeechChunk) -> Void, onConfigurationChange: @escaping @Sendable () -> Void) {
        self.onChunk = onChunk
        self.onConfigurationChange = onConfigurationChange
    }

    var isRunning: Bool { engine.isRunning }

    func start() throws {
        guard !engine.isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: Double(RioSpeechChunker.sampleRate), channels: 1, interleaved: true
              ),
              let converter = AVAudioConverter(from: format, to: target) else { throw Unavailable() }
        queue.async { [weak self] in self?.chunker = RioSpeechChunker() }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            self?.handle(buffer, converter: converter, target: target)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in self?.onConfigurationChange() }
    }

    /// Closes the microphone and drops any half-heard speech.
    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        queue.async { [weak self] in self?.chunker = RioSpeechChunker() }
    }

    private func handle(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, target: AVAudioFormat) {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }
        let data = Data(bytes: samples, count: Int(out.frameLength) * 2)
        queue.async { [weak self] in
            guard let self else { return }
            for chunk in self.chunker.feed(data) { self.onChunk(chunk) }
        }
    }
}
