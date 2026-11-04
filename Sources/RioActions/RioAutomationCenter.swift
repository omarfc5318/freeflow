import AppKit

/// Owns the live side of automations: a timer for scheduled commands that also re-checks when the
/// Mac wakes, and the watcher for triggers. The lead starts it once at launch:
/// `RioAutomationCenter.shared.start(run: { [appState] in appState.runRioCommandText($0, source: .automation) })`
@MainActor
final class RioAutomationCenter {
    static let shared = RioAutomationCenter()
    typealias RunCommand = @MainActor (String) -> Void

    let store: RioAutomationStore
    /// Called with a plain-language note when a run was skipped, so the lead can show it on the bear.
    var onNote: (@MainActor (String) -> Void)?
    private var run: RunCommand?
    private var timer: Timer?
    private var watcher: RioTriggerWatcher?
    private var observers: [NSObjectProtocol] = []
    private var isTicking = false
    private static let tickSeconds: TimeInterval = 15
    private static let gapBetweenRuns: UInt64 = 4_000_000_000

    init(store: RioAutomationStore = .shared) { self.store = store }

    func start(run: @escaping RunCommand) {
        guard self.run == nil else { return }
        self.run = run
        let timer = Timer(timeInterval: Self.tickSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // A short wait lets the network and displays come back before commands run.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self?.tick()
            }
        })
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.rebase() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: RioAutomationStore.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refreshWatcher() } })

        watcher = RioTriggerWatcher { [weak self] event in self?.handle(event) }
        refreshWatcher()
        Task { @MainActor in await tick() }
    }

    func refreshWatcher() {
        watcher?.update(for: store.data.triggers.map(\.kind))
    }

    /// After a clock or time zone change every recurring schedule is placed again from now.
    private func rebase() {
        let now = Date()
        let calendar = Calendar.current
        let rebased = store.data.schedules.map { item -> RioScheduledCommand in
            var copy = item
            if item.recurrence != .once,
               let next = RioScheduleMath.nextFire(after: now, recurrence: item.recurrence, hour: item.hour, minute: item.minute, calendar: calendar) {
                copy.nextFire = next
            }
            return copy
        }
        store.replaceSchedules(rebased)
    }

    func tick() async {
        guard !isTicking, let run else { return }
        isTicking = true
        defer { isTicking = false }
        let now = Date()
        let calendar = Calendar.current
        var keep: [RioScheduledCommand] = []
        var toRun: [RioScheduledCommand] = []
        for item in store.data.schedules {
            let outcome = RioScheduleMath.resolve(item, now: now, calendar: calendar)
            if let updated = outcome.updated { keep.append(updated) }
            switch outcome.verdict {
            case .notDue: break
            case .fire: toRun.append(item)
            case .skipped:
                let note = RioAutomationText.skipNote(for: item, calendar: calendar)
                store.addNote(note)
                onNote?(note)
            }
        }
        // The schedule is saved before anything runs, so a crash mid-run never repeats a command.
        store.replaceSchedules(keep)
        for (index, item) in toRun.enumerated() {
            if index > 0 { try? await Task.sleep(nanoseconds: Self.gapBetweenRuns) }
            run(item.command)
        }
    }

    private func handle(_ event: RioSystemEvent) {
        guard let run else { return }
        let now = Date()
        var delay: UInt64 = 0
        for rule in store.data.triggers where RioTriggerMatcher.matches(rule.kind, event)
            && RioTriggerMatcher.shouldFire(lastFired: rule.lastFired, now: now) {
            store.markFired(triggerID: rule.id, at: now)
            let command = rule.command
            let wait = delay
            Task { @MainActor in
                if wait > 0 { try? await Task.sleep(nanoseconds: wait) }
                run(command)
            }
            delay += Self.gapBetweenRuns
        }
    }
}
