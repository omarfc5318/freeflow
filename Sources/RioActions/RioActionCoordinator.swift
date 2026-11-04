import Foundation

// The Rio action pipeline after transcription: strip the optional name, parse, execute.
// Pure of AppKit and AppState so it can be tested with fake collaborators.

protocol RioActionParsing {
    func parse(_ transcript: String) -> RioActionParse
    /// The parse plus how sure it is. Parsers that can't tell are always sure of `.actions`.
    func analyze(_ transcript: String) -> RioParseAnalysis
}

extension RioActionParsing {
    func analyze(_ transcript: String) -> RioParseAnalysis {
        let parse = parse(transcript)
        if case .unknown(let text) = parse { return RioParseAnalysis(parse: parse, isConfident: false, resolverText: text) }
        return RioParseAnalysis(parse: parse, isConfident: true, resolverText: transcript)
    }
}

@MainActor protocol RioActionExecuting: AnyObject {
    func execute(_ action: RioAction) async -> RioActionResult
}

/// Turns text the local parser could not place into actions (the LLM, wave 2). Must only ever
/// return members of the closed `RioAction` set.
protocol RioSmartResolving {
    func resolve(_ text: String) async throws -> [RioAction]
    /// Understanding-first routing: the command with context (and, when re-planning, the step
    /// that failed). Never throws; an unavailable brain says why.
    func resolve(_ request: RioSmartRequest) async -> RioSmartResolution
}

extension RioSmartResolving {
    func resolve(_ request: RioSmartRequest) async -> RioSmartResolution {
        do {
            return .actions(try await resolve(request.command))
        } catch {
            return .failed(RioActionText.resolverFailedMessage)
        }
    }
}

enum RioActionOutcome: Equatable {
    /// Nothing was said worth acting on; show nothing.
    case nothing
    case succeeded(String)
    case failed(String)
    case cancelled
    /// Not understood: the bear shrugs. The text that could not be placed is in
    /// `RioActionCoordinator.lastUnrecognized`.
    case unknown
}

/// Where a spoken command came from. The action key (Fn + Control) proves the owner is
/// speaking; conversation mode hears the room, so some actions need a second check there.
enum RioCommandSource: Equatable {
    case actionKey
    case conversation
    /// The owner's own scheduled commands, triggers and recorded macros (wave 4–5, builder P).
    /// Treated like the action key; actions that always confirm still confirm.
    case automation
    /// A text from the owner's iPhone (builder S). Nobody can press Return on the Mac from there,
    /// so anything that would need a confirmation is refused instead of asked.
    case phone

    /// Whether this source refuses `action` outright.
    func refuses(_ action: RioAction) -> Bool {
        // Claude Code can run commands: an automation never drives or approves it.
        if self == .automation, case .claudeCode(let command) = action {
            switch command {
            case .send, .approve: return true
            case .deny, .status: return false
            }
        }
        guard self == .phone else { return false }
        return action.requiresConfirmation || action.conversationAlwaysNeedsConfirmation
            || action.conversationNeedsConfirmationWhenUntrusted
    }
}

/// The "Trust conversation mode" setting. ON by default (owner decision, 2026-11-03).
enum RioTrustSetting {
    static let key = "rio_trust_conversation_mode"
    static var isTrusting: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}

extension RioAction {
    /// Heard by conversation mode, these inject input or change state. They run straight away
    /// while "Trust conversation mode" is on, and need a spoken "yes" (or Return) when it is off.
    var conversationNeedsConfirmationWhenUntrusted: Bool {
        switch self {
        case .typeText, .pressKeys, .fillField, .click, .runTask, .systemToggle, .quitApp:
            return true
        case .clipboard(let command):
            if case .pasteRecent = command { return true }
            return false
        default:
            return false
        }
    }

