import AVFoundation
import CoreGraphics
import Foundation

/// The meeting copilot: a rolling five minutes of call audio (system audio plus the mic, mixed
/// to 16 kHz mono) in memory only. Nothing is written to disk or logged, and the audio is wiped
/// when it stops. It stops on `stop()`, when the call ends, or after two hours.
@MainActor
final class RioMeetingCopilot: ObservableObject {
    static let shared = RioMeetingCopilot()

    static let bufferSeconds = 300
    private static let pollSeconds: TimeInterval = 15

    enum StartFailure: Error, Equatable {
        case needsScreenRecording
        case captureFailed
        /// No other app is using the microphone (macOS 14 and later can tell): there is no call.
        case noCall
    }

    /// Drives the bear's "listening" badge.
    @Published private(set) var isRecording = false

    /// Called after the copilot stops by itself (the call ended, two hours passed, or the
    /// capture stream stopped on its own: permission revoked, display change).
    var onAutoStopped: ((RioMeetingStopReason) -> Void)?

    /// True while `start()` waits for the capture stream, so a second start can't open a second
    /// stream and a stop in that window isn't lost.
    private var isStarting = false
    private var stopRequestedWhileStarting = false
    /// Which capture a stream callback belongs to: a late callback from an old stream must not stop a new one.
    private var session = 0

    private let buffers = RioMeetingBuffers(seconds: RioMeetingCopilot.bufferSeconds)
    private var systemCapture: RioSystemAudioCapture?
    private var micTap: RioMeetingMicTap?
    private var autoStop: RioMeetingAutoStop?
    private var timer: Timer?

    /// macOS 14 and later can list which apps use the microphone; before that, nil.
    private static func otherAppUsingMic() -> Bool? {
        if #available(macOS 14.0, *) { return MicUsageMonitor.isOtherAppUsingMicrophone() }
        return nil
    }

    func start() async throws {
        guard !isRecording, !isStarting else { return }
        // A call means some other app is using the mic. macOS 13 can't tell (nil): the two-hour cap applies.
        if Self.otherAppUsingMic() == false { throw StartFailure.noCall }
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw StartFailure.needsScreenRecording
        }
        isStarting = true
        stopRequestedWhileStarting = false
        defer { isStarting = false }
        session += 1
        let current = session
        let buffers = buffers
        buffers.wipe()
        let system = RioSystemAudioCapture(
            onAudio: { buffers.appendSystem($0) },
            onStopped: { Task { @MainActor in RioMeetingCopilot.shared.captureStoppedItself(session: current) } }
        )
        do {
            try await system.start()
        } catch {
            throw StartFailure.captureFailed
        }
        // "Stop" arrived while the stream was starting: honour it instead of recording anyway.
        if stopRequestedWhileStarting {
            system.stop()
            buffers.wipe()
            return
        }
        systemCapture = system
        // The owner's side of the call. Skipped (system audio only) unless the mic is already allowed.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            let tap = RioMeetingMicTap(onAudio: { buffers.appendMic($0) })
            if (try? tap.start()) != nil { micTap = tap }
        }
        autoStop = RioMeetingAutoStop(start: Date())
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollSeconds, repeats: true) { _ in
            Task { @MainActor in RioMeetingCopilot.shared.checkAutoStop() }
        }
    }

    /// Stops listening and wipes the audio.
    func stop() {
        if isStarting { stopRequestedWhileStarting = true }
        timer?.invalidate()
        timer = nil
        systemCapture?.stop()
        systemCapture = nil
        micTap?.stop()
        micTap = nil
        autoStop = nil
        buffers.wipe()
        isRecording = false
    }

    /// The stream ended without being asked to: stop, and tell the owner rather than vanish quietly.
    private func captureStoppedItself(session stopped: Int) {
        guard stopped == session, isRecording else { return }
        stop()
        onAutoStopped?(.callEnded)
    }

    /// The last `seconds` of the call, mixed. Empty when not recording.
    func recentAudio(seconds: Double) -> Data {
        isRecording ? buffers.mixed(seconds: seconds) : Data()
    }

    private func checkAutoStop() {
        guard isRecording, let reason = autoStop?.tick(now: Date(), micInUse: Self.otherAppUsingMic()) else { return }
        stop()
        onAutoStopped?(reason)
    }
}
