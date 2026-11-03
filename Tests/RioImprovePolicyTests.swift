import Foundation

enum RioImprovePolicyTests {
    static func run() {
        for id in ["com.apple.Terminal", "dev.warp.Warp-Stable", "dev.warp.Warp", "com.googlecode.iterm2",
                   "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty", "co.zeit.hyper"] {
            TestSupport.expect(RioImprovePolicy.refusesReplacement(bundleIdentifier: id), "\(id) is a terminal")
        }
        for id in ["com.apple.TextEdit", "com.apple.Notes", "com.google.Chrome", nil] as [String?] {
            TestSupport.expect(!RioImprovePolicy.refusesReplacement(bundleIdentifier: id), "\(id ?? "nil") is fine")
        }
        // Single-line selections never gain line breaks (a newline could submit or run something).
        TestSupport.expectEqual(
            RioImprovePolicy.sanitized(improved: "Thanks for the update.\nI'll send it today.", original: "thx for update ill send today"),
            "Thanks for the update. I'll send it today."
        )
        TestSupport.expectEqual(
            RioImprovePolicy.sanitized(improved: "Line one.\r\nLine two.", original: "line one line two"),
            "Line one. Line two."
        )
        // Multi-line selections keep their structure.
        TestSupport.expectEqual(
            RioImprovePolicy.sanitized(improved: "Hi Ali,\n\nThanks!", original: "hi ali\n\nthanks"),
            "Hi Ali,\n\nThanks!"
        )
    }
}
