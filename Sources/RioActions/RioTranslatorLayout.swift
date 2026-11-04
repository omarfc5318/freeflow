import CoreGraphics
import Foundation

/// Where the subtitle card sits and when a conversation-mode command is worth a second listen.
/// Pure (CoreGraphics and Foundation only).
enum RioTranslatorLayout {
    static let captionWidth: CGFloat = 520
    static let minimumCaptionWidth: CGFloat = 260
    /// Clear of the bear's body and its speech card, which sit at the left edge.
    static let leadingGap: CGFloat = 96
    static let edgeInset: CGFloat = 14
    static let groundInset: CGFloat = 4

    /// Cocoa coordinates (origin bottom-left). The card sits on the ground line to the right of the
    /// bear, as wide as fits, never past the right edge of the visible area; `height` is its content height.
    static func captionFrame(screenFrame: CGRect, visibleFrame: CGRect, height: CGFloat) -> CGRect {
        let x = visibleFrame.minX + edgeInset + leadingGap
        let room = visibleFrame.maxX - edgeInset - x
        let width = max(min(captionWidth, room), min(minimumCaptionWidth, max(room, 0)))
        let clampedHeight = min(height, visibleFrame.height - 2 * edgeInset)
        return CGRect(x: x, y: screenFrame.minY + groundInset, width: width, height: max(clampedHeight, 0))
    }
}

/// Conversation mode hears with an on-device English recognizer, so Arabic spoken after "Rio"
/// comes out as English-looking nonsense. When that text doesn't begin like an English command,
/// the command's audio is transcribed again with Whisper. Plain English commands never are, so
/// they get no extra delay.
enum RioCommandRecheckGate {
    static let englishLeads: Set<String> = [
        "open", "launch", "quit", "close", "hide", "switch", "go", "show", "play", "pause", "resume", "skip",
        "next", "previous", "volume", "turn", "set", "mute", "unmute", "lock", "take", "screenshot", "type",
        "write", "search", "google", "look", "stop", "undo", "help", "text", "message", "imessage", "reply",
        "read", "summarize", "summarise", "explain", "translate", "say", "what", "whats", "how", "hows",
        "remind", "start", "cancel", "empty", "press", "click", "check", "battery", "brightness", "make", "put",
        "move", "maximize", "minimize", "tell", "remember", "recall", "forget", "when", "where", "who", "why",
        "can", "could", "please", "join", "send", "email", "add", "create", "find", "copy", "paste", "bring",
        "fix", "improve", "calculate", "is", "are", "do", "does", "dark", "light", "enable", "disable", "dim",
        "lower", "raise", "increase", "decrease", "unlock", "clear", "run", "focus", "activate", "navigate",
        "visit", "fill", "describe", "draft", "note", "timer", "ok", "okay", "hey", "uh", "um", "yo", "no", "yes",
        // Questions ("Rio, which planet is the biggest") and the wave 4-5 commands: re-reading them
        // with Whisper only adds up to three seconds before the answer.
        "which", "whose", "whom", "will", "would", "should", "shall", "did", "was", "were", "has", "have", "had",
        "am", "may", "might", "define", "give", "list", "convert", "spell", "answer", "approve", "deny", "watch",
        "organize", "organise", "clean", "tidy", "record", "every", "weather", "news", "quick",
    ]

    /// `onDeviceText` is what the English recognizer heard after "Rio".
    static func shouldRecheck(onDeviceText: String) -> Bool {
        let words = onDeviceText.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard let first = words.first else { return true }
        return !englishLeads.contains(first)
    }
}
