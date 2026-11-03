import AppKit
import Foundation
import UserNotifications

/// The live timer: one at a time, shown by the bear holding a clock through
/// `RioCompanionCenter.timerRemaining`. At zero it rings (`timerRinging`), plays a gentle sound,
/// Rio says "Your pasta timer is done!" and a notification appears. Ringing stops after 30 s, on
/// any key or click, or on "Rio, stop". The countdown math is `RioTimerCountdown` (pure, tested).
private let rioTimerNotificationID = "rio.timer"

@MainActor final class RioTimerCenter {
    static let shared = RioTimerCenter()

    enum CancelResult: Equatable {
        /// A running timer was cancelled; the value is what it was.
        case cancelled(RioTimerCountdown)
        case stoppedRinging
        case nothing
    }

    static let ringDuration: TimeInterval = 30
    private static let ringInterval: TimeInterval = 2.5
    /// Events this soon after the ring starts are ignored: the finger that pressed a key
    /// a moment ago must not silence it before anyone heard it.
    private static let ringGrace: TimeInterval = 1.0

    private let center = RioCompanionCenter.shared
    private let voice = RioVoice.shared
    private let clock: () -> Date

    private(set) var countdown: RioTimerCountdown?
    private(set) var isRinging = false
    private var tickTimer: Timer?
    private var ringTimer: Timer?
    private var ringStartedAt = Date.distantPast
    private var lastShownSeconds: Int?
    private var eventMonitors: [Any] = []

    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    var now: Date { clock() }

    // MARK: Control

    @discardableResult
    func start(seconds: Int, label: String?) -> RioTimerCountdown {
        stopRinging()
        removeNotification()
        let timer = RioTimerCountdown(seconds: seconds, label: label, start: clock())
        countdown = timer
        publish(timer.remaining(at: clock()))
        startTicking()
        scheduleNotification(for: timer)
        return timer
    }

    @discardableResult
    func cancel() -> CancelResult {
        if isRinging {
            stopRinging()
            return .stoppedRinging
        }
        guard let timer = countdown else { return .nothing }
        let remaining = timer.remaining(at: clock())
        let snapshot = RioTimerCountdown(seconds: Int(remaining.rounded(.up)), label: timer.label, start: clock())
        clear()
        removeNotification()
        return .cancelled(snapshot)
    }

    /// Silences the ring (and the bear's alarm) without touching a running timer.
    func stopRinging() {
        guard isRinging else { return }
        isRinging = false
        ringTimer?.invalidate()
        ringTimer = nil
        removeEventMonitors()
        center.timerRinging = false
        if countdown == nil { center.timerRemaining = nil }
    }

    // MARK: Ticking

    private func startTicking() {
        tickTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func tick() {
        guard let timer = countdown else { return }
        let remaining = timer.remaining(at: clock())
        if remaining <= 0 {
            finish(timer)
        } else {
            publish(remaining)
        }
    }

    /// Only publishes when the whole second changes, so the bear isn't redrawn four times a second.
    private func publish(_ remaining: TimeInterval) {
        let shown = RioTimerCountdown.displaySeconds(remaining)
        guard shown != lastShownSeconds else { return }
        lastShownSeconds = shown
        center.timerRemaining = TimeInterval(shown)
    }

    private func clear() {
        tickTimer?.invalidate()
        tickTimer = nil
        countdown = nil
        lastShownSeconds = nil
        if !isRinging { center.timerRemaining = nil }
    }

    // MARK: Ringing

    private func finish(_ timer: RioTimerCountdown) {
        clear()
        isRinging = true
        ringStartedAt = clock()
        lastShownSeconds = 0
        center.timerRemaining = 0
        center.timerRinging = true
        voice.speak(timer.doneLine)
        ringOnce()
        let ring = Timer(timeInterval: Self.ringInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ringTick() }
        }
        RunLoop.main.add(ring, forMode: .common)
        ringTimer = ring
        installEventMonitors()
    }

    private func ringTick() {
        guard isRinging else { return }
        if clock().timeIntervalSince(ringStartedAt) >= Self.ringDuration {
            stopRinging()
        } else {
            ringOnce()
        }
    }

    /// A gentle system chime; skipped while another app is using the microphone (a call).
    private func ringOnce() {
        guard !MicUsageMonitor.isOtherAppUsingMicrophone() else { return }
        (NSSound(named: NSSound.Name("Glass")) ?? NSSound(named: NSSound.Name("Ping")))?.play()
    }

    /// Any key press or click silences the ring. The handlers never look at what was typed.
    private func installEventMonitors() {
        removeEventMonitors()
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]
        let react: @Sendable () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.clock().timeIntervalSince(self.ringStartedAt) > Self.ringGrace else { return }
                self.stopRinging()
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in react() }) {
            eventMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            react()
            return event
        }) {
            eventMonitors.append(local)
        }
    }

    private func removeEventMonitors() {
        eventMonitors.forEach { NSEvent.removeMonitor($0) }
        eventMonitors = []
    }

    // MARK: Notification

    private var canNotify: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    private func scheduleNotification(for timer: RioTimerCountdown) {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Rio"
            content.body = timer.doneLine
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(max(1, timer.seconds)), repeats: false)
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: rioTimerNotificationID, content: content, trigger: trigger))
        }
    }

    private func removeNotification() {
        guard canNotify else { return }
        let notifications = UNUserNotificationCenter.current()
        notifications.removePendingNotificationRequests(withIdentifiers: [rioTimerNotificationID])
        notifications.removeDeliveredNotifications(withIdentifiers: [rioTimerNotificationID])
    }
}
