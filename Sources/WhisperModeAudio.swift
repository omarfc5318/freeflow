import AVFoundation
import Foundation

/// Produces the whisper-mode version of a finished recording for transcription.
/// The original recording (kept in the run log for replay and retry) is never modified.
enum WhisperModeAudio {
    enum BoostError: Error {
        case unsupportedFormat
        case unreadable
    }

    /// Writes a boosted copy to the temporary directory and returns its URL, or nil when the
    /// recording is already loud enough. The caller deletes the copy after transcribing it.
    static func boostedCopy(of url: URL) throws -> URL? {
        let input = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
        let format = input.processingFormat
        guard format.channelCount == 1, format.commonFormat == .pcmFormatInt16 else {
            throw BoostError.unsupportedFormat
        }
        let frameCount = AVAudioFrameCount(input.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        try input.read(into: buffer)
        guard let channel = buffer.int16ChannelData?[0] else { throw BoostError.unreadable }

        let result = WhisperBoostCore.boost(Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
        guard result.gainDecibels > 0 else { return nil }
        for (index, sample) in result.samples.enumerated() { channel[index] = sample }

        let extensionName = url.pathExtension.isEmpty ? "wav" : url.pathExtension
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-mode-\(UUID().uuidString).\(extensionName)")
        do {
            // The file is closed when `output` goes out of scope, before it is transcribed.
            let output = try AVAudioFile(
                forWriting: outputURL, settings: input.fileFormat.settings,
                commonFormat: .pcmFormatInt16, interleaved: false
            )
            try output.write(from: buffer)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        return outputURL
    }
}
