import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Two rings behind one lock: what the call said (system audio) and what the owner said (mic).
/// Audio lives only here, in memory.
final class RioMeetingBuffers: @unchecked Sendable {
    private let lock = NSLock()
    private var system: RioAudioRing
    private var mic: RioAudioRing

    init(seconds: Int) {
        system = RioAudioRing(capacitySeconds: seconds)
        mic = RioAudioRing(capacitySeconds: seconds)
    }

    func appendSystem(_ pcm: Data) {
        lock.lock()
        system.append(pcm)
        lock.unlock()
    }

    func appendMic(_ pcm: Data) {
        lock.lock()
        mic.append(pcm)
        lock.unlock()
    }

    /// The last `seconds` of both streams mixed to 16 kHz mono PCM16.
    func mixed(seconds: Double) -> Data {
        lock.lock()
        let a = system.last(seconds: seconds)
        let b = mic.last(seconds: seconds)
        lock.unlock()
        return RioAudioMix.mix(a, b)
    }

    func wipe() {
        lock.lock()
        system.reset()
        mic.reset()
        lock.unlock()
    }
}

/// System audio through a ScreenCaptureKit audio stream (needs Screen and System Audio
/// Recording permission). Rio's own sound is excluded. Audio never touches disk.
final class RioSystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Unavailable: Error {}

    private let queue = DispatchQueue(label: "com.zachlatta.freeflow.meeting-system-audio")
    private let onAudio: @Sendable (Data) -> Void
    private let onStopped: @Sendable () -> Void
    private var stream: SCStream?

    init(onAudio: @escaping @Sendable (Data) -> Void, onStopped: @escaping @Sendable () -> Void) {
        self.onAudio = onAudio
        self.onStopped = onStopped
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw Unavailable() }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = RioSpeechChunker.sampleRate
        configuration.channelCount = 1
        // Audio only in practice: the picture is a 2x2 frame once a second, and is dropped.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(
            filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: self
        )
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        let current = stream
        stream = nil
        Task { try? await current?.stopCapture() }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let data = Self.pcm16(from: sampleBuffer) else { return }
        onAudio(data)
    }

    /// Any common PCM layout (float or 16-bit, interleaved or not, any rate) to 16 kHz mono PCM16.
    private static func pcm16(from buffer: CMSampleBuffer) -> Data? {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mFormatID == kAudioFormatLinearPCM else { return nil }
        var needed = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil
        )
        guard needed > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: needed,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block
        )
        guard status == noErr else { return nil }
        let channels = floatChannels(UnsafeMutableAudioBufferListPointer(list), description)
        guard !channels.isEmpty else { return nil }
        let mono = RioPCMConvert.downmix(channels)
        let resampled = RioPCMConvert.resample(mono, from: Int(description.mSampleRate), to: RioSpeechChunker.sampleRate)
        return RioPCMConvert.data(RioPCMConvert.int16(resampled))
    }

    private static func floatChannels(
        _ buffers: UnsafeMutableAudioBufferListPointer, _ format: AudioStreamBasicDescription
    ) -> [[Float]] {
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isNonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bytesPerSample = Int(format.mBitsPerChannel / 8)
        guard bytesPerSample == (isFloat ? 4 : 2) else { return [] }
        func samples(_ audio: AudioBuffer) -> [Float] {
            guard let data = audio.mData else { return [] }
            let count = Int(audio.mDataByteSize) / bytesPerSample
            if isFloat {
                return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
            }
            return UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: count).map { Float($0) / 32768 }
        }
        if isNonInterleaved { return buffers.map(samples) }
        guard let first = buffers.first else { return [] }
        let all = samples(first)
        let channelCount = max(1, Int(format.mChannelsPerFrame))
        guard channelCount > 1 else { return [all] }
        return (0..<channelCount).map { channel in
            stride(from: channel, to: all.count, by: channelCount).map { all[$0] }
        }
    }
}

/// The microphone as 16 kHz mono PCM16. Audio never touches disk.
final class RioMeetingMicTap: @unchecked Sendable {
    struct Unavailable: Error {}

    private let engine = AVAudioEngine()
    private let onAudio: @Sendable (Data) -> Void

    init(onAudio: @escaping @Sendable (Data) -> Void) {
        self.onAudio = onAudio
    }

    func start() throws {
        guard !engine.isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: Double(RioSpeechChunker.sampleRate), channels: 1, interleaved: true
              ),
              let converter = AVAudioConverter(from: format, to: target) else { throw Unavailable() }
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
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
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
        onAudio(Data(bytes: samples, count: Int(out.frameLength) * 2))
    }
}
