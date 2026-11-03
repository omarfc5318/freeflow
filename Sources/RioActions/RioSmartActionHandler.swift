import AppKit
import Foundation

/// Runs the smart and context actions: answers, texts, replies, reminders, tasks on the
/// selection and reading aloud. Returns nil for every action that isn't its own.
@MainActor
final class RioSmartActionHandler: RioActionHandling {
    static let shared = RioSmartActionHandler()

    private let llm: RioSmartLLMCompleting

    init(llm: RioSmartLLMCompleting = RioSmartLLMClient(config: { RioSmartSettings.llmConfig() })) {
        self.llm = llm
    }

    func handle(_ action: RioAction, executor: RioActionExecuting) async -> RioActionResult? {
        switch action {
        case .answer(let text):
            return .done(summary: text)
        case .sendMessage(let to, let body):
            return await RioMessageSender.send(to: to, body: body)
        case .replyInConversation(let body):
            return await RioContextReader.reply(body)
        case .createReminder(let title, let due):
            return await RioReminderStore.shared.create(title: title, due: due)
        case .selectionTask(let task):
            return await run(task, executor: executor)
        case .readAloud(let target):
            switch target {
            case .selection: return await RioContextReader.readSelection()
            case .lastMessage: return RioContextReader.readLastMessage()
            case .page: return await RioContextReader.readPage()
            }
        default:
            return nil
        }
    }

    // MARK: Selection tasks

    private func run(_ task: SelectionTask, executor: RioActionExecuting) async -> RioActionResult {
        guard RioSmartSettings.isEnabled else { return .failed(message: RioSmartMessages.disabled) }
        guard NetworkMonitor.shared.isOnline else { return .failed(message: RioSmartMessages.offline) }
        guard RioAX.isTrusted else { return .failed(message: RioContextReader.needsAccessibility) }
        guard let app = RioAX.frontmostApp(), let selected = await RioAX.selectedText(in: app) else {
            // "explain this" / "summarize this" with nothing selected means the window in front.
            switch task {
            case .explain: return await executor.execute(.describeScreen(question: "Explain what's in this window."))
            case .summarize: return await executor.execute(.describeScreen(question: "Summarize this window."))
            case .translate, .improve:
                return .failed(message: "I don't see any selected text. Select something first.")
            }
        }
        let output: String
        do {
            let reply = try await llm.complete(
                system: RioSelectionPrompts.system(for: task),
                user: RioSelectionPrompts.user(text: selected),
                maxOutputTokens: nil
            )
            output = RioSelectionPrompts.cleanOutput(reply)
        } catch RioSmartLLMError.notConfigured {
            return .failed(message: RioSmartMessages.notConfigured)
        } catch {
            return .failed(message: RioSmartMessages.unreachable)
        }
        guard !output.isEmpty else { return .failed(message: RioSmartMessages.unreachable) }

        switch task {
        case .summarize, .explain:
            return .done(summary: RioSmartText.limitSentences(output, maxSentences: 3, maxCharacters: 500))
        case .translate:
            return .done(summary: RioReadingText.condense([output], limit: RioContextReader.readLimit))
        case .improve:
            return await replaceSelection(in: app, original: selected, with: output)
        }
    }

    private func replaceSelection(in app: NSRunningApplication, original: String, with improved: String) async -> RioActionResult {
        guard !RioImprovePolicy.refusesReplacement(bundleIdentifier: app.bundleIdentifier) else {
            return .failed(message: "I won't paste over text in a terminal. Copy it from here instead: \(improved)")
        }
        let trimmedOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeImproved = RioImprovePolicy.sanitized(improved: improved, original: original)
        if safeImproved == trimmedOriginal { return .done(summary: "It already reads well") }
        // The model took a moment: the selection must still be there, unchanged. If it can't be
        // re-read, fail closed rather than paste over something else.
        guard let current = RioAX.axSelectedText(in: app), current == original else {
            return .failed(message: "Your selection changed, so I left it alone.")
        }
        let keepsTrailing = original.hasSuffix("\n") ? "\n" : ""
        guard await RioAX.paste(safeImproved + keepsTrailing, into: app) else {
            return .failed(message: "You switched apps, so I left your text alone.")
        }
        return .done(summary: "Improved your text")
    }
}
