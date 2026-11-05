import Foundation

/// Main-run-loop timers whose callbacks reach the main actor by enqueueing a `Task`, never by
/// `MainActor.assumeIsolated`.
///
/// Why: build 123 crashed on 2026-11-04 after 9.5 hours (EXC_BAD_ACCESS, PC jumped to a garbage
/// address) inside the Swift runtime's main-executor check that `assumeIsolated` runs on every
/// tick (`swift_task_isCurrentExecutorWithFlagsImpl` → `SerialExecutor.isMainExecutor`). Rio's
/// fast timers made that check hundreds of thousands of times a day. Enqueueing a task on the
/// main actor takes a different runtime path with no isolation check.
///
/// A repeating timer's tick that was already queued when the timer was invalidated is dropped,
/// so `invalidate()` still means "no more ticks".
enum RioMainTimer {
    @discardableResult
    static func schedule(
        interval: TimeInterval,
        repeats: Bool,
        tolerance: TimeInterval = 0,
        _ body: @escaping @MainActor () -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats) { firing in
            let liveness = TimerLiveness(firing, repeats: repeats)
            Task { @MainActor in
                guard liveness.isLive else { return }
                body()
            }
        }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

/// Lets a queued tick ask whether its timer was invalidated in the meantime. A one-shot timer
/// is invalid as soon as it fires, so its tick always runs.
private final class TimerLiveness: @unchecked Sendable {
    private weak var timer: Timer?
    private let repeats: Bool

    init(_ timer: Timer, repeats: Bool) {
        self.timer = timer
        self.repeats = repeats
    }

    /// Read on the main thread only (inside the main-actor task); `Timer.isValid` is set on the
    /// main run loop, so there is no race.
    var isLive: Bool {
        guard repeats else { return true }
        return timer?.isValid ?? false
    }
}
