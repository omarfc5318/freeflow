import CoreAudio
import Foundation

/// CoreAudio's per-process list (macOS 14+): which processes are sending audio out right now.
/// Reads only pids, bundle identifiers and a flag; never audio. Before macOS 14 it lists nothing,
/// so playback falls back to asking Spotify and Music only.
enum RioAudioOutputMonitor {
    static func isOtherAppPlaying() -> Bool {
        RioOtherAudio.isOtherAppPlaying(
            processes(), ownPID: ProcessInfo.processInfo.processIdentifier,
            isOtherAppUsingMicrophone: MicUsageMonitor.isOtherAppUsingMicrophone()
        )
    }

    private static func processes() -> [RioAudioOutputProcess] {
        guard #available(macOS 14.0, *) else { return [] }
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
    private static func process(for object: AudioObjectID) -> RioAudioOutputProcess? {
        guard let pid: Int32 = value(of: kAudioProcessPropertyPID, on: object),
              let running: UInt32 = value(of: kAudioProcessPropertyIsRunningOutput, on: object) else { return nil }
        return RioAudioOutputProcess(pid: pid, bundleID: bundleID(of: object), isRunningOutput: running != 0)
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
