import AppKit
import Foundation
import Network

/// Live network-reachability tracker. A single long-running `NWPathMonitor`
/// keeps `isOnline` current so transcription error classification can tell a
/// real network outage apart from a slow provider — a hung socket trips the
/// request timeout, which otherwise looks identical to "the server is slow."
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.zachlatta.freeflow.network-monitor")
    private let lock = NSLock()
    private var started = false

    // Default to online so the first request, before the monitor's first path
    // update lands, is never wrongly blamed on the network.
    private var _isOnline = true
    private var lastPathSignature = ""

    private init() {}

    /// Current reachability. Safe to read from any thread.
    var isOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isOnline
    }

    /// Begin monitoring. Idempotent — call once at launch.
    func start() {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let online = path.status == .satisfied
            // A different route (Wi-Fi switch, VPN, cable) leaves pooled provider
            // connections dead; drop them so the next dictation opens fresh ones.
            let signature = "\(path.status)|" + path.availableInterfaces.map(\.name).joined(separator: ",")
            self.lock.lock()
            self._isOnline = online
            let changed = !self.lastPathSignature.isEmpty && signature != self.lastPathSignature
            self.lastPathSignature = signature
            self.lock.unlock()
            if changed { LLMAPITransport.resetSharedSession() }
        }
        monitor.start(queue: queue)
        // Connections idle across sleep are usually dead on wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { _ in
            LLMAPITransport.resetSharedSession()
        }
    }
}
