import Foundation

// The multi-step agent loop (builder K). Every dependency is injected, so the loop is tested
// with a fake model, executor, observer and prompter. Each step the model proposes goes through
// validation, the sensitive-field and risky-step checks, and then the normal executor, so every
// existing safety rule still applies.

struct RioTaskLimits: Equatable {
    var maxSteps = 25
    var maxSeconds: TimeInterval = 180
    /// Consecutive executor failures before the task gives up.
    var maxConsecutiveFailures = 3
    /// Consecutive unusable model replies before the task gives up.
    var maxInvalidReplies = 3
    /// The same step this many times in a row is allowed; one more is a loop.
    var maxRepeats = 3
    /// Scrolling legitimately repeats.
    var maxScrollRepeats = 8
}

@MainActor protocol RioTaskObserving: AnyObject {
    func observe() async -> RioTaskObservation
    /// The frontmost process right now, for the last-moment "still the same app?" check.
    func currentProcessID() -> Int32?
}

extension RioTaskObserving {
    func currentProcessID() -> Int32? { nil }
}

@MainActor protocol RioTaskModelling: AnyObject {
    /// One model turn; returns the raw reply text. `imageDataURL` is the window screenshot, if any.
    func nextStep(system: String, user: String, imageDataURL: String?) async throws -> String
}

@MainActor protocol RioTaskUserPrompting: AnyObject {
    /// "Do this exact step?" True means go ahead. Silence counts as no.
    func confirmStep(title: String, detail: String) async -> Bool
    /// Hands control to the user (a password, a question). True means "continue", false means stop.
    func handBack(message: String) async -> Bool
}

@MainActor protocol RioTaskReporting: AnyObject {
    var isStopRequested: Bool { get }
    func begin(goal: String)
    func update(step: Int, text: String)
    func finish()
}

@MainActor
final class RioTaskRunner {
    private let observer: RioTaskObserving
    private let resolver: RioTaskTargetResolving
    private let model: RioTaskModelling
    private let prompter: RioTaskUserPrompting
    private let reporter: RioTaskReporting
    private let limits: RioTaskLimits
    private let clock: () -> Date
    private let sleep: (TimeInterval) async -> Void

    init(
        observer: RioTaskObserving,
        resolver: RioTaskTargetResolving,
        model: RioTaskModelling,
        prompter: RioTaskUserPrompting,
        reporter: RioTaskReporting,
        limits: RioTaskLimits = RioTaskLimits(),
        clock: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.observer = observer
        self.resolver = resolver
        self.model = model
        self.prompter = prompter
        self.reporter = reporter
        self.limits = limits
        self.clock = clock
        self.sleep = sleep
    }

    /// Mutable state of one run, kept together so the loop body stays small.
    private struct RunState {
        let start: Date
        var pausedSeconds: TimeInterval = 0
        var steps = 0
        var invalidReplies = 0
        var failures = 0
        var history: [RioTaskHistoryEntry] = []
        var lastStepKey: String?
        var repeats = 0
        var note: String?
        /// The app the task started in (security: pinned, the task aborts if it changes).
        var pinnedPID: Int32?
        /// The site the task is on, as `RioWebHostRules.originKey`.
        var pageOrigin: String?
        var pageURL: URL?
        /// After the agent's own `openURL`: the site it asked for, and how many observations
        /// may still show the old page while it loads.
        var pendingNavigation: URL?
        var pendingObservations = 0
    }

    private static let navigationGraceObservations = 3

    func run(goal: String, executor: RioActionExecuting) async -> RioActionResult {
        reporter.begin(goal: goal)
        defer { reporter.finish() }
        var state = RunState(start: clock())
        while true {
            if let stop = stopResult(state) { return stop }
            let observation = await observer.observe()
            if let abort = guardObservation(observation, state: &state) { return abort }
            let user = RioTaskPrompt.user(
                goal: goal, stepNumber: state.steps + 1, maxSteps: limits.maxSteps,
                history: state.history, observation: observation, note: state.note
            )
            state.note = nil
            let reply: String
            do {
                reply = try await model.nextStep(system: RioTaskPrompt.system, user: user, imageDataURL: observation.imageDataURL)
            } catch {
                return Task.isCancelled ? .cancelled : .failed(message: Self.message(for: error))
            }
            // A stop that arrived while the model was thinking wins over whatever it said.
            if let stop = stopResult(state) { return stop }
            switch RioTaskStepParser.parse(reply) {
            case .failure(let error):
                state.invalidReplies += 1
                if state.invalidReplies >= limits.maxInvalidReplies {
                    return .failed(message: "I couldn't work out the next step, so I stopped.")
                }
                state.note = "Your last reply was not valid (\(Self.describe(error))). Reply with exactly one valid JSON step."
            case .success(let step):
                state.invalidReplies = 0
                if let result = await perform(step, observation: observation, goal: goal, executor: executor, state: &state) {
                    return result
                }
            }
        }
    }

