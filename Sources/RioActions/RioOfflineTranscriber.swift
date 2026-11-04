import Foundation
import Speech

/// Transcribes a recorded Fn + Control command on this Mac, with no network, so the built-in
/// commands ("open Chrome", "volume down") keep working offline. Used only when
/// `NetworkMonitor` says the Mac is offline. Nothing is sent anywhere: recognition is forced
/// on-device, and it refuses to run if the on-device model isn't installed.
enum RioOfflineTranscriber {
    enum Failure: Error, Equatable {
        case permissionDenied
        case unavailable
        case noSpeech
        case failed

        /// Short and friendly: this is what the bear shows and Rio says.
        var message: String {
            switch self {
            case .permissionDenied: return "I need Speech Recognition permission to work offline"
            case .unavailable: return "I can't understand speech offline on this Mac yet"
            case .noSpeech: return "I didn't catch that"
            case .failed: return "I couldn't understand that offline"
            }
        }
    }

    static func transcribe(fileURL: URL) async throws -> String {
        guard await hasPermission() else { throw Failure.permissionDenied }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw Failure.unavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .search
        let box = RecognitionTaskBox()
        let text: String = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let gate = SingleResume(continuation)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        gate.resume(returning: result.bestTranscription.formattedString)
                    } else if let error {
                        gate.resume(throwing: failure(for: error))
                    }
                }
                box.set(task) { gate.resume(throwing: CancellationError()) }
                gate.onFinish { task.cancel() }
                // A recognizer that never answers must not leave the bear "working" forever.
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                    gate.resume(throwing: Failure.failed)
                }
            }
        } onCancel: {
            box.cancel()
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.noSpeech }
        return trimmed
    }

    /// The recognizer gives up after this long without an answer.
    static let timeoutSeconds: TimeInterval = 15

    /// Apple reports silence as an error (kAFAssistantErrorDomain 1110, "No speech detected");
    /// that is "I didn't catch that", not a failure.
    static func failure(for error: Error) -> Failure {
        let nsError = error as NSError
        let message = nsError.localizedDescription.lowercased()
        if nsError.code == 1110 || nsError.code == 203 || message.contains("no speech") { return .noSpeech }
        return .failed
    }

    private static func hasPermission() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }
}

/// The recognition callback can fire more than once (a final result, then an error); a
/// continuation may only be resumed once.
private final class SingleResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var cleanup: (() -> Void)?

    init(_ continuation: CheckedContinuation<String, Error>) { self.continuation = continuation }

    func onFinish(_ cleanup: @escaping () -> Void) {
        lock.lock()
        let alreadyDone = continuation == nil
        if !alreadyDone { self.cleanup = cleanup }
        lock.unlock()
        if alreadyDone { cleanup() }
    }

    func resume(returning value: String) { finish { $0.resume(returning: value) } }
    func resume(throwing error: Error) { finish { $0.resume(throwing: error) } }

    private func finish(_ body: (CheckedContinuation<String, Error>) -> Void) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let cleanup = self.cleanup
        self.cleanup = nil
        lock.unlock()
        guard let continuation else { return }
        body(continuation)
        cleanup?()
    }
}

/// Lets the cancellation handler (which runs on any thread) cancel the recognition task and
/// release the waiting continuation.
private final class RecognitionTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: SFSpeechRecognitionTask?
    private var onCancel: (() -> Void)?
    private var cancelled = false

    func set(_ task: SFSpeechRecognitionTask, onCancel: @escaping () -> Void) {
        lock.lock()
        self.task = task
        self.onCancel = onCancel
        let already = cancelled
        lock.unlock()
        if already { cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        let onCancel = self.onCancel
        lock.unlock()
        task?.cancel()
        onCancel?()
    }
}
