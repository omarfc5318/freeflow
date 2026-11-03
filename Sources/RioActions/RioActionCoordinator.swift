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
    /// Not understood: the bear shrugs.
    case unknown
}

enum RioActionText {
    static let unknownMessage = "I don't know how to do that yet"
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

    init(
        parser: RioActionParsing,
        executor: RioActionExecuting,
        smartResolver: RioSmartResolving? = nil,
        observer: RioActionObserving? = nil,
        confirmer: RioConfirming? = nil
    ) {
        self.parser = parser
        self.executor = executor
        self.smartResolver = smartResolver
        self.observer = observer
        self.confirmer = confirmer
    }

    /// Runs one spoken command. `progress` receives a line like "Opening Google Chrome" before
    /// each action starts. Never types or pastes anything on its own.
    func run(_ transcript: String, progress: @MainActor (String) -> Void = { _ in }) async -> RioActionOutcome {
        let text = RioActionTranscript.stripName(from: transcript)
        guard !text.isEmpty else { return .nothing }

        switch parser.parse(text) {
        case .empty:
            return .nothing
        case .actions(let actions):
            return await execute(actions, progress: progress)
        case .unknown(let unrecognized):
            guard let smartResolver else { return .unknown }
            do {
                let actions = try await smartResolver.resolve(unrecognized)
                guard !actions.isEmpty else { return .unknown }
                return await execute(actions, progress: progress)
            } catch {
                return .failed(RioActionText.resolverFailedMessage)
            }
        }
    }

    private func execute(_ actions: [RioAction], progress: @MainActor (String) -> Void) async -> RioActionOutcome {
        var summaries: [String] = []
        for action in actions {
            progress(RioActionText.working(for: action))
            if action.requiresConfirmation {
                // No confirmer means no way to ask, so never run it.
                guard let confirmer, await confirmer.confirm(action) else { return .cancelled }
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
