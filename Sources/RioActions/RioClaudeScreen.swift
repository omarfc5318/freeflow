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

    /// What the confirmation panel shows: the context's end, then the question. Bounded.
    var detail: String {
        let budget = max(0, Self.maxDetailLength - question.count - 1)
        guard budget > 1, !context.isEmpty else { return String(question.prefix(Self.maxDetailLength)) }
        let shown = context.count > budget ? "\u{2026}" + String(context.suffix(budget - 1)) : context
        return shown + "\n" + question
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
        let lines = cleanedLines(text, last: 40)
        return numberedPrompt(lines) ?? yesNoPrompt(lines)
    }

    private static func optionMatch(_ line: String) -> (number: Int, label: String)? {
        guard let groups = RioText.firstMatch(#"^(?:[❯›>▶]\s*)?(\d{1,2})[.)]\s+(.+)$"#, in: line),
              let number = groups[1].flatMap({ Int($0) }), let label = groups[2] else { return nil }
        return (number, label.trimmingCharacters(in: .whitespaces))
    }

    private static func isStatusLine(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        return glyphStarts.contains(first)
    }

    private static func numberedPrompt(_ lines: [String]) -> RioClaudePrompt? {
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
        return RioClaudePrompt(
            question: lines[questionIndex],
            context: context(above: questionIndex, in: lines),
            options: options,
            approveKey: approve.map { String($0.number) },
            denyKey: deny.map { String($0.number) }
        )
    }

    private static func yesNoPrompt(_ lines: [String]) -> RioClaudePrompt? {
        let pattern = #"\?\s*[\(\[]\s*y\s*/\s*n\s*[\)\]]\s*:?$"#
        let nonEmpty = lines.indices.filter { !lines[$0].isEmpty }
        guard let index = nonEmpty.suffix(2).first(where: { RioText.matches(pattern, lines[$0]) }) else { return nil }
        let after = nonEmpty.filter { $0 > index }
        guard after.isEmpty else { return nil }
        return RioClaudePrompt(
            question: lines[index], context: context(above: index, in: lines), options: [], approveKey: "y", denyKey: "n"
        )
    }

    private static func isStanding(_ label: String) -> Bool {
        let lowered = label.lowercased()
        return standingPhrases.contains { lowered.contains($0) }
    }

    /// Up to 14 lines above the question, stopping at the previous Claude message.
    private static func context(above index: Int, in lines: [String]) -> String {
        var collected = [String]()
        var cursor = index - 1
        while cursor >= 0, collected.count < 14 {
            let line = lines[cursor]
            if isStatusLine(line), line.first != ">" { break }
            collected.append(line)
            cursor -= 1
        }
        var result = [String]()
        for line in collected.reversed() {
            if line.isEmpty, result.last?.isEmpty ?? true { continue }
            result.append(line)
        }
        while result.last?.isEmpty == true { result.removeLast() }
        return result.joined(separator: "\n")
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
