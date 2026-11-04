import Foundation

/// Finding 93: the Return key's read of the watched field happens inside the event tap, so it
/// only reads live while the field answers quickly.
enum CorrectionReturnKeyPolicyTests {
    static func run() {
        TestSupport.expect(CorrectionReturnKeyPolicy.readsLive(lastReadSeconds: 0.002, lastLength: 300), "fast small field")
        TestSupport.expect(!CorrectionReturnKeyPolicy.readsLive(lastReadSeconds: nil, lastLength: nil), "no read yet")
        TestSupport.expect(!CorrectionReturnKeyPolicy.readsLive(lastReadSeconds: 0.2, lastLength: 300), "slow app")
        TestSupport.expect(!CorrectionReturnKeyPolicy.readsLive(lastReadSeconds: 0.002, lastLength: 40_000), "large field")
        TestSupport.expect(CorrectionReturnKeyPolicy.messagingTimeout < 1, "a hung app can't hold the tap for seconds")
    }
}
