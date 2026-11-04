import Foundation

// The Rio action pipeline after transcription: strip the optional name, parse, execute.
// Pure of AppKit and AppState so it can be tested with fake collaborators.

protocol RioActionParsing {
    func parse(_ transcript: String) -> RioActionParse
}

@MainActor protocol RioActionExecuting: AnyObject {
    func execute(_ action: RioAction) async -> RioActionResult
}

/// Turns text the local parser could not place into actions (the LLM, wave 2). Must only ever
/// return members of the closed `RioAction` set.
protocol RioSmartResolving {
    func resolve(_ text: String) async throws -> [RioAction]
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
    private let observer: RioActionObserving?
    private let confirmer: RioConfirming?
    private let isTrustingConversation: () -> Bool
    /// The words the last run could not place (set when it ends `.unknown`, cleared otherwise).
    private(set) var lastUnrecognized: String?
    /// The actions the last run parsed (or the resolver produced), for the history label.
    private(set) var lastActions: [RioAction] = []

    init(
        parser: RioActionParsing,
        executor: RioActionExecuting,
        smartResolver: RioSmartResolving? = nil,
        observer: RioActionObserving? = nil,
        confirmer: RioConfirming? = nil,
        isTrustingConversation: @escaping () -> Bool = { RioTrustSetting.isTrusting }
    ) {
        self.isTrustingConversation = isTrustingConversation
        self.parser = parser
        self.executor = executor
        self.smartResolver = smartResolver
        self.observer = observer
        self.confirmer = confirmer
    }

    /// Runs one spoken command. `progress` receives a line like "Opening Google Chrome" before
    /// each action starts. Never types or pastes anything on its own.
    func run(
        _ transcript: String,
        source: RioCommandSource = .actionKey,
        progress: @MainActor (String) -> Void = { _ in }
    ) async -> RioActionOutcome {
        lastUnrecognized = nil
        lastActions = []
        let text = RioActionTranscript.stripName(from: transcript)
        guard !text.isEmpty else { return .nothing }

        switch parser.parse(text) {
        case .empty:
            return .nothing
        case .actions(let actions):
            return await execute(actions, source: source, progress: progress)
        case .unknown(let unrecognized):
            lastUnrecognized = unrecognized
            guard let smartResolver else { return .unknown }
            do {
                let actions = try await smartResolver.resolve(unrecognized)
                guard !actions.isEmpty else { return .unknown }
                return await execute(actions, source: source, progress: progress)
            } catch {
                return .failed(RioActionText.resolverFailedMessage)
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

    private func execute(
        _ actions: [RioAction],
        source: RioCommandSource,
        progress: @MainActor (String) -> Void
    ) async -> RioActionOutcome {
        var summaries: [String] = []
        lastActions = actions
        for action in actions {
            progress(RioActionText.working(for: action))
            if source.refuses(action) {
                return .failed("I won't do that from your phone. Do it on your Mac.")
            }
            if needsConfirmation(action, source: source) {
                // No confirmer means no way to ask, so never run it.
                guard let confirmer else { return .cancelled }
                let confirmed: Bool
                if source == .conversation, !action.requiresConfirmation,
                   let conversational = confirmer as? RioConversationConfirming {
                    confirmed = await conversational.confirmConversationAction(action)
                } else {
                    confirmed = await confirmer.confirm(action)
                }
                guard confirmed else { return .cancelled }
            }
            await observer?.willExecute(action)
            let result = await executor.execute(action)
            observer?.didExecute(action, result: result)
            switch result {
            case .done(let summary):
                summaries.append(summary)
            case .failed(let message):
                return .failed(message)
            case .cancelled:
                return .cancelled
            }
        }
        return summaries.isEmpty ? .nothing : .succeeded(summaries.joined(separator: ", "))
    }
}
