import AppKit
import Combine
import SwiftUI

/// Owns the corner bear: the click-through panel in the bottom-left corner, the model that
/// drives it, and the Dock run. The recording overlay forwards dictation events here when the
/// style is "Corner bear"; `attach(_:)` lets it follow AppState's `rioActionPhase`.
@MainActor
final class RioCompanionHub: RioCompanionDirecting {
    static let shared = RioCompanionHub()
    static let dockRunDefaultsKey = "rio_dock_run_enabled"

    let model = RioCompanionModel()
    private let locator = RioDockLocator()
    private(set) var panel: NSPanel?
    var cancellables = Set<AnyCancellable>()
    // Screen following (RioCompanionHub+ScreenFollow.swift). `homeDisplayID` nil means the primary.
    nonisolated(unsafe) static var homeDisplayIDStorage: Int?
    var homeDisplayID: Int? {
        get { Self.homeDisplayIDStorage }
        set { Self.homeDisplayIDStorage = newValue }
    }
    var screenFollow = RioScreenFollowDebounce()
    var screenFollowTimer: Timer?
    var isMovingScreens = false
    private var recoveryAnnounced = false
    private var housekeepingTimer: Timer?
    private var housekeepingPeriod: TimeInterval = 0
    private var lastActionPhase: RioActionPhase = .idle
    var voiceIsActive = false
    private var runToken = UUID()
    private var dockRunThrottle = RioDockRunThrottle()
    private var observersInstalled = false

    private init() {}

    // MARK: Setup

    func attach(_ appState: AppState) {
        startDockClickRuns()
        // Only the two AppState values the bear needs: the action phase and the crash apology.
        // Speech, timer, help and celebration come straight from RioVoice and RioCompanionCenter,
        // never through AppState's mirrored copies (they fired at 30 Hz while he spoke).
        appState.$rioActionPhase.removeDuplicates()
            .sink { [weak self] phase in MainActor.assumeIsolated { self?.syncActionPhase(phase) } }
            .store(in: &cancellables)
        appState.$rioRecoveredFromCrash.removeDuplicates()
            .sink { [weak self] recovered in
                MainActor.assumeIsolated {
                    guard let self, recovered, !self.recoveryAnnounced else { return }
                    self.recoveryAnnounced = true
                    self.announceRecovery()
                }
            }
            .store(in: &cancellables)
        bindDirectSources()
        installObservers()
        applyStyle()
    }

