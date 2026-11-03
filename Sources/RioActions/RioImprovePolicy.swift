import Foundation

/// Safety rules for "improve my selection", which pastes model-written text over the user's
/// selection. Pure, so it is unit-tested.
enum RioImprovePolicy {
    /// Terminals run what's pasted: a newline in model output could execute a command.
    private static let terminalBundlePrefixes = [
        "com.apple.Terminal", "dev.warp.", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty", "co.zeit.hyper", "com.github.wez.wezterm",
        "dev.zed.Zed-Terminal", "com.raggesilver.BlackBox",
    ]

    static func refusesReplacement(bundleIdentifier: String?) -> Bool {
        guard let id = bundleIdentifier else { return false }
        return terminalBundlePrefixes.contains { id == $0 || id.hasPrefix($0) }
    }

    /// A single-line selection is replaced with single-line text: line breaks (which could send a
    /// chat message or submit a form early) become spaces. Multi-line selections keep their shape.
    static func sanitized(improved: String, original: String) -> String {
        guard !original.contains(where: \.isNewline) else { return improved }
        return improved
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
