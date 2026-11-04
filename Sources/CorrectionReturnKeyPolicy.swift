import Foundation

/// The Return key reaches `CorrectionWatcher` inside the global event tap, before the app sees
/// it, so a fix made and sent within one poll is still learned. A cross-process Accessibility
/// read there must stay cheap: a slow or hung app would lag every Enter and can make macOS
/// disable the tap (Fn, the chord and Fix Last stop working). So the live read happens only when
/// the watched field has been answering quickly; otherwise the last polled value (at most one
/// poll old) stands in, and every read on the watched field has a short messaging timeout.
enum CorrectionReturnKeyPolicy {
    /// Accessibility messaging timeout for the watched field (polls and the Return read).
    static let messagingTimeout: Float = 0.25
    /// A poll read slower than this means the Return key uses the last polled value instead.
    static let liveReadBudget: TimeInterval = 0.03
    /// Fields longer than this are never read inside the tap.
    static let liveReadMaxLength = 20_000

    /// True when the Return key may read the field live. `lastReadSeconds` is how long the most
    /// recent poll read took (nil before any), `lastLength` that value's UTF-16 length.
    static func readsLive(lastReadSeconds: TimeInterval?, lastLength: Int?) -> Bool {
        guard let lastReadSeconds, lastReadSeconds <= liveReadBudget else { return false }
        return (lastLength ?? 0) <= liveReadMaxLength
    }

    /// True when the Return key may settle `value` (finding 90). A live read is the field as it is
    /// sent. The last polled value stands in only once it is known to have stopped changing: it
    /// was already settled, or a later poll saw it unchanged. A value from the very poll that saw
    /// a keystroke may be half-typed ("Gro" for "Groq"), so the settled state is left alone then.
    static func settlesOnReturn(isLiveRead: Bool, isPendingSettled: Bool, pendingSeenUnchanged: Bool) -> Bool {
        isLiveRead || isPendingSettled || pendingSeenUnchanged
    }
}
