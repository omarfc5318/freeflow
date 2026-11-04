import AppKit

// The corner bear follows the owner to the screen they are working on: the screen holding the
// frontmost app's frontmost normal window (bounds only, so no Screen Recording permission and
// no window titles), else the screen under the mouse. The pure choice and the 1.5 s debounce
// live in RioScreenFollowCore.swift.
extension RioCompanionHub {
    // MARK: Screens

    nonisolated static func displayID(of screen: NSScreen) -> Int? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue
    }

    static func screenInfos() -> [RioScreenInfo] {
        NSScreen.screens.compactMap { screen in
            displayID(of: screen).map { RioScreenInfo(id: $0, frame: screen.frame) }
        }
    }

    /// The screen the bear stands on: the one he followed the owner to, else the primary.
    /// Main thread only.
    nonisolated static func homeScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let id = homeDisplayIDStorage, let match = screens.first(where: { displayID(of: $0) == id }) {
            return match
        }
        return screens.first
    }

    // MARK: Observing

    /// Activation notifications catch app switches; a 1 Hz poll (only with several displays)
    /// catches a window dragged to another screen. Both run the same cheap check.
    func installScreenFollow() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspace.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.checkScreenFollow() } }.store(in: &cancellables)
        }
    }

    /// Starts or stops the safety poll to match the number of displays and the style.
    func updateScreenFollowTimer() {
        let needed = RioStyle.current == .corner && isShown && NSScreen.screens.count > 1 && !model.gate.isPaused
        if needed, screenFollowTimer == nil {
            let timer = Timer(timeInterval: RioScreenFollow.pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkScreenFollow() }
            }
            timer.tolerance = 0.3
            RunLoop.main.add(timer, forMode: .common)
            screenFollowTimer = timer
        } else if !needed, let timer = screenFollowTimer {
            timer.invalidate()
            screenFollowTimer = nil
        }
    }

    /// A display was added or removed: forget a screen that is gone and re-plan the timer.
    func reconcileHomeScreen() {
        let screens = Self.screenInfos()
        if let id = homeDisplayID, !screens.contains(where: { $0.id == id }) { homeDisplayID = nil }
        screenFollow = RioScreenFollowDebounce(current: homeDisplayID ?? RioScreenChoice.dockScreenID(screens: screens))
        updateScreenFollowTimer()
    }

    // MARK: The check

    func checkScreenFollow() {
        guard RioStyle.current == .corner, isShown, !model.gate.isPaused else { return }
        let screens = Self.screenInfos()
        guard screens.count > 1, let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        if screenFollow.current == nil {
            screenFollow = RioScreenFollowDebounce(current: homeDisplayID ?? RioScreenChoice.dockScreenID(screens: screens))
        }
        let target = RioScreenChoice.screenID(
            windowBounds: Self.frontmostWindowBounds(),
            mouse: NSEvent.mouseLocation,
            screens: screens,
            primaryHeight: primaryHeight
        )
        guard let destination = screenFollow.observe(target: target, now: RioCompanionClock.now, isBlocked: followIsBlocked) else { return }
        poof(toDisplay: destination, isPrimary: destination == RioScreenChoice.dockScreenID(screens: screens))
    }

    /// The frontmost app's frontmost normal window, in CG space. Reads only owner pid, layer,
    /// alpha and bounds.
    private static func frontmostWindowBounds() -> CGRect? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let entries = list.compactMap { info -> RioWindowEntry? in
            guard let owner = info[kCGWindowOwnerPID as String] as? Int32,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo)
            else { return nil }
            return RioWindowEntry(pid: owner, layer: layer, alpha: (info[kCGWindowAlpha as String] as? Double) ?? 1, bounds: bounds)
        }
        return RioScreenChoice.frontmostWindowBounds(in: entries, pid: pid)
    }

    /// He never relocates mid Dock run, trick, speech, dictation, confirmation or help card.
    var followIsBlocked: Bool {
        if model.run != nil || isMovingScreens || lastSpeaking || lastHelp || voiceIsActive { return true }
        let confirmationUp = NSApp.windows.contains { $0 is RioConfirmationPanel && $0.isVisible }
        if confirmationUp { return true }
        switch model.machine.mode(at: RioCompanionClock.now) {
        case .away, .sprint, .punch, .returning, .talking, .waking, .help: return true
        default: return false
        }
    }

    // MARK: The poof

    /// Fades him out, puts him in the new screen's corner and fades him back in: under 0.25 s.
    private func poof(toDisplay id: Int, isPrimary: Bool) {
        guard let panel else { return }
        isMovingScreens = true
        let half = RioScreenFollow.poofDuration / 2
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = half
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.homeDisplayID = isPrimary ? nil : id
                self.relayout()
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = half
                    panel.animator().alphaValue = 1
                }, completionHandler: { [weak self] in
                    MainActor.assumeIsolated { self?.isMovingScreens = false }
                })
            }
        })
    }
}
