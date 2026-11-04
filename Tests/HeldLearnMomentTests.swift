import Foundation

/// Finding 95: a held "Learned" sign belongs to the dictation it was held for.
enum HeldLearnMomentTests {
    static func run() {
        // Shown as the dictation closes with a paste.
        var shown = HeldLearnMoment()
        shown.hold(.learned("Nashwa"), now: 100)
        shown.sessionStarted(now: 100.01)
        shown.sessionEnded(now: 130)
        TestSupport.expectEqual(shown.take(now: 130), .learned("Nashwa"))
        TestSupport.expect(shown.take(now: 130) == nil, "shown once")

        // The dictation ended another way: dropped, never shown after a later dictation.
        var dropped = HeldLearnMoment()
        dropped.hold(.learned("Hala"), now: 100)
        dropped.sessionStarted(now: 100.01)
        dropped.sessionEnded(now: 105)
        dropped.dropIfSessionEnded()
        dropped.sessionStarted(now: 200)
        dropped.sessionEnded(now: 210)
        TestSupport.expect(dropped.take(now: 210) == nil, "dropped after its own dictation")

        // Even without the drop, a later dictation is past the expiry.
        var stale = HeldLearnMoment()
        stale.hold(.learned("Hala"), now: 100)
        stale.sessionStarted(now: 100.01)
        stale.sessionEnded(now: 105)
        stale.sessionStarted(now: 200)
        stale.sessionEnded(now: 210)
        TestSupport.expect(stale.take(now: 210) == nil, "stale sign expires")

        // A start that never happened: the next dictation doesn't inherit the sign.
        var orphan = HeldLearnMoment()
        orphan.hold(.learned("Claude"), now: 100)
        orphan.sessionStarted(now: 160)
        orphan.sessionEnded(now: 170)
        TestSupport.expect(orphan.take(now: 170) == nil, "orphaned sign dropped")

        // A new sign held for the next dictation survives the previous one's drop timer.
        var next = HeldLearnMoment()
        next.hold(.alreadyKnown("Claude"), now: 100)
        next.sessionStarted(now: 100.01)
        next.sessionEnded(now: 101)
        next.hold(.learned("Hala"), now: 101.5)
        next.dropIfSessionEnded()
        next.sessionStarted(now: 101.6)
        next.sessionEnded(now: 120)
        TestSupport.expectEqual(next.take(now: 120), .learned("Hala"))
    }
}