    /// Starting the translator sends the room's audio to a provider, so it is always confirmed
    /// when conversation mode asked for it, trusted or not.
    var conversationAlwaysNeedsConfirmation: Bool {
        switch self {
        case .startTranslation:
            return true
        // Automations later run with automation trust, so creating, changing or running one from an
        // untrusted channel would launder that trust: always ask in conversation mode, and (via
        // `RioCommandSource.refuses`) never from the phone.
        case .scheduleCommand, .addTrigger, .recordMacro, .runMacro, .removeAutomation:
            return true
        // "Tell Claude to …" drives a tool-capable agent (security review): always ask here, and
        // never from the phone.
        case .claudeCode(.send):
            return true
        default:
            return false
        }
    }
}

/// A confirmer that can also ask about an action that came from conversation mode (the panel
/// accepts a spoken "yes"). The coordinator uses it when the confirmer provides it.
@MainActor protocol RioConversationConfirming: AnyObject {
    func confirmConversationAction(_ action: RioAction) async -> Bool
}

enum RioActionText {
    static let unknownMessage = "I don't know how to do that yet"
    static let didntCatchMessage = "I didn't catch that"

    /// What Rio says when he could not place the words: it quotes what was heard so a
    /// mishearing ("We are hoping for a win") is obvious.
    static func unknownMessage(heard: String) -> String {
        let cleaned = heard.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{201C}\u{201D}"))
        guard !cleaned.isEmpty else { return unknownMessage }
        let clipped = cleaned.count > 80 ? String(cleaned.prefix(80)) + "..." : cleaned
        return "I heard \"\(clipped)\". Try again?"
    }
    static let resolverFailedMessage = "I couldn't work that out"

    /// After the first plan and every re-plan failed: what went wrong, said plainly.
    static func couldNotFinish(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return "I tried a few ways but couldn't finish that. \(trimmed)."
    }

    /// The short "now doing" line the corner bear and status text show.
    static func working(for action: RioAction) -> String {
        switch action {
        case .openApp(let name): return "Opening \(name)"
        case .quitApp(let name): return "Quitting \(name)"
        case .switchToApp(let name): return "Switching to \(name)"
        case .hideApp(let name): return "Hiding \(name)"
        case .openURL(let url): return "Opening \(url.host ?? "link")"
        case .webSearch: return "Searching"
        case .volume: return "Adjusting the volume"
        case .media: return "Controlling playback"
        case .lockScreen: return "Locking the screen"
        case .screenshot: return "Taking a screenshot"
        case .doNotDisturb: return "Changing Focus"
        case .window(let command): return "Arranging \(command.appName ?? "the window")"
        case .typeText: return "Typing"
        case .stopListening: return "Stopping"
        case .sendMessage: return "Preparing a message"
        case .createReminder: return "Creating a reminder"
        case .selectionTask: return "Working on your selection"
        case .replyInConversation: return "Writing a reply"
        case .readAloud: return "Reading"
        case .answer: return "Thinking"
        case .startTimer: return "Starting a timer"
        case .cancelTimer: return "Cancelling the timer"
        case .timerStatus: return "Checking the timer"
        case .undoLast: return "Undoing"
        case .showHelp: return "Here's what I can do"
        case .openFile(let query): return "Looking for \(query)"
        case .revealFile(let query): return "Finding \(query)"
        case .calendarAgenda: return "Checking your calendar"
        case .joinNextMeeting: return "Joining your meeting"
        case .createEvent: return "Adding it to your calendar"
        case .clipboard: return "Checking the clipboard"
        case .pressKeys: return "Pressing keys"
        case .browser: return "Controlling the browser"
        case .systemToggle: return "Changing a setting"
        case .brightness: return "Adjusting brightness"
        case .batteryStatus: return "Checking the battery"
        case .emptyTrash: return "Emptying the trash"
        case .describeScreen: return "Looking at your screen"
        case .click(let label, _): return "Clicking \(label)"
        case .fillField(let label, _): return "Filling in \(label)"
        case .runTask: return "Working on it step by step"
        case .remember: return "Remembering that"
        case .recall: return "Remembering"
        case .forget: return "Forgetting that"
        case .draftEmail: return "Drafting an email"
        case .addNote: return "Adding a note"
        case .calculate: return "Calculating"
        case .startTranslation: return "Starting the translator"
        case .stopTranslation: return "Stopping the translator"
        case .speakLastTranslation: return "Saying it"
        case .searchHistory: return "Searching what you've said"
        case .editLastDictation: return "Rewriting that"
        case .writeForMe: return "Writing it"
        case .smartPaste: return "Pasting it"
        case .scheduleCommand: return "Scheduling it"
        case .addTrigger: return "Setting that up"
        case .listAutomations: return "Checking your automations"
        case .removeAutomation: return "Removing it"
        case .recordMacro: return "Watching you"
        case .stopRecordingMacro: return "Saving that"
        case .runMacro(let name): return "Running \(name)"
        case .findThing(let query): return "Looking for \(query)"
        case .organizeDownloads: return "Tidying your Downloads"
        case .copyTextFromScreen: return "Reading the text"
        case .weather: return "Checking the weather"
        case .news: return "Checking the news"
        case .playMusic: return "Finding that"
        case .notionAdd: return "Adding it to Notion"
        case .canvasDue: return "Checking Canvas"
        case .meeting: return "Checking the call"
        case .claudeCode: return "Talking to Claude"
        }
    }
}

