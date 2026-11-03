import Foundation

/// User-facing lines for the cases where the brain isn't available. They come back as an
/// `.answer`, so Rio shows and says them.
enum RioSmartMessages {
    static let offline = "I'm offline right now. I can still open apps, control music and windows."
    static let unreachable = "I couldn't reach my brain just now."
    static let disabled = "Smart actions are turned off in Settings."
    static let notConfigured = "I need an API key to work that out. Add one in Settings."
}

/// Turns text the local parser couldn't place into actions with the configured LLM. The reply is
/// validated by `RioSmartResponseParser`, so only members of the closed `RioAction` set (or an
/// `.answer`) can come out. Only the spoken command and today's date and time zone are sent.
struct RioSmartResolver: RioSmartResolving {
    private let llm: RioSmartLLMCompleting
    private let isEnabled: @Sendable () -> Bool
    private let isOnline: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private let timeZone: @Sendable () -> TimeZone

    init(
        llm: RioSmartLLMCompleting,
        isEnabled: @escaping @Sendable () -> Bool,
        isOnline: @escaping @Sendable () -> Bool,
        now: @escaping @Sendable () -> Date = { Date() },
        timeZone: @escaping @Sendable () -> TimeZone = { TimeZone.current }
    ) {
        self.llm = llm
        self.isEnabled = isEnabled
        self.isOnline = isOnline
        self.now = now
        self.timeZone = timeZone
    }

    func resolve(_ text: String) async throws -> [RioAction] {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return [] }
        guard isEnabled() else { return [.answer(RioSmartMessages.disabled)] }
        guard isOnline() else { return [.answer(RioSmartMessages.offline)] }
        let moment = now()
        let zone = timeZone()
        do {
            let reply = try await llm.complete(
                system: RioSmartPrompt.system(now: moment, timeZone: zone),
                user: RioSmartPrompt.user(command: command),
                maxOutputTokens: nil
            )
            return RioSmartResponseParser.actions(from: reply, now: moment, timeZone: zone)
        } catch RioSmartLLMError.notConfigured {
            return [.answer(RioSmartMessages.notConfigured)]
        } catch {
            return [.answer(RioSmartMessages.unreachable)]
        }
    }
}
