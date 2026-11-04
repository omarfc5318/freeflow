import AppKit
import CoreAudio
import CoreLocation
import CoreWLAN

/// Watches the Mac for the events triggers care about: a display connecting, the default audio
/// output changing (AirPods) and joining a Wi-Fi network. Observers are only installed for the
/// kinds a stored trigger needs, and removed when none is left. Never created in tests.
@MainActor
final class RioTriggerWatcher: NSObject, CWEventDelegate {
    private let onEvent: (RioSystemEvent) -> Void
    private var screenObserver: NSObjectProtocol?
    private var screenCount = NSScreen.screens.count
    private var audioListener: AudioObjectPropertyListenerBlock?
    private var isWatchingWiFi = false
    private var lastOutputName: String?

    init(onEvent: @escaping (RioSystemEvent) -> Void) { self.onEvent = onEvent }

    func update(for kinds: [RioTriggerKind]) {
        setDisplay(kinds.contains(.displayConnected))
        setAudio(kinds.contains { if case .audioOutput = $0 { return true } else { return false } })
        setWiFi(kinds.contains { $0.needsLocation })
    }

    // MARK: Displays

    private func setDisplay(_ on: Bool) {
        if on, screenObserver == nil {
            screenCount = NSScreen.screens.count
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let count = NSScreen.screens.count
                    if count > self.screenCount { self.onEvent(.displayConnected) }
                    self.screenCount = count
                }
            }
        } else if !on, let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
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
        Task { @MainActor in self.onEvent(.wifiJoined(ssid: ssid)) }
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