enum RioActionTranscript {
    /// Drops an optional leading "Rio" (with "yo"/"hey" before it, and the speech-to-text
    /// spellings of the name) and a trailing "bro". Only the very start counts, so
    /// "open Rio Grande" and "Riot police" are untouched.
    static func stripName(from transcript: String) -> String {
        var tokens = transcript.split(whereSeparator: \.isWhitespace).map(String.init)

        func normalized(_ token: String) -> String {
            token.lowercased()
                .replacingOccurrences(of: "'", with: "")
                .replacingOccurrences(of: "\u{2019}", with: "")
                .trimmingCharacters(in: CharacterSet.letters.inverted)
        }

        let greetings = TeddyCommand.greetings.union(["hey"])
        if let first = tokens.first {
            let word = normalized(first)
            if greetings.contains(word), tokens.count > 1, TeddyCommand.names.contains(normalized(tokens[1])) {
                tokens.removeFirst(2)
            } else if TeddyCommand.names.contains(word) {
                tokens.removeFirst()
            } else if word.hasPrefix("yo"), TeddyCommand.names.contains(String(word.dropFirst(2))) {
                tokens.removeFirst()
            }
        }
        if let last = tokens.last, TeddyCommand.signOffs.contains(normalized(last)) {
            tokens.removeLast()
        }
        let joined = tokens.joined(separator: " ")
        return joined.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
            .isEmpty ? "" : joined
    }
}

@MainActor
final class RioActionCoordinator {
    private let parser: RioActionParsing
    private let executor: RioActionExecuting
    private let smartResolver: RioSmartResolving?
    private let smartContext: RioSmartContextProviding?
    private let observer: RioActionObserving?
    private let confirmer: RioConfirming?
    /// Resolves the AI's planned clicks and fills against the live window before deciding whether
    /// to ask (security review). Nil fails closed: every planned click or fill asks.
    var plannedTargetResolver: RioTaskTargetResolving?
    private let isTrustingConversation: () -> Bool
    private let now: () -> Date
    /// The words the last run could not place (set when it ends `.unknown`, cleared otherwise).
    private(set) var lastUnrecognized: String?
    /// The actions the last run parsed (or the resolver produced), for the history label.
    private(set) var lastActions: [RioAction] = []
    /// The previous command and what it did, so the resolver can follow "do that again".
    private var previous: (command: String, actions: [String], at: Date)?

    init(
        parser: RioActionParsing,
        executor: RioActionExecuting,
        smartResolver: RioSmartResolving? = nil,
        smartContext: RioSmartContextProviding? = nil,
        observer: RioActionObserving? = nil,
        confirmer: RioConfirming? = nil,
        isTrustingConversation: @escaping () -> Bool = { RioTrustSetting.isTrusting },
        now: @escaping () -> Date = Date.init
    ) {
        self.isTrustingConversation = isTrustingConversation
        self.parser = parser
        self.executor = executor
        self.smartResolver = smartResolver
        self.smartContext = smartContext
        self.observer = observer
        self.confirmer = confirmer
        self.now = now
    }

