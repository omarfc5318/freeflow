import Foundation

/// Turns a non-English spoken command (Arabic first) into English before Rio parses it.
///
/// English never takes a detour: the only work for an English transcript is one script check
/// (microseconds), so English commands are exactly as fast as before. For Arabic and other
/// non-Latin scripts: the built-in Gulf/MSA table answers instantly and offline; anything it
/// doesn't know goes to the configured LLM as text when online and allowed; if neither works the
/// transcript is returned unchanged and the normal "didn't understand" path runs.
@MainActor final class RioCommandTranslator {
    static let shared = RioCommandTranslator()

    private static let systemPrompt = """
        You translate a spoken voice command into English for a Mac assistant named Rio. The input is a transcript \
        in another language (often Arabic, Gulf dialect), sometimes mixed with English. Reply with the command as \
        one short English imperative sentence, keeping "Rio" if the name was said (ريو is Rio), and keeping app \
        names, numbers and people's names. Translate only the command words. Never translate the content: text to \
        type or write, a message to send, a reply, or a search query stays exactly as spoken, in its original \
        language and script, word for word. Use these forms: "type <text>", "text <name> saying <message>", \
        "reply saying <message>", "search for <query>", "play <song or artist> on <app>", "translate the selected \
        text to <language>". Example: "ريو ارسل لأحمد اني بتأخر شوي" becomes "Rio text Ahmed saying اني بتأخر شوي". \
        No quotes, no explanation. If it is not a command, translate it plainly.
        """

    private let llm: RioSmartLLMCompleting
    private let isAllowed: () -> Bool
    private let isOnline: () -> Bool

    init(
        llm: RioSmartLLMCompleting = RioSmartLLMClient(config: { RioSmartSettings.llmConfig() }, timeout: 5),
        isAllowed: @escaping () -> Bool = { RioSmartSettings.isEnabled },
        isOnline: @escaping () -> Bool = { NetworkMonitor.shared.isOnline }
    ) {
        self.llm = llm
        self.isAllowed = isAllowed
        self.isOnline = isOnline
    }

    /// Returns `transcript` unchanged when it's already English or can't be translated.
    func englishCommand(from transcript: String) async -> String {
        // A command is running: the translator (if on) steps aside while Rio answers.
        RioTranslatorMode.shared.noteCommandHeard()
        switch RioCommandTranslationPlan.plan(for: transcript) {
        case .unchanged:
            return transcript
        case .offline(let english):
            return english
        case .llm:
            guard isAllowed(), isOnline() else { return transcript }
            do {
                let reply = try await llm.complete(system: Self.systemPrompt, user: transcript, maxOutputTokens: 120)
                return RioCommandTranslationPlan.acceptedReply(reply) ?? transcript
            } catch {
                return transcript
            }
        }
    }
}