    private func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let center = NotificationCenter.default
        // UserDefaults posts one notification for every write by anyone in the app; only a change
        // to the bear's own keys may re-run the style, relayout and Dock walk.
        center.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.bearDefaultsMayHaveChanged() } }.store(in: &cancellables)
        center.publisher(for: NSApplication.didChangeScreenParametersNotification).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.reconcileHomeScreen(); self?.relayout() } }.store(in: &cancellables)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.publisher(for: name).debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.locator.refresh() } }.store(in: &cancellables)
        }
        DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.dock.prefchanged"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.relayout(); self?.locator.refresh() } }
            .store(in: &cancellables)
        installScreenFollow()
        installPauseObservers()
        model.onStop = { [weak self] in self?.onStopPressed?() }
    }

    var onStopPressed: (() -> Void)?

    private var lastBearDefaults: RioBearDefaults?

    private static func readBearDefaults() -> RioBearDefaults {
        RioBearDefaults.read(
            from: .standard, styleKey: RioStyle.defaultsKey,
            capturesKey: RioCompanionPrivacy.defaultsKey, dockRunKey: dockRunDefaultsKey
        )
    }

    private func bearDefaultsMayHaveChanged() {
        let current = Self.readBearDefaults()
        guard current != lastBearDefaults else { return }
        applyStyle()
    }

    // MARK: Pausing (display asleep, session inactive, panel covered)

    private func installPauseObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        let changes: [(Notification.Name, WritableKeyPath<RioRedrawGate, Bool>, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, \.displayAsleep, true),
            (NSWorkspace.screensDidWakeNotification, \.displayAsleep, false),
            (NSWorkspace.sessionDidResignActiveNotification, \.sessionActive, false),
            (NSWorkspace.sessionDidBecomeActiveNotification, \.sessionActive, true),
        ]
        for (name, path, value) in changes {
            workspace.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.setGate(path, to: value) } }
                .store(in: &cancellables)
        }
        NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification).receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let panel = self.panel, (note.object as? NSPanel) === panel else { return }
                    self.setGate(\.panelVisible, to: panel.occlusionState.contains(.visible))
                }
            }
            .store(in: &cancellables)
    }

    private func setGate(_ path: WritableKeyPath<RioRedrawGate, Bool>, to value: Bool) {
        guard model.gate[keyPath: path] != value else { return }
        model.gate[keyPath: path] = value
        // Resuming kicks the timers back on; pausing lets them lapse and stops screen-follow polling.
        kick()
        updateScreenFollowTimer()
    }

    /// Shows the sleeping bear (corner style) or removes him (classic pill).
    func applyStyle() {
        lastBearDefaults = Self.readBearDefaults()
        if RioStyle.current == .corner {
            if panel == nil { makePanel() }
            panel?.sharingType = RioCompanionPrivacy.sharingType
            relayout()
            locator.refresh()
            kick()
            updateScreenFollowTimer()
        } else if let panel {
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
            self.panel = nil
            stopHousekeeping()
            homeDisplayID = nil
            updateScreenFollowTimer()
        }
    }

    // MARK: Events from the overlay and AppState

    func voiceChanged(_ voice: RioCompanionMachine.Voice) {
        guard RioStyle.current == .corner else { return }
        voiceIsActive = voice != .none
        if voice == .starting { locator.refresh() }
        model.machine.voiceChanged(voice, at: RioCompanionClock.now)
        if voice == .none { model.level = 0 }
        kick()
    }

    func setLevel(_ level: Float) { model.level = CGFloat(min(max(level, 0), 1)) }
    func setOutfit(_ outfit: TeddyOutfit) { model.outfit = outfit }
    func setLook(_ look: SpokenLook) { model.look = look }

    func setHandsFree(_ isOn: Bool) {
        guard panel != nil else { return }
        let shows = isOn && voiceIsActive
        panel?.ignoresMouseEvents = !shows
        if model.showsStop != shows { model.showsStop = shows }
    }

    /// Moments never interrupt a dictation in progress; the closing ones may replace the
    /// transcribing state, as the pill's did.
    func showMoment(_ moment: TeddyMoment, interruptsTranscribing: Bool) {
        let now = RioCompanionClock.now
        let mode = model.machine.mode(at: now)
        if mode == .talking || mode == .waking || mode == .away || mode == .sprint || mode == .punch { return }
        if mode == .thinking && !interruptsTranscribing { return }
        if voiceIsActive && interruptsTranscribing { voiceChanged(.none) }
        model.machine.showMoment(moment, at: now)
        kick()
    }

    func showNotice(_ text: String, seconds: TimeInterval = 6) {
        model.noticeText = (text, RioCompanionClock.now + seconds)
        kick()
    }

    func showError(_ message: String, seconds: TimeInterval = 6) {
        model.errorText = (message, RioCompanionClock.now + seconds)
        kick()
    }

    /// After a crash restart: the bear says sorry on a speech card and Rio says it aloud.
    private func announceRecovery() {
        let text = Self.recoveryMessage
        RioVoice.shared.speak(text)
        guard RioStyle.current == .corner, panel != nil else { return }
        model.noticeText = (text, RioCompanionClock.now + 5)
        kick()
    }

    static let recoveryMessage = "Sorry, I tripped! I'm back."
    static let crashLoopMessage = "Rio kept crashing at startup, so I stopped restarting him."

    /// Shown once on the first manual launch after Rio gave up restarting himself (three crashes
    /// in about two minutes). A longer card on the bear; a plain alert when the pill style is on.
    func announceCrashLoopStopped() {
        if RioStyle.current == .corner, panel != nil {
            model.noticeText = (Self.crashLoopMessage, RioCompanionClock.now + 10)
            kick()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Rio stopped restarting"
        alert.informativeText = Self.crashLoopMessage
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func showFailure() { showError("Something went wrong", seconds: 2.2) }

    func trick(isAway: Bool) {
        model.machine.trickChanged(isAway: isAway, at: RioCompanionClock.now)
        kick()
    }

    var isShown: Bool { panel != nil }

    /// Where the trick bear jumps out of: the corner bear's centre, from the top left of his
    /// screen. Main thread only.
    nonisolated static func trickHome() -> (screen: NSScreen, point: CGPoint)? {
        guard let screen = homeScreen() else { return nil }
        let anchor = RioCompanionLayout.anchor(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        let centerX = anchor.x + RioCompanionMetrics.halfBody - screen.frame.minX
        let centerY = screen.frame.height - (anchor.y - screen.frame.minY + 30)
        return (screen, CGPoint(x: centerX, y: centerY))
    }

    private var celebrateWatcher = RioCounterWatcher()
    private var lastTimer: (remaining: Int?, ringing: Bool) = (nil, false)
    var lastSpeaking = false
    var lastHelp = false

    /// Subscribes straight to the sources of the bear's state: Rio's voice (speaking and mouth
    /// level) and RioCompanionCenter (timer, help card, celebrations). `@Published` fires before
    /// the value changes, so each handler uses the value it is handed, never a re-read.
    private func bindDirectSources() {
        let voice = RioVoice.shared
        let center = RioCompanionCenter.shared
        voice.$isSpeaking.removeDuplicates()
            .sink { [weak self] speaking in MainActor.assumeIsolated { self?.speakingChanged(speaking) } }
            .store(in: &cancellables)
        voice.$level
            .sink { [weak self] level in
                MainActor.assumeIsolated {
                    guard let self, self.lastSpeaking else { return }
                    self.model.level = CGFloat(min(max(level, 0), 1))
                }
            }
            .store(in: &cancellables)
        center.$timerRemaining.combineLatest(center.$timerRinging)
            .sink { [weak self] remaining, ringing in MainActor.assumeIsolated { self?.timerChanged(remaining: remaining, ringing: ringing) } }
            .store(in: &cancellables)
        RioTranslatorMode.shared.$isOn.removeDuplicates()
            .sink { [weak self] isOn in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.model.wearsHeadphones = isOn
                    self.kick()
                }
            }
            .store(in: &cancellables)
        center.$isHelpVisible.removeDuplicates()
            .sink { [weak self] visible in MainActor.assumeIsolated { self?.helpChanged(visible) } }
            .store(in: &cancellables)
        center.$celebrateCount
            .sink { [weak self] count in MainActor.assumeIsolated { self?.celebrateCountChanged(count) } }
            .store(in: &cancellables)
    }

    private func speakingChanged(_ speaking: Bool) {
        guard RioStyle.current == .corner, speaking != lastSpeaking else { return }
        lastSpeaking = speaking
        model.machine.speakingChanged(speaking, at: RioCompanionClock.now)
        kick()
    }

    private func timerChanged(remaining: TimeInterval?, ringing: Bool) {
        guard RioStyle.current == .corner else { return }
        let wholeSeconds = remaining.map { Int($0.rounded(.up)) }
        guard wholeSeconds != lastTimer.remaining || ringing != lastTimer.ringing else { return }
        lastTimer = (wholeSeconds, ringing)
        model.machine.timerChanged(remaining: remaining, ringing: ringing, at: RioCompanionClock.now)
        kick()
    }

    private func helpChanged(_ visible: Bool) {
        guard RioStyle.current == .corner, visible != lastHelp else { return }
        lastHelp = visible
        model.machine.helpChanged(visible, at: RioCompanionClock.now)
        kick()
    }

    private func celebrateCountChanged(_ count: Int) {
        guard RioStyle.current == .corner, celebrateWatcher.didIncrement(count) else { return }
        model.machine.celebrate(at: RioCompanionClock.now)
        kick()
    }

    private func syncActionPhase(_ phase: RioActionPhase) {
        guard phase != lastActionPhase else { return }
        lastActionPhase = phase
        guard RioStyle.current == .corner else { return }
        switch phase {
        case .listening, .working: locator.refresh()
        default: break
        }
        model.machine.actionPhaseChanged(phase, at: RioCompanionClock.now)
        kick()
    }

    // MARK: Dock run (RioCompanionDirecting)

    func runAndPunchDockIcon(appURL: URL, bundleIdentifier: String?, punch: @escaping @MainActor () -> Void) async -> Bool {
        await runToDockIcon(appURL: appURL, allowStaleDock: false, punch: punch)
    }

    // MARK: The owner's own Dock clicks

    private var dockClickMonitors: [Any] = []
    private var dockMouseDown: CGPoint?

    /// Watches left clicks on the Dock (global monitors only observe; the click still reaches the
    /// Dock untouched, so apps open exactly as fast as always). On release over an app icon the
    /// bear sprints there and punches it while the app opens.
    func startDockClickRuns() {
        guard dockClickMonitors.isEmpty else { return }
        if let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dockMouseDown(at: NSEvent.mouseLocation) }
        }) { dockClickMonitors.append(down) }
        if let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dockMouseUp(at: NSEvent.mouseLocation) }
        }) { dockClickMonitors.append(up) }
    }

    private func dockMouseDown(at location: CGPoint) {
        dockMouseDown = nil
        guard RioStyle.current == .corner, dockRunEnabled, let primary = NSScreen.screens.first else { return }
        // Only presses near the bottom edge (where the Dock lives) are interesting.
        guard location.y - primary.frame.minY < 160 else { return }
        dockMouseDown = location
        locator.refresh()
    }

    private func dockMouseUp(at location: CGPoint) {
        guard let down = dockMouseDown, let primary = NSScreen.screens.first else { return }
        dockMouseDown = nil
        guard DockClickHitTest.isClick(down: down, up: location) else { return }
        let point = DockClickHitTest.axPoint(fromAppKit: location, primaryHeight: primary.frame.height)
        guard let appURL = locator.clickedAppURL(atAX: point) else { return }
        Task { @MainActor [weak self] in
            // The Dock is already opening the app; the punch is just the bear's flourish.
            _ = await self?.runToDockIcon(appURL: appURL, allowStaleDock: true, punch: {})
        }
    }

    private func runToDockIcon(appURL: URL, allowStaleDock: Bool, punch: @escaping @MainActor () -> Void) async -> Bool {
        guard RioStyle.current == .corner, dockRunEnabled, panel != nil,
              let screen = Self.homeScreen(),
              RioScreenChoice.canRunDockRun(bearScreen: homeDisplayID, screens: Self.screenInfos()) else { return false }
        let now = RioCompanionClock.now
        // Never while a trick or another run is going, and at most one run per 0.5 s.
        guard dockRunThrottle.allows(at: now), model.machine.canRun(at: now), model.run == nil,
              let target = locator.target(for: appURL, primaryScreen: screen.frame, allowStale: allowStaleDock) else { return false }

        let anchor = RioCompanionLayout.anchor(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        let startX = anchor.x + RioCompanionMetrics.halfBody - screen.frame.minX
        // Stop short so the fist, not the body, lands on the icon's left half.
        let finalX = target.iconRect.minX + 8 - 22 - screen.frame.minX
        guard finalX > startX + 24 else { return false }

        let plan = RioDockRunPlan.make(distance: finalX - startX)
        guard model.machine.startRun(plan, at: now) else { return false }
        dockRunThrottle.record(at: now)
        let token = UUID()
        runToken = token
        let height = RioCompanionMetrics.cornerPanelSize.height
        let ground = height - RioCompanionLayout.groundInset
        let iconCenter = CGPoint(x: target.iconRect.midX - screen.frame.minX, y: height - (target.iconRect.midY - screen.frame.minY))
        model.homeX = startX
        model.groundY = ground
        model.run = RioCompanionModel.Run(plan: plan, start: now, startX: startX, finalX: finalX, iconCenter: iconCenter)
        setPanelFrame(CGRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: height))
        model.refreshTier(at: now)
        kick()

        let wait = max(0, plan.impactTime - (RioCompanionClock.now - now))
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        punch()

        let restore = plan.totalDuration + RioDockRunPlan.returnDuration + 0.1
        DispatchQueue.main.asyncAfter(deadline: .now() + restore) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.runToken == token else { return }
                self.model.run = nil
                self.relayout()
            }
        }
        return true
    }

    private var dockRunEnabled: Bool {
        (UserDefaults.standard.object(forKey: Self.dockRunDefaultsKey) as? Bool) ?? true
    }

    // MARK: Panel

    private func makePanel() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: RioCompanionMetrics.cornerPanelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.sharingType = RioCompanionPrivacy.sharingType
        let hosting = NSHostingView(rootView: RioCompanionRootView(model: model))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        self.panel = panel
        panel.orderFrontRegardless()
    }

    private func setPanelFrame(_ frame: CGRect) {
        guard let panel else { return }
        panel.setFrame(frame, display: true)
    }

    /// Puts the small corner panel at the bottom-left of the primary screen.
    func relayout() {
        guard panel != nil, model.run == nil, let screen = Self.homeScreen() else { return }
        let anchor = RioCompanionLayout.anchor(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        let size = RioCompanionMetrics.cornerPanelSize
        let origin = CGPoint(x: anchor.x - RioCompanionMetrics.leftPad, y: screen.frame.minY)
        model.homeX = RioCompanionMetrics.leftPad + RioCompanionMetrics.halfBody
        model.groundY = size.height - RioCompanionLayout.groundInset
        setPanelFrame(CGRect(origin: origin, size: size))
        panel?.orderFrontRegardless()
    }

    /// Re-picks the redraw schedule and keeps a housekeeping timer running only as often as the
    /// schedule needs (none while asleep or paused).
    private func kick(notify: Bool = true) {
        let now = RioCompanionClock.now
        model.refreshTier(at: now)
        if notify { model.objectWillChange.send() }
        guard panel != nil, let period = model.housekeepingInterval() else {
            stopHousekeeping()
            return
        }
        if housekeepingTimer != nil, housekeepingPeriod == period { return }
        housekeepingTimer?.invalidate()
        housekeepingPeriod = period
        let timer = Timer(timeInterval: period, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.housekeepingTick() }
        }
        timer.tolerance = period * 0.25
        RunLoop.main.add(timer, forMode: .common)
        housekeepingTimer = timer
    }

    private func stopHousekeeping() {
        housekeepingTimer?.invalidate()
        housekeepingTimer = nil
        housekeepingPeriod = 0
    }

    private func housekeepingTick() {
        let t = RioCompanionClock.now
        if let error = model.errorText, t >= error.until { model.errorText = nil }
        if let notice = model.noticeText, t >= notice.until { model.noticeText = nil }
        // `kick` re-plans (or stops) the timer as the schedule changes. No forced redraw here:
        // the schedule's own ticks draw, and a schedule change publishes itself.
        kick(notify: false)
    }
}
