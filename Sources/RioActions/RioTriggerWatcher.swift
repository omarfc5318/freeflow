import AppKit
import CoreAudio
import CoreLocation
import CoreWLAN

/// Watches the Mac for the events triggers care about: a display connecting, the default audio
/// output changing (AirPods) and joining a Wi-Fi network. Observers are only installed for the
/// kinds a stored trigger needs, and removed when none is left. Never created in tests.
///
/// Sleep and wake are not connections: displays drop out while the Mac sleeps and come back on
/// wake, and Wi-Fi rejoins the same network. So for a minute after a wake only a display or a
/// network that was not there before the sleep counts. The built-in screen (lid opened in
/// clamshell mode) is never "connecting a display".
@MainActor
final class RioTriggerWatcher: NSObject, CWEventDelegate {
    private let onEvent: (RioSystemEvent) -> Void
    private var screenObserver: NSObjectProtocol?
    private var knownDisplays = RioTriggerWatcher.currentExternalDisplayIDs()
    private var audioListener: AudioObjectPropertyListenerBlock?
    private var isWatchingWiFi = false
    private var lastOutputName: String?
    private var sleepObservers: [NSObjectProtocol] = []
    /// Displays and the network as they were when the Mac (or its screens) went to sleep.
    private var displaysBeforeSleep: Set<CGDirectDisplayID>?
    private var ssidBeforeSleep: String?
    private var lastSSID: String?
    /// Until when after a wake the before-sleep snapshot is used.
    private var compareUntil: Date?
    /// Long enough for slow docks to bring their displays back.
    private static let wakeCompareSeconds: TimeInterval = 60

    init(onEvent: @escaping (RioSystemEvent) -> Void) {
        self.onEvent = onEvent
        super.init()
        observeSleep()
    }

    // MARK: Sleep and wake

    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            sleepObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteSleep() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            sleepObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteWake() }
            })
        }
    }

    private func noteSleep() {
        // The first notification wins: by the second, displays may already have dropped out.
        expireSleepSnapshot()
        compareUntil = nil
        if displaysBeforeSleep == nil { displaysBeforeSleep = knownDisplays }
        if ssidBeforeSleep == nil { ssidBeforeSleep = lastSSID }
    }

    private func noteWake() {
        compareUntil = Date().addingTimeInterval(Self.wakeCompareSeconds)
    }

    /// Drops the before-sleep snapshot once the minute after a wake is over.
    private func expireSleepSnapshot() {
        guard let compareUntil, Date() >= compareUntil else { return }
        self.compareUntil = nil
        displaysBeforeSleep = nil
        ssidBeforeSleep = nil
    }

    func update(for kinds: [RioTriggerKind]) {
        setDisplay(kinds.contains(.displayConnected))
        setAudio(kinds.contains { if case .audioOutput = $0 { return true } else { return false } })
        setWiFi(kinds.contains { $0.needsLocation })
    }

    // MARK: Displays

    private func setDisplay(_ on: Bool) {
        if on, screenObserver == nil {
            knownDisplays = Self.currentExternalDisplayIDs()
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.screensChanged() }
            }
        } else if !on, let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
    }

    private func screensChanged() {
        expireSleepSnapshot()
        let displays = Self.currentExternalDisplayIDs()
        defer { knownDisplays = displays }
        var added = displays.subtracting(knownDisplays)
        // Back from sleep: a display that was attached before it is not new.
        if let before = displaysBeforeSleep { added.subtract(before) }
        guard !added.isEmpty else { return }
        onEvent(.displayConnected)
    }

    /// Attached displays other than the built-in screen.
    private static func currentExternalDisplayIDs() -> Set<CGDirectDisplayID> {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let ids = NSScreen.screens.compactMap { ($0.deviceDescription[key] as? NSNumber)?.uint32Value }
        return Set(ids.filter { CGDisplayIsBuiltin($0) == 0 })
    }

    // MARK: Audio output

    private var outputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    private func setAudio(_ on: Bool) {
        if on, audioListener == nil {
            lastOutputName = Self.defaultOutputName()
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in self?.outputChanged() }
            }
            audioListener = listener
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outputAddress, .main, listener)
        } else if !on, let listener = audioListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outputAddress, .main, listener)
            audioListener = nil
        }
    }

    private func outputChanged() {
        guard let name = Self.defaultOutputName(), name != lastOutputName else { return }
        lastOutputName = name
        onEvent(.audioOutput(deviceName: name))
    }

    private static func defaultOutputName() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, &name) == noErr,
              let name else { return nil }
        return name.takeRetainedValue() as String
    }

    // MARK: Wi-Fi

    private func setWiFi(_ on: Bool) {
        let client = CWWiFiClient.shared()
        if on, !isWatchingWiFi {
            client.delegate = self
            lastSSID = client.interface()?.ssid()
            try? client.startMonitoringEvent(with: .ssidDidChange)
            isWatchingWiFi = true
        } else if !on, isWatchingWiFi {
            try? client.stopMonitoringAllEvents()
            client.delegate = nil
            isWatchingWiFi = false
        }
    }

    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        // The name is only readable with Location permission; without it nothing can match.
        guard let ssid = CWWiFiClient.shared().interface(withName: interfaceName)?.ssid(), !ssid.isEmpty else { return }
        Task { @MainActor in self.wifiJoined(ssid) }
    }

    private func wifiJoined(_ ssid: String) {
        expireSleepSnapshot()
        defer { lastSSID = ssid }
        // Rejoining the network it was on before the Mac slept is not arriving somewhere.
        if let before = ssidBeforeSleep, before == ssid { return }
        onEvent(.wifiJoined(ssid: ssid))
    }
}

/// Location permission, asked for only when the first Wi-Fi trigger is created (macOS 14 and later
/// hide the network name without it). Rio never reads or stores the location itself.
@MainActor
final class RioWiFiLocationAccess: NSObject, CLLocationManagerDelegate {
    static let shared = RioWiFiLocationAccess()
    private let manager = CLLocationManager()
    private var waiting: CheckedContinuation<Bool, Never>?

    var isAuthorized: Bool {
        let status = manager.authorizationStatus
        return status == .authorizedAlways || status == .authorized
    }

    func ensure() async -> Bool {
        if isAuthorized { return true }
        guard manager.authorizationStatus == .notDetermined, waiting == nil else { return false }
        manager.delegate = self
        return await withCheckedContinuation { continuation in
            waiting = continuation
            manager.requestWhenInUseAuthorization()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 90_000_000_000)
                self.finish()
            }
        }
    }

    private func finish() {
        guard let continuation = waiting else { return }
        waiting = nil
        continuation.resume(returning: isAuthorized)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if self.manager.authorizationStatus != .notDetermined { self.finish() }
        }
    }
}
