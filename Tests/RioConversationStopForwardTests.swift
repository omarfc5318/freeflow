import Foundation

/// Finding 91: silence words never pause the owner's music, and a stop just after Rio finished
/// talking counts as having stopped him.
enum RioConversationStopForwardTests {
    private static func forwarded(
        _ transcript: String, stopped: Bool = false, speaking: Bool = false, since: TimeInterval? = nil
    ) -> String? {
        RioConversationStopForward.forwardedCommand(
            for: transcript, stoppedSomething: stopped, isRioSpeaking: speaking, secondsSinceRioSpoke: since
        )
    }

    static func run() {
        // A plain stop with nothing of Rio's going pauses media (the parser's stop).
        for plain in ["stop", "stop it", "okay okay stop", "Rio, stop", "stop stop stop", "وقف", "توقف"] {
            TestSupport.expect(forwarded(plain) == "stop", "\(plain) is a plain stop")
        }
        // Silence words only ever ask Rio to stop talking.
        for quiet in ["be quiet", "quiet", "shut up", "enough", "that's enough", "hush", "silence", "stop talking",
                      "Rio, shut up", "stop shut up", "اسكت", "كفاية", "كفايه", "كفى", "بس", "خلاص"] {
            TestSupport.expect(forwarded(quiet) == nil, "\(quiet) never pauses media")
        }
        // Aborts never go on.
        TestSupport.expectEqual(forwarded("cancel"), nil)
        TestSupport.expectEqual(forwarded("forget it"), nil)
        // Something was stopped, Rio is talking, or he just finished: nothing more.
        TestSupport.expectEqual(forwarded("stop", stopped: true), nil)
        TestSupport.expectEqual(forwarded("stop", speaking: true), nil)
        TestSupport.expectEqual(forwarded("stop", since: 1.0), nil)
        TestSupport.expectEqual(forwarded("stop", since: RioConversationBargeIn.echoTailSeconds + 0.5), "stop")
        // Not a stop at all.
        TestSupport.expectEqual(forwarded("stop the music"), nil)
    }
}
