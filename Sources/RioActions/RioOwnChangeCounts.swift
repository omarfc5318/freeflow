import Foundation

/// The pasteboard change counts Rio caused itself (its paste and the clipboard restore), so the
/// history poller skips them. Change counts only ever go up, so anything at or below the count
/// the poller has reached can never match again and is dropped: the set cannot grow forever,
/// and it is also capped as a backstop.
struct RioOwnChangeCounts: Equatable {
    static let capacity = 16

    private(set) var counts: Set<Int> = []

    mutating func insert(_ count: Int) {
        counts.insert(count)
        if counts.count > Self.capacity, let oldest = counts.min() { counts.remove(oldest) }
    }

    /// True (and forgets it) when `count` was Rio's own. Always prunes entries at or below `count`.
    mutating func consume(_ count: Int) -> Bool {
        let wasOwn = counts.contains(count)
        counts = counts.filter { $0 > count }
        return wasOwn
    }
}
