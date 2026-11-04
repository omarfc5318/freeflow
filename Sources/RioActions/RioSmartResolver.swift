import Foundation

/// User-facing lines for the cases where the brain isn't available. They come back as an
/// `.answer`, so Rio shows and says them.
enum RioSmartMessages {
    static let offline = "I'm offline right now. I can still open apps, control music and windows."
    static let unreachable = "I couldn't reach my brain just now."
    static let disabled = "Smart actions are turned off in Settings."
    static let notConfigured = "I need an API key to work that out. Add one in Settings."
    static let tooSlow = "My brain took too long to answer. Try that again?"
    static let rateLimited = "I'm being rate-limited. Give me a few seconds and try again."
    static let rateLimitedLong = "I've hit my AI provider's limit for now. Try again in a few minutes."

    /// The truthful line for a 429, by how long the provider asked Rio to wait.
    static func rateLimited(retryAfter: TimeInterval) -> String {
        retryAfter > 60 ? rateLimitedLong : rateLimited
    }
}

/// The owner's command behind each runTask goal the resolver wrote (security review). The task
/// agent's safety exemptions ("you named this site", "you gave these details") must rest on what
/// the owner said, not on a goal a model wrote after reading an untrusted title or a failed step.
/// In memory only, a few entries, for a few minutes.
final class RioPlannedGoals: @unchecked Sendable {
    static let shared = RioPlannedGoals()
    static let lifetime: TimeInterval = 10 * 60
    static let maxEntries = 8

    private struct Entry {
        let goal: String
        let command: String
        let at: Date
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func record(goal: String, command: String, at: Date) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { $0.goal == goal || at.timeIntervalSince($0.at) > Self.lifetime }
        entries.append(Entry(goal: goal, command: command, at: at))
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
    }

    /// The owner's command when the resolver wrote `goal` recently; nil when it is the owner's own.
    func ownerCommand(forGoal goal: String, now: Date) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return entries.last { $0.goal == goal && now.timeIntervalSince($0.at) <= Self.lifetime }?.command
    }
}

/// Turns text the local parser couldn't place (or only guessed at) into actions with the
/// configured LLM. The reply is validated by `RioSmartResponseParser`, so only members of the
/// closed `RioAction` set (or an `.answer`) can come out. What is sent: the spoken command,
/// today's date and time zone, and the `RioSmartContext` (front app and window title, running and
/// installed app names, the previous command) plus, when re-planning, Rio's own message for the
/// step that failed.
struct RioSmartResolver: RioSmartResolving {
    /// A spoken command must not hang: past this, Rio says so and moves on.
    static let defaultTimeout: TimeInterval = 6

    private let llm: RioSmartLLMCompleting
    private let isEnabled: @Sendable () -> Bool
    private let isOnline: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private let timeZone: @Sendable () -> TimeZone
    private let timeout: TimeInterval
    private let plannedGoals: RioPlannedGoals

    init(
        llm: RioSmartLLMCompleting,
        isEnabled: @escaping @Sendable () -> Bool,
        isOnline: @escaping @Sendable () -> Bool,
        now: @escaping @Sendable () -> Date = { Date() },
        timeZone: @escaping @Sendable () -> TimeZone = { TimeZone.current },
        timeout: TimeInterval = RioSmartResolver.defaultTimeout,
        plannedGoals: RioPlannedGoals = .shared
    ) {
        self.plannedGoals = plannedGoals
        self.llm = llm
        self.isEnabled = isEnabled
        self.isOnline = isOnline
        self.now = now
        self.timeZone = timeZone
        self.timeout = timeout
    }

    /// The legacy entry point (no context): an unavailable brain comes back as a spoken answer.
    func resolve(_ text: String) async throws -> [RioAction] {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return [] }
        switch await resolve(RioSmartRequest(command: command, context: RioSmartContext())) {
        case .actions(let actions): return actions
        case .unavailable(let message), .failed(let message): return [.answer(message)]
        }
    }

    func resolve(_ request: RioSmartRequest) async -> RioSmartResolution {
        let command = request.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return .actions([]) }
        guard isEnabled() else { return .unavailable(RioSmartMessages.disabled) }
        guard isOnline() else { return .unavailable(RioSmartMessages.offline) }
        let moment = now()
        let zone = timeZone()
        // A world question with no Mac context gets the short prompt (rate limits); anything about
        // the Mac, the owner or a re-plan gets the full one.
        let context = request.context
        let hasMac = context.frontApp != nil || context.frontWindowTitle != nil || !context.runningApps.isEmpty || !context.installedApps.isEmpty
        let isWorldQuestion = request.attempt == nil && !hasMac && RioQuestionShape.isGeneralQuestion(command)
        let system = isWorldQuestion
            ? RioSmartPrompt.question(now: moment, timeZone: zone)
            : RioSmartPrompt.system(now: moment, timeZone: zone)
        let user = RioSmartPrompt.user(request: RioSmartRequest(command: command, context: request.context, attempt: request.attempt))
        switch await complete(system: system, user: user) {
        case .reply(let reply):
            let actions = RioSmartResponseParser.actions(from: reply, now: moment, timeZone: zone)
            for case .runTask(let goal) in actions {
                plannedGoals.record(goal: goal.trimmingCharacters(in: .whitespacesAndNewlines), command: command, at: moment)
            }
            return .actions(actions)
        case .timedOut:
            return .unavailable(RioSmartMessages.tooSlow)
        case .notConfigured:
            return .unavailable(RioSmartMessages.notConfigured)
        case .unreachable:
            return .unavailable(RioSmartMessages.unreachable)
        case .rateLimited(let wait):
            return .unavailable(RioSmartMessages.rateLimited(retryAfter: wait))
        }
    }

    private enum Completion: Sendable {
        case reply(String)
        case timedOut
        case notConfigured
        case unreachable
        case rateLimited(TimeInterval)
    }

    /// The model call raced against `timeout`; whichever finishes first wins and the other is
    /// cancelled, so a slow provider never holds the command.
    private func complete(system: String, user: String) async -> Completion {
        let llm = self.llm
        let nanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
        return await withTaskGroup(of: Completion.self) { group in
            group.addTask {
                do {
                    return .reply(try await llm.complete(system: system, user: user, maxOutputTokens: nil))
                } catch RioSmartLLMError.notConfigured {
                    return .notConfigured
                } catch RioSmartLLMError.rateLimited(let wait) {
                    return .rateLimited(wait)
                } catch {
                    return Task.isCancelled ? .timedOut : .unreachable
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: nanoseconds)
                return .timedOut
            }
            let first = await group.next() ?? .unreachable
            group.cancelAll()
            return first
        }
    }
}
