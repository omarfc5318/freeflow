import Foundation

/// Thread-safe holders for the recorder's per-buffer callbacks.
///
/// The closure lives inside a struct slot on purpose. When a bare function type was the state
/// of an `OSAllocatedUnfairLock`, every `withLock` read passed it `inout` through generics and
/// wrote it back wrapped in a fresh reabstraction thunk, so the chain grew by one layer per
/// audio buffer. Clearing it later freed thousands of nested contexts recursively on the capture
/// queue and overflowed its small stack (the build-115 crash). A concrete struct field is not
/// re-wrapped when read, so the closure stays one layer deep no matter how often it is read.
struct LevelSampleSlot {
    var callback: (@Sendable (Float, TimeInterval) -> Void)?
}

struct PCM16SamplesSlot {
    var callback: ((Data) -> Void)?
}

/// Set and cleared on the main thread, read on the capture queue for every buffer.
final class LevelSampleHandlerStore: @unchecked Sendable {
    private let lock = NSLock()
    private var slot = LevelSampleSlot()

    var callback: (@Sendable (Float, TimeInterval) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return slot.callback
        }
        set {
            lock.lock()
            let old = slot.callback
            slot.callback = newValue
            lock.unlock()
            withExtendedLifetime(old) {}
        }
    }
}

/// Same contract for the realtime-transcription PCM16 stream: main writes, capture queue reads.
final class PCM16SamplesHandlerStore: @unchecked Sendable {
    private let lock = NSLock()
    private var slot = PCM16SamplesSlot()

    var callback: ((Data) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return slot.callback
        }
        set {
            lock.lock()
            let old = slot.callback
            slot.callback = newValue
            lock.unlock()
            withExtendedLifetime(old) {}
        }
    }
}
