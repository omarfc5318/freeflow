import AppKit
import Foundation

/// Calls `onTap` on the main actor for every three-finger tap on any trackpad. Reads raw
/// touches from Apple's private MultitouchSupport framework, loaded at run time with
/// dlopen/dlsym so nothing is linked and a missing framework just makes `start()` fail.
/// The touch callback runs on a background thread; only the pure `TapGestureDetector` sees
/// it, and the main actor is touched only when a tap is detected.
///
/// MultitouchSupport ABI relied on (macOS 13 through 26, unchanged for years):
///   MTDeviceCreateList() -> CFArray of MTDeviceRef   (+1 retained)
///   MTRegisterContactFrameCallback(device, callback) / MTUnregisterContactFrameCallback
///   MTDeviceStart(device, 0) / MTDeviceStop(device)
///   callback(device, MTTouch *touches, Int32 count, Double timestamp, Int32 frame) -> Int32
///   MTTouch is 96 bytes: identifier Int32 @16, state Int32 @20 (3 make-touch, 4 touching),
///   normalized x Float @32, y Float @36, size Float @48.
final class ThreeFingerTapMonitor {
    private let onTap: @MainActor () -> Void
    private let lock = NSLock()
    private var isRunning = false
    private var devices: CFArray?
    private var sinkID: UUID?
    private var detectors: [Int: TapGestureDetector] = [:]
    private var wakeObserver: NSObjectProtocol?

    init(onTap: @escaping @MainActor () -> Void) {
        self.onTap = onTap
    }

    deinit { stop() }

    /// Starts listening. False when MultitouchSupport can't be loaded or no trackpad exists.
    func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isRunning { return true }
        guard let library = MultitouchLibrary.shared, startDevices(using: library) else { return false }
        isRunning = true
        sinkID = MultitouchDispatcher.shared.addSink { [weak self] device, frame in
            self?.handle(frame, from: device)
        }
        // Devices stop streaming across sleep; re-register after wake.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.restartAfterWake() }
        return true
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }
        isRunning = false
        if let sinkID { MultitouchDispatcher.shared.removeSink(sinkID) }
        sinkID = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        if let library = MultitouchLibrary.shared { stopDevices(using: library) }
        detectors.removeAll()
    }

    // MARK: Devices (caller holds the lock)

    private func deviceList(_ array: CFArray) -> [UnsafeMutableRawPointer] {
        (0..<CFArrayGetCount(array)).compactMap { CFArrayGetValueAtIndex(array, $0) }.map { UnsafeMutableRawPointer(mutating: $0) }
    }

    private func startDevices(using library: MultitouchLibrary) -> Bool {
        guard let list = library.createDeviceList()?.takeRetainedValue() else { return false }
        let found = deviceList(list)
        guard !found.isEmpty else { return false }
        for device in found {
            library.register(device, multitouchContactCallback)
            _ = library.start(device, 0)
        }
        devices = list
        return true
    }

    private func stopDevices(using library: MultitouchLibrary) {
        guard let list = devices else { return }
        for device in deviceList(list) {
            library.unregister(device, multitouchContactCallback)
            _ = library.stop(device)
        }
        devices = nil
    }

    private func restartAfterWake() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning, let library = MultitouchLibrary.shared else { return }
        stopDevices(using: library)
        detectors.removeAll()
        if !startDevices(using: library) { isRunning = false }
    }

    // MARK: Touch frames (background thread)

    private func handle(_ frame: TouchFrame, from device: Int) {
        lock.lock()
        guard isRunning else { lock.unlock(); return }
        var detector = detectors[device] ?? TapGestureDetector()
        let tapped = detector.process(frame)
        detectors[device] = detector
        lock.unlock()
        guard tapped else { return }
        let callback = onTap
        Task { @MainActor [weak self] in
            guard let self, self.running else { return }
            callback()
        }
    }

    private var running: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning
    }
}

// MARK: - MultitouchSupport loading

private final class MultitouchLibrary {
    typealias ContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    typealias Register = @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void
    typealias StartStop = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
    typealias Stop = @convention(c) (UnsafeMutableRawPointer) -> Int32

    let createDeviceList: CreateList
    let register: Register
    let unregister: Register
    let start: StartStop
    let stop: Stop

    static let shared: MultitouchLibrary? = MultitouchLibrary()

    private init?() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_LAZY),
              let list = dlsym(handle, "MTDeviceCreateList"),
              let register = dlsym(handle, "MTRegisterContactFrameCallback"),
              let unregister = dlsym(handle, "MTUnregisterContactFrameCallback"),
              let start = dlsym(handle, "MTDeviceStart"),
              let stop = dlsym(handle, "MTDeviceStop")
        else { return nil }
        createDeviceList = unsafeBitCast(list, to: CreateList.self)
        self.register = unsafeBitCast(register, to: Register.self)
        self.unregister = unsafeBitCast(unregister, to: Register.self)
        self.start = unsafeBitCast(start, to: StartStop.self)
        self.stop = unsafeBitCast(stop, to: Stop.self)
    }
}

/// The C callback has no context pointer, so frames go through one shared fan-out.
private final class MultitouchDispatcher: @unchecked Sendable {
    static let shared = MultitouchDispatcher()
    typealias Sink = (_ device: Int, _ frame: TouchFrame) -> Void

    private let lock = NSLock()
    private var sinks: [UUID: Sink] = [:]

    func addSink(_ sink: @escaping Sink) -> UUID {
        let id = UUID()
        lock.lock(); sinks[id] = sink; lock.unlock()
        return id
    }

    func removeSink(_ id: UUID) {
        lock.lock(); sinks[id] = nil; lock.unlock()
    }

    func deliver(device: Int, frame: TouchFrame) {
        lock.lock()
        let current = Array(sinks.values)
        lock.unlock()
        for sink in current { sink(device, frame) }
    }
}

private let mtTouchStride = 96
private let mtIdentifierOffset = 16
private let mtStateOffset = 20
private let mtXOffset = 32
private let mtYOffset = 36
private let mtSizeOffset = 48
private let mtStatesOfFingerOnPad: ClosedRange<Int32> = 3...4

private func multitouchContactCallback(
    _ device: UnsafeMutableRawPointer?,
    _ touches: UnsafeMutableRawPointer?,
    _ count: Int32,
    _ timestamp: Double,
    _ frameNumber: Int32
) -> Int32 {
    guard let device else { return 0 }
    var points: [TouchPoint] = []
    if let touches, count > 0, count <= 32 {
        let base = UnsafeRawPointer(touches)
        for index in 0..<Int(count) {
            let offset = index * mtTouchStride
            let state = base.loadUnaligned(fromByteOffset: offset + mtStateOffset, as: Int32.self)
            guard mtStatesOfFingerOnPad.contains(state) else { continue }
            points.append(TouchPoint(
                id: Int(base.loadUnaligned(fromByteOffset: offset + mtIdentifierOffset, as: Int32.self)),
                x: base.loadUnaligned(fromByteOffset: offset + mtXOffset, as: Float.self),
                y: base.loadUnaligned(fromByteOffset: offset + mtYOffset, as: Float.self),
                size: base.loadUnaligned(fromByteOffset: offset + mtSizeOffset, as: Float.self)
            ))
        }
    }
    MultitouchDispatcher.shared.deliver(
        device: Int(bitPattern: device),
        frame: TouchFrame(timestamp: timestamp, touches: points)
    )
    return 0
}