    // MARK: Pinning (app and site)

    /// Aborts when the window is one Rio must not read, the app changed, or the page moved to
    /// another site by anything but the agent's own `openURL`. Nil to carry on.
    private func guardObservation(_ observation: RioTaskObservation, state: inout RunState) -> RioActionResult? {
        if observation.isRestricted {
            return .failed(message: "I won't look at that window, so I stopped.")
        }
        if let pid = observation.processID {
            // The agent's own `openURL` can bring up the default browser, a different app: that is
            // accepted only when the page now showing is the one it asked for.
            let opened = state.pendingNavigation.flatMap(RioWebHostRules.originKey).map { $0 == observation.pageURL.flatMap(RioWebHostRules.originKey) } ?? false
            if let pinned = state.pinnedPID, pinned != pid, !opened {
                return .failed(message: "You switched to a different app, so I stopped.")
            }
            state.pinnedPID = pid
        }
        guard let url = observation.pageURL, let key = RioWebHostRules.originKey(url) else { return nil }
        defer { state.pageURL = url }
        guard let known = state.pageOrigin else { state.pageOrigin = key; return nil }
        if key == known {
            if state.pendingNavigation != nil {
                state.pendingObservations -= 1
                if state.pendingObservations <= 0 { state.pendingNavigation = nil }
            }
            return nil
        }
        if let requested = state.pendingNavigation, RioWebHostRules.originKey(requested) == key {
            state.pageOrigin = key
            state.pendingNavigation = nil
            return nil
        }
        return .failed(message: "The page moved to a different site, so I stopped. The page is where I left it.")
    }

    // MARK: Stop conditions

    private func elapsed(_ state: RunState) -> TimeInterval {
        clock().timeIntervalSince(state.start) - state.pausedSeconds
    }

    private func stopResult(_ state: RunState) -> RioActionResult? {
        if reporter.isStopRequested || Task.isCancelled { return .cancelled }
        if state.steps >= limits.maxSteps {
            return .failed(message: "I stopped after \(limits.maxSteps) steps without finishing. The page is where I left it.")
        }
        if elapsed(state) >= limits.maxSeconds {
            let minutes = Int(limits.maxSeconds / 60)
            return .failed(message: "I stopped after \(minutes) minutes without finishing. The page is where I left it.")
        }
        return nil
    }

    // MARK: One step

    /// Returns a result when the task is over, nil to carry on.
    private func perform(
        _ step: RioTaskStep, observation: RioTaskObservation, goal: String,
        executor: RioActionExecuting, state: inout RunState
    ) async -> RioActionResult? {
        switch step {
        case .done(let summary):
            return .done(summary: summary)
        case .ask(let question):
            state.steps += 1
            reporter.update(step: state.steps, text: "Waiting for you")
            guard await handBack(question, state: &state) else { return .cancelled }
            state.history.append(RioTaskHistoryEntry(step: state.steps, text: "Asked: \(question)", outcome: "the user continued"))
            return nil
        case .wait(let seconds, let narration):
            state.steps += 1
            reporter.update(step: state.steps, text: narration)
            await sleep(seconds)
            state.history.append(RioTaskHistoryEntry(step: state.steps, text: "Waited \(Int(seconds)) s", outcome: "ok"))
            return nil
        case .act(let action, let narration, let flagged):
            return await perform(action, narration: narration, flagged: flagged, observation: observation,
                                 goal: goal, executor: executor, state: &state)
        }
    }

