import Foundation

/// What Rio's run history may keep for a command. Rio history is written to disk, so the
/// content of anything private (a message read aloud, a memory, the clipboard, the screen, a
/// translation, a task's result) is never stored: only a fixed label per kind of action.
enum RioHistoryPolicy {
    struct Entry: Equatable {
        let transcript: String
        let outcome: String
    }

    static let redactedTranscript = "(not saved)"

    /// The entry to store for a finished run. `outcomeText` is the normal summary or failure line
    /// and `didSucceed` is false for failures, cancels and "didn't understand".
    static func entry(transcript: String, actions: [RioAction], outcomeText: String, didSucceed: Bool) -> Entry {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let redactTranscript = actions.contains(where: redactsTranscript)
        let label = actions.lazy.compactMap(sensitiveLabel).first
        let outcome: String
        if let label {
            outcome = didSucceed ? label : "\(label) (didn't work)"
        } else {
            outcome = outcomeText
        }
        return Entry(transcript: redactTranscript ? redactedTranscript : trimmed, outcome: outcome)
    }

    /// Memory and clipboard commands carry the private content in what was said.
    private static func redactsTranscript(_ action: RioAction) -> Bool {
        switch action {
        case .remember, .recall, .forget, .clipboard, .addNote, .searchHistory, .notionAdd: return true
        default: return false
        }
    }

    /// A fixed label for actions whose result is private content. Nil for everything else.
    static func sensitiveLabel(for action: RioAction) -> String? {
        switch action {
        case .readAloud(let target):
            switch target {
            case .lastMessage: return "Read your last message"
            case .selection: return "Read your selection"
            case .page: return "Read the page"
            }
        case .remember: return "Saved a memory"
        case .recall: return "Recalled a memory"
        case .forget: return "Forgot a memory"
        case .clipboard: return "Used the clipboard"
        case .describeScreen: return "Looked at your screen"
        case .click: return "Clicked on your screen"
        case .fillField: return "Filled in a field"
        case .startTranslation: return "Started the translator"
        case .stopTranslation: return "Stopped the translator"
        case .speakLastTranslation: return "Said the last translation"
        case .runTask: return "Ran a task"
        case .selectionTask: return "Worked on your selection"
        case .answer: return "Answered a question"
        case .addNote: return "Added a note"
        case .searchHistory: return "Searched your dictations"
        case .editLastDictation: return "Rewrote your last dictation"
        case .writeForMe: return "Wrote something for you"
        case .smartPaste: return "Pasted transformed text"
        case .findThing: return "Looked for a file"
        case .copyTextFromScreen: return "Copied text from the screen"
        case .meeting: return "Used the meeting copilot"
        case .claudeCode: return "Talked to Claude Code"
        case .notionAdd: return "Added to Notion"
        default: return nil
        }
    }
}
