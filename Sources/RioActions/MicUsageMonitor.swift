import CoreAudio
import Foundation

/// CoreAudio-backed list of processes with an audio-input client (macOS 14+).
struct CoreAudioInputProcessSource: AudioInputProcessSource {
    func inputProcesses() -> [AudioInputProcess] {
        guard #available(macOS 14.0, *) else { return [] }
        return Self.queryProcesses()
    }

    @available(macOS 14.0, *)
    private static func queryProcesses() -> [AudioInputProcess] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.compactMap(process(for:))
    }

    @available(macOS 14.0, *)
    private static func process(for object: AudioObjectID) -> AudioInputProcess? {
        guard let pid: Int32 = value(of: kAudioProcessPropertyPID, on: object),
              let running: UInt32 = value(of: kAudioProcessPropertyIsRunningInput, on: object) else { return nil }
        return AudioInputProcess(pid: pid, bundleID: bundleID(of: object), isRunningInput: running != 0)
    }

    private static func value<T>(of selector: AudioObjectPropertySelector, on object: AudioObjectID) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }

    @available(macOS 14.0, *)
    private static func bundleID(of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var name: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }
}

enum MicUsageMonitor {
    /// True while a process other than Rio is capturing from an input device (a call, a recording).
    /// Always false before macOS 14, where CoreAudio has no per-process list.
    static func isOtherAppUsingMicrophone() -> Bool {
        MicUsageDecision.isOtherAppUsingMicrophone(
            CoreAudioInputProcessSource(),
            ownPID: ProcessInfo.processInfo.processIdentifier
        )
    }
}
