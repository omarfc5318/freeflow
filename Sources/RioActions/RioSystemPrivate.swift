import AppKit
import CoreBluetooth
import CoreGraphics
import Foundation
import ObjectiveC

// Private-framework access for builder I. Every symbol is looked up with dlopen/dlsym or the ObjC
// runtime and every failure is a nil/false, so a missing or changed symbol becomes a friendly
// message instead of a crash. Nothing here takes text from the user.

/// Bluetooth power through IOBluetooth's preference functions.
/// IMPORTANT: macOS kills a process that touches Bluetooth without NSBluetoothAlwaysUsageDescription in
/// its Info.plist (verified: SIGABRT from TCC in a bare binary). `unavailableReason` is checked first
/// and nothing is called while it is non-nil.
enum RioBluetoothPower {
    private typealias GetState = @convention(c) () -> Int32
    private typealias SetState = @convention(c) (Int32) -> Void
    private static let path = "/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth"

    /// Nil when it is safe to call into IOBluetooth; otherwise a message for the user.
    static var unavailableReason: String? {
        let usage = Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") as? String
        guard let usage, !usage.isEmpty else { return "I can't control Bluetooth in this build" }
        switch CBManager.authorization {
        case .denied, .restricted:
            return "Bluetooth access is off for Rio Dictate. Allow it in Privacy and Security"
        default:
            return nil
        }
    }

    /// Both calls can block while macOS shows the permission prompt, so they run off the main thread.
    static func isOn() async -> Bool? {
        guard unavailableReason == nil else { return nil }
        return await onWorker {
            guard let handle = dlopen(path, RTLD_NOW), let symbol = dlsym(handle, "IOBluetoothPreferenceGetControllerPowerState") else { return nil }
            return unsafeBitCast(symbol, to: GetState.self)() != 0
        }
    }

    /// True once the controller reports the requested state (polled for up to 2 s).
    static func set(_ isOn: Bool) async -> Bool {
        guard unavailableReason == nil else { return false }
        let applied: Bool? = await onWorker {
            guard let handle = dlopen(path, RTLD_NOW),
                  let setter = dlsym(handle, "IOBluetoothPreferenceSetControllerPowerState"),
                  let getter = dlsym(handle, "IOBluetoothPreferenceGetControllerPowerState") else { return nil }
            unsafeBitCast(setter, to: SetState.self)(isOn ? 1 : 0)
            for _ in 0..<20 {
                if (unsafeBitCast(getter, to: GetState.self)() != 0) == isOn { return true }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return false
        }
        return applied ?? false
    }

    private static func onWorker<T: Sendable>(_ work: @escaping @Sendable () -> T?) async -> T? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }
}

/// Night Shift through CoreBrightness's CBBlueLightClient.
@MainActor
enum RioNightShift {
    private static let path = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
    private typealias GetStatus = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
    private typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool) -> Void

    private static func client() -> NSObject? {
        guard dlopen(path, RTLD_NOW) != nil, let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type else { return nil }
        return cls.init()
    }

    /// The status struct starts with `active`, `enabled` (one byte each); 64 bytes is room to spare.
    static func isEnabled() -> Bool? {
        guard let client = client() else { return nil }
        let selector = NSSelectorFromString("getBlueLightStatus:")
        guard client.responds(to: selector), let imp = class_getMethodImplementation(type(of: client), selector) else { return nil }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        defer { buffer.deallocate() }
        memset(buffer, 0, 64)
        guard unsafeBitCast(imp, to: GetStatus.self)(client, selector, buffer) else { return nil }
        return buffer.load(fromByteOffset: 1, as: UInt8.self) != 0
    }

    /// True once the status reports the requested state (polled for up to 1 s).
    static func set(_ isOn: Bool) async -> Bool {
        guard let client = client() else { return false }
        let selector = NSSelectorFromString("setEnabled:")
        guard client.responds(to: selector), let imp = class_getMethodImplementation(type(of: client), selector) else { return false }
        unsafeBitCast(imp, to: SetEnabled.self)(client, selector, isOn)
        for _ in 0..<10 {
            if isEnabled() == isOn { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}

/// Built-in display brightness through DisplayServices.
@MainActor
enum RioDisplayBrightness {
    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
    private static let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"

    /// The built-in panel only. External displays and virtual displays answer with an error.
    private static func builtInDisplay() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        guard let handle = dlopen(path, RTLD_NOW) else { return nil }
        return dlsym(handle, name)
    }

    /// 0...100, or nil when this display can't report brightness.
    static func currentPercent() -> Int? {
        guard let id = builtInDisplay(), let getter = symbol("DisplayServicesGetBrightness") else { return nil }
        var value: Float = 0
        guard unsafeBitCast(getter, to: GetBrightness.self)(id, &value) == 0 else { return nil }
        return RioBrightness.percent(fromScalar: value)
    }

    static func set(percent: Int) -> Bool {
        guard let id = builtInDisplay(), let setter = symbol("DisplayServicesSetBrightness") else { return false }
        return unsafeBitCast(setter, to: SetBrightness.self)(id, RioBrightness.scalar(fromPercent: percent)) == 0
    }
}
