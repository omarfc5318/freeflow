import AVFoundation
import Foundation

/// Lossless FLAC copy of a recording for upload: the same samples in roughly half the bytes.
enum FLACUploadAudio {
    enum EncodingError: Error {
        case unsupportedFormat
        case unreadable
    }

    /// Apple's FLAC encoder writes whole 1,024-sample packets and drops a trailing partial one,
    /// so the audio is padded with silence past that boundary to keep every recorded sample.
    private static let packetFrames = 1_024

    /// Writes the copy to the temporary directory; the caller deletes it after uploading.
    static func flacCopy(of url: URL) throws -> URL {
        let input = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
        let format = input.processingFormat
        guard format.channelCount == 1, format.commonFormat == .pcmFormatInt16 else {
            throw EncodingError.unsupportedFormat
        }
        let frames = Int(input.length)
        let paddedFrames = (frames / packetFrames + 2) * packetFrames
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(paddedFrames)) else {
            throw EncodingError.unreadable
        }
        try input.read(into: buffer)
        guard let channel = buffer.int16ChannelData?[0] else { throw EncodingError.unreadable }
        channel.advanced(by: Int(buffer.frameLength))
            .initialize(repeating: 0, count: paddedFrames - Int(buffer.frameLength))
        buffer.frameLength = AVAudioFrameCount(paddedFrames)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString).flac")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16
        ]
        do {
            // The file is finished when `output` goes out of scope, before it is read back.
            let output = try AVAudioFile(
                forWriting: outputURL, settings: settings,
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