    private func perform(
        _ action: RioAction, narration: String, flagged: Bool, observation: RioTaskObservation,
        goal: String, executor: RioActionExecuting, state: inout RunState
    ) async -> RioActionResult? {
        state.steps += 1
        reporter.update(step: state.steps, text: narration)
        let description = RioTaskDescriber.describe(action)
        if isLoop(description, action: action, state: &state) {
            return .failed(message: "I seem to be going in circles, so I stopped.")
        }
        if let reason = RioTaskSafety.handBackReason(for: action, focused: observation.focusedField) {
            guard await handBack("\(reason) Press Continue when you're done.", state: &state) else { return .cancelled }
            state.history.append(RioTaskHistoryEntry(step: state.steps, text: narration, outcome: "the user did this themselves"))
            return nil
        }
        if let pinned = state.pinnedPID, let now = observer.currentProcessID(), now != pinned {
            return .failed(message: "You switched to a different app, so I stopped.")
        }
        // Resolve the control the label really means before judging the step (security H2).
        let resolution = await resolver.resolveTarget(for: action)
        if let reason = RioTaskSafety.chromeHandBackReason(for: action, observation: observation, target: resolution) {
            guard await handBack("\(reason) Press Continue when you're done.", state: &state) else { return .cancelled }
            state.history.append(RioTaskHistoryEntry(step: state.steps, text: narration, outcome: "the user did this themselves"))
            return nil
        }
        let target: String?
        if case .click(let label, _) = action { target = label } else { target = observation.focusedField?.label }
        if case .confirm(let reason) = RioTaskSafety.risk(
            of: action, targetLabel: target, narration: narration, modelFlagged: flagged, goal: goal,
            resolution: resolution, currentPage: state.pageURL,
            focusInWebArea: observation.focusedInWebArea, focusIsAddressField: observation.focusedIsAddressField
        ) {
            let detail = context(observation) + description
            guard await confirm(title: reason, detail: detail, state: &state) else { return .cancelled }
        }
        if case .openURL(let url) = action {
            // The agent's own navigation: the next observations may show the new site.
            state.pendingNavigation = url
            state.pendingObservations = Self.navigationGraceObservations
        }
        return await execute(action, narration: narration, executor: executor, state: &state)
    }

    private func execute(
        _ action: RioAction, narration: String, executor: RioActionExecuting, state: inout RunState
    ) async -> RioActionResult? {
        let result = await executor.execute(action)
        switch result {
        case .cancelled:
            return .cancelled
        case .done:
            state.failures = 0
            state.history.append(RioTaskHistoryEntry(step: state.steps, text: narration, outcome: "ok"))
        case .failed(let message):
            state.failures += 1
            state.history.append(RioTaskHistoryEntry(step: state.steps, text: narration, outcome: "failed: \(message)"))
            if state.failures >= limits.maxConsecutiveFailures { return .failed(message: message) }
        }
        if case .openURL = action { await sleep(1.5) } else { await sleep(0.5) }
        return nil
    }

    private func isLoop(_ key: String, action: RioAction, state: inout RunState) -> Bool {
        if key == state.lastStepKey { state.repeats += 1 } else { state.lastStepKey = key; state.repeats = 1 }
        if case .browser = action { return state.repeats > limits.maxScrollRepeats }
        return state.repeats > limits.maxRepeats
    }

    // MARK: Asking the user (their time does not count against the budget)

    private func confirm(title: String, detail: String, state: inout RunState) async -> Bool {
        let began = clock()
        let answer = await prompter.confirmStep(title: title, detail: detail)
        state.pausedSeconds += clock().timeIntervalSince(began)
        return answer && !reporter.isStopRequested
    }

    private func handBack(_ message: String, state: inout RunState) async -> Bool {
        let began = clock()
        let answer = await prompter.handBack(message: message)
        state.pausedSeconds += clock().timeIntervalSince(began)
        return answer && !reporter.isStopRequested
    }

    private func context(_ observation: RioTaskObservation) -> String {
        let place = [observation.appName, observation.windowTitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " - ")
        return place.isEmpty ? "" : "In \(RioTaskPrompt.sanitizePageText(place, maxLength: 100)):\n"
    }

    // MARK: Messages

    private static func describe(_ error: RioTaskStepError) -> String {
        switch error {
        case .notJSON: return "it was not a JSON object"
        case .multipleSteps: return "it must be one step, not several"
        case .unknownStep: return "that step is not allowed"
        case .invalidField(let field): return "check the \(field) field"
        }
    }

    private static func message(for error: Error) -> String {
        if let llm = error as? RioSmartLLMError, llm == .notConfigured {
            return "I need an API key to do tasks. Set one up in Rio's settings."
        }
        return "I couldn't reach the AI service, so I stopped."
    }
}
