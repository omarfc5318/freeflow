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
    private var tierTimer: Timer?
    private var lastActionPhase: RioActionPhase = .idle
    var voiceIsActive = false
    private var runToken = UUID()
    private var observersInstalled = false

    private init() {}

    // MARK: Setup

    func attach(_ appState: AppState) {
        appState.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak appState] _ in
                guard let self, let appState else { return }
                MainActor.assumeIsolated { self.syncAppState(appState) }
            }
            .store(in: &cancellables)
        installObservers()
        applyStyle()
    }

    private func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let center = NotificationCenter.default
        center.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.applyStyle() } }.store(in: &cancellables)
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
        model.onStop = { [weak self] in self?.onStopPressed?() }
    }

    var onStopPressed: (() -> Void)?

    /// Shows the sleeping bear (corner style) or removes him (classic pill).
    func applyStyle() {
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
            tierTimer?.invalidate()
            tierTimer = nil
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

    /// Mirrors AppState's Rio state (action phase, speech, timer, help card, celebrations).
    private func syncAppState(_ appState: AppState) {
        syncActionPhase(appState.rioActionPhase)
        if appState.rioRecoveredFromCrash, !recoveryAnnounced {
            recoveryAnnounced = true
            announceRecovery()
        }
        guard RioStyle.current == .corner else { return }
        let now = RioCompanionClock.now
        var changed = false
        let speaking = appState.isRioSpeaking
        if speaking != lastSpeaking {
            lastSpeaking = speaking
            model.machine.speakingChanged(speaking, at: now)
            changed = true
        }
        if speaking { model.level = CGFloat(min(max(appState.rioSpeechLevel, 0), 1)) }
        let remaining = appState.rioTimerRemaining
        let wholeSeconds = remaining.map { Int($0.rounded(.up)) }
        let ringing = appState.rioTimerRinging
        if wholeSeconds != lastTimer.remaining || ringing != lastTimer.ringing {
            lastTimer = (wholeSeconds, ringing)
            model.machine.timerChanged(remaining: remaining, ringing: ringing, at: now)
            changed = true
        }
        if appState.isRioHelpVisible != lastHelp {
            lastHelp = appState.isRioHelpVisible
            model.machine.helpChanged(lastHelp, at: now)
            changed = true
        }
        if celebrateWatcher.didIncrement(appState.rioCelebrate) {
            model.machine.celebrate(at: now)
            changed = true
        }
        if changed { kick() }
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
        guard RioStyle.current == .corner, dockRunEnabled, panel != nil,
              let screen = Self.homeScreen(),
              RioScreenChoice.canRunDockRun(bearScreen: homeDisplayID, screens: Self.screenInfos()) else { return false }
        let now = RioCompanionClock.now
        guard model.machine.canRun(at: now), model.run == nil,
              let target = locator.target(for: appURL, primaryScreen: screen.frame) else { return false }

        let anchor = RioCompanionLayout.anchor(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        let startX = anchor.x + RioCompanionMetrics.halfBody - screen.frame.minX
        // Stop short so the fist, not the body, lands on the icon's left half.
        let finalX = target.iconRect.minX + 8 - 22 - screen.frame.minX
        guard finalX > startX + 24 else { return false }

        let plan = RioDockRunPlan.make(distance: finalX - startX)
        guard model.machine.startRun(plan, at: now) else { return false }
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

    /// Re-picks the redraw rate and keeps a light timer running while he is awake.
    private func kick() {
        let now = RioCompanionClock.now
        model.refreshTier(at: now)
        model.objectWillChange.send()
        guard tierTimer == nil, panel != nil else { return }
        tierTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = RioCompanionClock.now
                if let error = self.model.errorText, t >= error.until { self.model.errorText = nil }
                if let notice = self.model.noticeText, t >= notice.until { self.model.noticeText = nil }
                self.model.refreshTier(at: t)
                if !self.model.needsTimer && self.model.machine.mode(at: t) == .asleep {
                    self.tierTimer?.invalidate()
                    self.tierTimer = nil
                }
            }
        }
    }
}
