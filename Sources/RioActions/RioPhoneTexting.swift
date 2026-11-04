import AppKit
import Combine
import Foundation

enum RioPhoneStatus: Equatable {
    case off
    case needsHandle
    case needsFullDiskAccess
    case messagesMissing
    case listening
}

/// Text Rio from your iPhone (builder S). Off by default.
///
/// Every few seconds, while on, it reads Messages' chat.db read-only for NEW messages you sent to
/// yourself that start with "Rio", runs each through the injected `run` closure (bound to
/// `runRioCommandText(_, .phone)`), and texts the answer back to your own handle only. The
/// coordinator refuses anything that would need a confirmation. The last handled ROWID is stored
/// before a command runs, so a message never runs twice; messages that arrived while Rio was off
/// are skipped, never replayed. Message text is held in memory for one command and never logged.
@MainActor
final class RioPhoneTexting: ObservableObject {
    static let shared = RioPhoneTexting()

    /// Runs one command text and returns Rio's answer, or nil when it produced none in time.
    typealias Runner = @MainActor (String) async -> (message: String, succeeded: Bool)?

    static let pollInterval: TimeInterval = 3

    @Published private(set) var status: RioPhoneStatus = .off
    private var run: Runner?
    private var timer: Timer?
    private var isPolling = false
    private let chatPath: String

    init(chatPath: String = RioPhoneAccess.defaultPath) {
        self.chatPath = chatPath
    }

    /// Binds the command runner. Call once at launch, then `applySettings()`.
    func configure(run: @escaping Runner) {
        self.run = run
        applySettings()
    }

    /// Starts or stops watching to match the settings. Safe to call whenever a setting changes.
    func applySettings() {
        guard run != nil, RioOutsideSettings.phoneEnabled else {
            stop()
            return
        }
        guard !RioOutsideSettings.phoneHandles.isEmpty else {
            stop(status: .needsHandle)
            return
        }
        switch RioPhoneAccess.check(path: chatPath) {
        case .denied: stop(status: .needsFullDiskAccess)
        case .missing: stop(status: .messagesMissing)
        case .ok: start()
        }
    }

    private func start() {
        status = .listening
        guard timer == nil else { return }
        // Skip anything that arrived while Rio was off.
        if let reader = RioChatDBReader(path: chatPath) {
            UserDefaults.standard.set(Int(reader.maxRowID()), forKey: RioOutsideSettings.phoneLastRowKey)
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
    }

    private func stop(status newStatus: RioPhoneStatus = .off) {
        timer?.invalidate()
        timer = nil
        status = newStatus
    }

    private func poll() async {
        guard !isPolling, let run else { return }
        isPolling = true
        defer { isPolling = false }
        let handles = RioOutsideSettings.phoneHandles
        guard RioOutsideSettings.phoneEnabled, !handles.isEmpty else { return applySettings() }
        let last = Int64(UserDefaults.standard.integer(forKey: RioOutsideSettings.phoneLastRowKey))
        let path = chatPath
        let scan = await Task.detached(priority: .utility) { () -> RioPhoneScan? in
            guard let reader = RioChatDBReader(path: path) else { return nil }
            return RioPhoneFilter.scan(reader.rows(after: last, limit: 200), ownerHandles: handles, after: last)
        }.value
        guard let scan else { return applySettings() }
        // Stored before anything runs: a crash or a slow command can never replay a message.
        UserDefaults.standard.set(Int(scan.lastRowID), forKey: RioOutsideSettings.phoneLastRowKey)
        for command in scan.commands {
            let outcome = await run(command.text)
            let reply = RioPhoneReply.text(
                outcome?.message ?? "I didn't finish that one in time.", succeeded: outcome?.succeeded ?? false
            )
            // Only ever to the chat the command came from, which the filter proved is the owner's own.
            send(reply, to: command.replyHandle)
        }
    }

    private func send(_ body: String, to handle: String) {
        let call = RioMessagingScripts.sendIMessage(handle: handle, body: body)
        guard let script = NSAppleScript(source: call.source) else { return }
        var error: NSDictionary?
        _ = script.compileAndReturnError(&error)
        guard error == nil else { return }
        let event = RioMessagingScripts.appleEvent(for: call, target: NSAppleEventDescriptor.currentProcess())
        _ = script.executeAppleEvent(event, error: &error)
    }
}

// MARK: - Launch binding

extension RioPhoneTexting {
    /// The one-line launch hook: `RioPhoneTexting.shared.bind(to: appState)`.
    func bind(to appState: AppState) {
        configure { [weak appState] text in
            guard let appState else { return nil }
            return await RioPhoneOutcomeWaiter.run(text, on: appState)
        }
    }
}

/// Runs a command through AppState and waits for the bear's next success or failure.
@MainActor
private final class RioPhoneOutcomeWaiter {
    private var continuation: CheckedContinuation<(message: String, succeeded: Bool)?, Never>?
    private var cancellable: AnyCancellable?

    static func run(_ text: String, on appState: AppState) async -> (message: String, succeeded: Bool)? {
        let waiter = RioPhoneOutcomeWaiter()
        return await waiter.wait(text, on: appState)
    }

    private func wait(_ text: String, on appState: AppState) async -> (message: String, succeeded: Bool)? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            cancellable = appState.$rioActionPhase.dropFirst().sink { [weak self] phase in
                switch phase {
                case .succeeded(let message): Task { @MainActor in self?.finish((message, true)) }
                case .failed(let message): Task { @MainActor in self?.finish((message, false)) }
                default: break
                }
            }
            appState.runRioCommandText(text, source: .phone)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                self?.finish(nil)
            }
        }
    }

    private func finish(_ outcome: (message: String, succeeded: Bool)?) {
        guard let continuation else { return }
        self.continuation = nil
        cancellable?.cancel()
        continuation.resume(returning: outcome)
    }
}
