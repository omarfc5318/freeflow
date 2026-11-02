import Foundation

/// Live language checks while you dictate: when to send a short clip of recent speech to
/// Whisper, and how to read its answer. Pure values, so the timing rules are testable.
struct LanguageProbePlan: Equatable {
    /// The recorder's live PCM16 tap: 24 kHz mono, 2 bytes per sample.
    static let sampleRate = 24_000
    static let bytesPerSecond = sampleRate * 2
    /// Speech heard before the first check: enough for Whisper to tell the language apart.
    static let firstProbeVoicedSeconds = 1.4
    /// Speech heard between later checks, which catch a switch of language mid-dictation.
    static let laterProbeVoicedSeconds = 3.5
    /// How much recent audio each check sends.
    static let windowSeconds = 3.0
    /// Checks per dictation, so long dictations stay well inside the provider's rate limit.
    static let maxProbes = 5
    /// A chunk at or above this RMS (about -40 dBFS) counts as speech. Silence is never sent:
    /// Whisper invents text (often Arabic) for silent clips.
    static let speechRMS: Float = 0.01

    private(set) var voicedSinceProbe: Double = 0
    private(set) var probesSent = 0
    private(set) var isInFlight = false

    /// Counts one audio chunk. Returns the new plan and whether to send a check now.
    func adding(chunkSeconds: Double, rms: Float) -> (plan: LanguageProbePlan, shouldProbe: Bool) {
        var next = self
        if rms >= Self.speechRMS { next.voicedSinceProbe += chunkSeconds }
        let needed = probesSent == 0 ? Self.firstProbeVoicedSeconds : Self.laterProbeVoicedSeconds
        guard !isInFlight, probesSent < Self.maxProbes, next.voicedSinceProbe >= needed else {
            return (next, false)
        }
        next.voicedSinceProbe = 0
        next.probesSent += 1
        next.isInFlight = true
        return (next, true)
    }

    /// The check came back (or failed); the next one may go once enough speech is heard.
    func finishingProbe() -> LanguageProbePlan {
        var next = self
        next.isInFlight = false
        return next
    }
}

enum LanguageProbeCore {
    /// Groq's turbo Whisper is the fastest; other providers use the model already configured.
    static let groqProbeModel = "whisper-large-v3-turbo"

    static func probeModel(baseURL: String, configuredModel: String) -> String {
        let host = URL(string: baseURL)?.host?.lowercased() ?? ""
        return host.hasSuffix("groq.com") ? groqProbeModel : configuredModel
    }

    /// `baseURL` plus `/audio/transcriptions`, or nil when it is not an http(s) URL.
    static func endpoint(baseURL: String) -> URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed + "/audio/transcriptions"),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return nil
        }
        return url
    }

    /// Keeps only the last `windowSeconds` of audio, cut on a sample boundary.
    static func trimmedToWindow(_ pcm16: Data) -> Data {
        let limit = Int(LanguageProbePlan.windowSeconds * Double(LanguageProbePlan.bytesPerSecond))
        guard pcm16.count > limit else { return pcm16 }
        return Data(pcm16.suffix(limit - limit % 2))
    }

    /// Root-mean-square level of little-endian PCM16, 0...1.
    static func rms(ofPCM16 pcm16: Data) -> Float {
        let count = pcm16.count / 2
        guard count > 0 else { return 0 }
        let sum = pcm16.withUnsafeBytes { raw -> Double in
            var total = 0.0
            for index in 0..<count {
                let sample = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)))
                total += sample * sample
            }
            return total
        }
        return Float((sum / Double(count)).squareRoot() / Double(Int16.max))
    }

    /// A 16-bit mono WAV file around raw PCM16 samples.
    static func wav(pcm16: Data, sampleRate: Int = LanguageProbePlan.sampleRate) -> Data {
        var header = Data()
        func append(_ text: String) { header.append(Data(text.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        append("RIFF")
        append32(UInt32(36 + pcm16.count))
        append("WAVE")
        append("fmt ")
        append32(16)
        append16(1) // PCM
        append16(1) // mono
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))
        append16(2)
        append16(16)
        append("data")
        append32(UInt32(pcm16.count))
        return header + pcm16
    }

    /// No language and no prompt: either would bias Whisper away from what was actually said.
    static func multipartBody(wav: Data, model: String, responseFormat: String, boundary: String) -> Data {
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        for (name, value) in [("model", model), ("response_format", responseFormat), ("temperature", "0")] {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"probe.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    /// Whisper's `language` (verbose_json only) and `text`, or nil for an unreadable body.
    static func parseResponse(_ data: Data) -> (language: String?, text: String)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else {
            return nil
        }
        let language = (object["language"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (language, text)
    }

    /// Whisper's own language guess wins (it tells Urdu from Arabic even when the script is
    /// shared); without one, the text's script decides. nil means no signal, keep the look.
    static func look(language: String?, text: String) -> SpokenLook? {
        if let language, let look = SpokenLook.forLanguage(language) { return look }
        if let fromText = SpokenLook.detect(in: text) { return fromText }
        return language == nil ? nil : SpokenLook.none
    }
}
