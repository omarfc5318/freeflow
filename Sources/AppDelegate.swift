import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    /// The duplicate-copy check runs before AppState is built, so a second copy never touches
    /// the microphone, the hotkey tap or the history files before it leaves.
    let appState: AppState = {
        if AppDelegate.isDuplicateCopy() { exit(0) }
        // Reads the crash marker first: a launchd crash loop exits here, before AppState exists.
        _ = RioLaunchAtLogin.startup
        return AppState()
    }()
    var setupWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // (A second copy already left in the appState initializer above.)
        // A marker left by the last run means it crashed; a clean quit removes it below.
        let start = RioLaunchAtLogin.startup
        let recoveredFromCrash = start.recoveredFromCrash
        RioLaunchAtLogin.migrateAtLaunch()
        installTerminationSignalHandler()
        NetworkMonitor.shared.start()
        appState.bindRioCompanionState()
        // "Rio, undo" can delete the calendar events Rio adds.
        RioCalendarService.onEventCreated = { RioUndoJournal.shared.noteCreated(.calendarEvent(identifier: $0)) }
        // Clipboard history (memory only, concealed/password copies skipped) starts with the app.
        RioClipboardHistory.shared.start()
        RioCompanionHub.shared.attach(appState)
        if start.showLoopNotice { RioCompanionHub.shared.announceCrashLoopStopped() }
        if recoveredFromCrash { appState.rioRecoveredFromCrash = true }
        RioCompanionHub.shared.onStopPressed = { [weak self] in self?.appState.overlayManager.onStopButtonPressed?() }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowSetup),
            name: .showSetup,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowSettings),
            name: .showSettings,
            object: nil
        )

        if !appState.hasCompletedSetup {
            showSetupWindow()
        } else {
            appState.startHotkeyMonitoring()
            appState.startAccessibilityPolling()

            if !AXIsProcessTrusted() {
                appState.showAccessibilityAlert()
            }
        }

    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard appState.hasCompletedSetup else { return true }
        if !flag {
            showSettingsWindow()
        }
        return true
    }

    @objc func handleShowSetup() {
        // Single wizard at a time — opening a second leaks the first's
        // willClose observer and breaks the bail-restore.
        if let existing = setupWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let wasCompleted = appState.hasCompletedSetup
        appState.hasCompletedSetup = false
        appState.stopAccessibilityPolling()
        appState.stopHotkeyMonitoring()
        showSetupWindow()

        // Restore prior state if the user closes the wizard without completing.
        // completeSetup() flips hasCompletedSetup back to true before window.close(),
        // so the !hasCompletedSetup check below correctly skips the restore there.
        if wasCompleted, let window = setupWindow {
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self = self else { return }
                if !self.appState.hasCompletedSetup {
                    self.appState.hasCompletedSetup = true
                    self.appState.startHotkeyMonitoring()
                    self.appState.startAccessibilityPolling()
                    NSApp.setActivationPolicy(.accessory)
                }
                self.setupWindow = nil
            }
        }
    }

    @objc private func handleShowSettings() {
        showSettingsWindow()
    }

    private func showSettingsWindow() {
        NSApp.setActivationPolicy(.regular)

        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if settingsWindow == nil {
            presentSettingsWindow()
        } else {
            settingsWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func presentSettingsWindow() {
        let settingsView = SettingsView()
            .environmentObject(appState)
        let hostingView = NSHostingView(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppName.displayName
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            if self?.setupWindow == nil {
                NSApp.setActivationPolicy(.accessory)
            }
            self?.settingsWindow = nil
        }
    }


    func showSetupWindow() {
        NSApp.setActivationPolicy(.regular)

        let setupView = SetupView(onComplete: { [weak self] in
            self?.completeSetup()
        })
        .environmentObject(appState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = AppName.displayName
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: setupView)
        window.minSize = NSSize(width: 520, height: 680)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false

        self.setupWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func completeSetup() {
        appState.hasCompletedSetup = true
        setupWindow?.close()
        setupWindow = nil
        NSApp.setActivationPolicy(.accessory)
        appState.startHotkeyMonitoring()
        appState.startAccessibilityPolling()

        if !AXIsProcessTrusted() {
            appState.showAccessibilityAlert()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        RioCrashMarker.standard.endRun()
    }

    /// True when another copy of the same app is already running, however this one was started
    /// (launch agent, Terminal, `open -n`). It leaves quietly with a clean exit, so launchd does
    /// not restart it.
    fileprivate static func isDuplicateCopy() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { $0.processIdentifier != me }
    }

    private var terminationSignalSource: DispatchSourceSignal?

    /// `kill <pid>` (SIGTERM) is a request to quit, not a crash: quit cleanly so the marker is
    /// removed and launchd leaves Rio stopped.
    private func installTerminationSignalHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSignalSource = source
    }
}