    /// Runs one spoken command. `progress` receives a line like "Opening Google Chrome" before
    /// each action starts. Never types or pastes anything on its own.
    ///
    /// Understanding-first routing: a sure local parse runs straight away; a guess ("open another
    /// Chrome window") and anything not understood go to the smart resolver with context, and its
    /// plan is re-planned up to twice when a step fails. With no brain available a guess still runs
    /// as the parser read it.
    func run(
        _ transcript: String,
        source: RioCommandSource = .actionKey,
        progress: @MainActor (String) -> Void = { _ in }
    ) async -> RioActionOutcome {
        lastUnrecognized = nil
        lastActions = []
        let text = RioActionTranscript.stripName(from: transcript)
        guard !text.isEmpty else { return .nothing }
        defer { rememberCommand(text) }

        let analysis = parser.analyze(text)
        switch analysis.parse {
        case .empty:
            return .nothing
        case .actions(let actions):
            guard !analysis.isConfident, let smartResolver else {
                return await executeLocal(actions, source: source, progress: progress)
            }
            let request = await makeRequest(analysis.resolverText)
            if case .actions(let plan) = await smartResolver.resolve(request), !plan.isEmpty {
                return await runPlan(plan, request: request, resolver: smartResolver, source: source, progress: progress)
            }
            // Offline, off, too slow or no idea: do what the words most plainly said.
            return await executeLocal(actions, source: source, progress: progress)
        case .unknown(let unrecognized):
            lastUnrecognized = unrecognized
            guard let smartResolver else { return .unknown }
            let request = await makeRequest(unrecognized)
            switch await smartResolver.resolve(request) {
            case .actions(let plan):
                guard !plan.isEmpty else { return .unknown }
                return await runPlan(plan, request: request, resolver: smartResolver, source: source, progress: progress)
            case .unavailable(let message):
                return await executeLocal([.answer(message)], source: source, progress: progress)
            case .failed(let message):
                return .failed(message)
            }
        }
    }

    /// Whether `action` must be confirmed before it runs from `source`.
    func needsConfirmation(_ action: RioAction, source: RioCommandSource) -> Bool {
        if action.requiresConfirmation { return true }
        guard source == .conversation else { return false }
        if action.conversationAlwaysNeedsConfirmation { return true }
        return !isTrustingConversation() && action.conversationNeedsConfirmationWhenUntrusted
    }

    // MARK: Context

    private func makeRequest(_ command: String) async -> RioSmartRequest {
        RioSmartRequest(command: command, context: await currentContext())
    }

    private func currentContext() async -> RioSmartContext {
        var context = await smartContext?.currentContext() ?? RioSmartContext()
        if let previous, now().timeIntervalSince(previous.at) <= RioSmartContextLimits.previousCommandLifetime {
            context.previousCommand = previous.command
            context.previousActions = previous.actions
        }
        return context
    }

    private func rememberCommand(_ command: String) {
        guard !lastActions.isEmpty else { return }
        let steps = lastActions.prefix(RioSmartContextLimits.maxPreviousActions).map(RioSmartPlanText.describe)
        previous = (command, Array(steps), now())
    }

    // MARK: Running

    /// How one pass over a list of steps ended.
    private enum StepsResult {
        case finished(summaries: [String])
        /// Cancelled, refused or confirmed away: the run is over, never re-planned.
        case stopped(RioActionOutcome)
        case failed(index: Int, message: String, summaries: [String])
    }

    /// A local parse: runs as before, first failure ends the run.
    private func executeLocal(
        _ actions: [RioAction], source: RioCommandSource, progress: @MainActor (String) -> Void
    ) async -> RioActionOutcome {
        lastActions = actions
        switch await runSteps(actions, planned: false, source: source, progress: progress) {
        case .finished(let summaries): return Self.outcome(summaries)
        case .stopped(let outcome): return outcome
        case .failed(_, let message, _): return .failed(message)
        }
    }

