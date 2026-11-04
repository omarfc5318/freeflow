import Foundation

enum AudioCallbackSlotsTests {
    static func run() {
        levelHandlerSurvivesManyReadsAndSmallStackRelease()
        pcm16HandlerRoundTripsAcrossThreads()
    }

    /// Regression for the build-115 crash: reading the handler once per audio buffer must not
    /// grow a reabstraction-thunk chain that overflows a small stack when it is released.
    private static func levelHandlerSurvivesManyReadsAndSmallStackRelease() {
        let counter = CallCounter()
        var store: LevelSampleHandlerStore? = LevelSampleHandlerStore()
        store?.callback = { _, _ in counter.increment() }
        for _ in 0..<100_000 {
            store?.callback?(0.5, 0.01)
        }
        TestSupport.expectEqual(counter.value, 100_000)

        let box = StoreBox(store)
        store = nil
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.store?.callback = nil
            box.store = nil
            done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        let result = done.wait(timeout: .now() + 10)
        TestSupport.expect(result == .success, "releasing the level handler on a 512 KB stack finished")
    }

    private static func pcm16HandlerRoundTripsAcrossThreads() {
        let store = PCM16SamplesHandlerStore()
        let counter = CallCounter()
        store.callback = { _ in counter.increment() }
        let group = DispatchGroup()
        for _ in 0..<4 {
            DispatchQueue.global().async(group: group) {
                for _ in 0..<5_000 { store.callback?(Data([1])) }
            }
        }
        for _ in 0..<500 {
            store.callback = { _ in counter.increment() }
        }
        group.wait()
        store.callback = nil
        TestSupport.expect(store.callback == nil, "cleared handler reads nil")
        TestSupport.expect(counter.value > 0, "handler ran")
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class StoreBox: @unchecked Sendable {
    var store: LevelSampleHandlerStore?
    init(_ store: LevelSampleHandlerStore?) { self.store = store }
}