    /// A resolver plan: a failed step is fed back (with what already ran) for a new plan, at most
    /// `RioSmartRouting.maxReplans` times; steps that already ran are not repeated.
    private func runPlan(
        _ plan: [RioAction], request: RioSmartRequest, resolver: RioSmartResolving,
        source: RioCommandSource, progress: @MainActor (String) -> Void
    ) async -> RioActionOutcome {
        var current = plan
        var attempted: [RioAction] = []
        var summaries: [String] = []
        var completed: [String] = []
        var round = 0
        while true {
            let result = await runSteps(current, planned: true, source: source, progress: progress)
            switch result {
            case .finished(let done):
                lastActions = attempted + current
                return Self.outcome(summaries + done)
            case .stopped(let outcome):
                lastActions = attempted + current
                return outcome
            case .failed(let index, let message, let done):
                attempted += current.prefix(index + 1)
                lastActions = attempted
                summaries += done
                completed += current.prefix(index).map(RioSmartPlanText.describe)
                guard round < RioSmartRouting.maxReplans else { return .failed(RioActionText.couldNotFinish(message)) }
                round += 1
                var retry = request
                retry.context = await currentContext()
                retry.attempt = RioSmartAttempt(
                    completed: completed, failedStep: RioSmartPlanText.describe(current[index]), failure: message, round: round
                )
                progress("Trying another way")
                guard case .actions(let next) = await resolver.resolve(retry), !next.isEmpty else {
                    return .failed(RioActionText.couldNotFinish(message))
                }
                current = next
            }
        }
    }

    /// `planned` is true for the resolver's steps (not the owner's own words), where a risky click
    /// or fill asks first (`RioSmartRouting.plannedStepNeedsConfirmation`).
    private func runSteps(
        _ actions: [RioAction], planned: Bool, source: RioCommandSource, progress: @MainActor (String) -> Void
    ) async -> StepsResult {
        var summaries: [String] = []
        for (index, action) in actions.enumerated() {
            progress(RioActionText.working(for: action))
            var riskyPlannedStep = planned && RioSmartRouting.plannedStepNeedsConfirmation(action)
            var action = action
            if planned, !riskyPlannedStep, RioSmartRouting.isClickOrFill(action) {
                if let resolver = plannedTargetResolver {
                    let resolution = await resolver.resolveTarget(for: action)
                    if RioSmartRouting.resolvedPlannedStepNeedsConfirmation(action, resolution) {
                        riskyPlannedStep = true
                    } else {
                        // Press exactly the element that was checked.
                        action = RioTaskTargetMapper.bind(action, to: resolution)
                    }
                } else {
                    riskyPlannedStep = true
                }
            }
            if source.refuses(action) || (riskyPlannedStep && source == .phone) {
                return .stopped(.failed("I won't do that from your phone. Do it on your Mac."))
            }
            if riskyPlannedStep || needsConfirmation(action, source: source) {
                // No confirmer means no way to ask, so never run it.
                guard let confirmer else { return .stopped(.cancelled) }
                let confirmed: Bool
                if source == .conversation, !action.requiresConfirmation,
                   let conversational = confirmer as? RioConversationConfirming {
                    confirmed = await conversational.confirmConversationAction(action)
                } else {
                    confirmed = await confirmer.confirm(action)
                }
                guard confirmed else { return .stopped(.cancelled) }
            }
            // "Switch to Chrome, then press command N": the keys must land in Chrome.
            if index > 0, RioSmartRouting.focusesApp(actions[index - 1]), RioSmartRouting.actsOnFrontApp(action),
               let settling = executor as? RioFocusSettling {
                await settling.settleFocus()
            }
            await observer?.willExecute(action)
            let result = await executor.execute(action)
            observer?.didExecute(action, result: result)
            switch result {
            case .done(let summary):
                // So the next command can say "it", "that" or "the same" (see RioFollowUp.swift).
                RioFollowUpMemory.shared.record(action)
                summaries.append(summary)
            case .failed(let message):
                return .failed(index: index, message: message, summaries: summaries)
            case .cancelled:
                return .stopped(.cancelled)
            }
        }
        return .finished(summaries: summaries)
    }

    private static func outcome(_ summaries: [String]) -> RioActionOutcome {
        summaries.isEmpty ? .nothing : .succeeded(summaries.joined(separator: ", "))
    }
}
