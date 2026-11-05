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
/// Whenever Messages writes to its database (watched with a file-system event source, with a slow
/// fallback check), while on, it reads Messages' chat.db read-only for NEW messages you sent to
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

    /// The fallback check, for writes the file watch misses; it also re-arms the watch.
    static let fallbackPollInterval: TimeInterval = 30
    /// Messages writes in bursts; one look after it settles.
    private static let writeSettleSeconds: TimeInterval = 0.5

    @Published private(set) var status: RioPhoneStatus = .off
    private var run: Runner?
    private var timer: Timer?
    private var isPolling = false
    private var needsAnotherPoll = false
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var pendingPoll: DispatchWorkItem?
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
        watchDatabase()
        timer = RioMainTimer.schedule(interval: Self.fallbackPollInterval, repeats: true, tolerance: 5) { [weak self] in
            guard let self else { return }
            // The write-ahead log may have appeared or been replaced since the watch began.
            if self.watchers.count < Self.watchedPaths(self.chatPath).count { self.watchDatabase() }
            self.requestPoll()
        }
    }

    private func stop(status newStatus: RioPhoneStatus = .off) {
        timer?.invalidate()
        timer = nil
        stopWatching()
        pendingPoll?.cancel()
        pendingPoll = nil
        status = newStatus
    }

    /// The database and its write-ahead log, where new messages land first.
    private static func watchedPaths(_ chatPath: String) -> [String] { [chatPath, chatPath + "-wal"] }

    private func watchDatabase() {
        stopWatching()
        for path in Self.watchedPaths(chatPath) {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename, .revoke], queue: .main
            )
            source.setEventHandler { [weak self, weak source] in
                let events = source?.data ?? []
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // The file was replaced (a checkpoint, a Messages restart): watch the new one.
                    if !events.isDisjoint(with: [.delete, .rename, .revoke]) { self.watchDatabase() }
                    self.schedulePoll()
                }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watchers.append(source)
        }
    }

    private func stopWatching() {
        watchers.forEach { $0.cancel() }
        watchers = []
    }

    private func schedulePoll() {
        pendingPoll?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.requestPoll() } }
        pendingPoll = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.writeSettleSeconds, execute: work)
    }

    /// Looks now, or right after the look in progress, so a write during a slow command is never missed.
    private func requestPoll() {
        guard timer != nil else { return }
        guard !isPolling else {
            needsAnotherPoll = true
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.poll()
            if self.needsAnotherPoll {
                self.needsAnotherPoll = false
                self.requestPoll()
            }
        }
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
    /// The one-line launch hook: `RioPhoneTexting.shared.bind(to: appState)`. Each text waits its
    /// turn if Rio is busy, and gets its own command's result back (never another command's).
    func bind(to appState: AppState) {
        configure { [weak appState] text in
            guard let appState else { return nil }
            return await Self.withinTimeLimit { await appState.runRioCommandForReply(text, source: .phone) }
        }
    }

    /// How long the phone waits for an answer before saying it didn't finish in time.
    static let replyTimeLimitSeconds: UInt64 = 180

    /// The command keeps running past the limit; only the reply stops waiting for it.
    private static func withinTimeLimit(
        _ work: @escaping @MainActor () async -> (message: String, succeeded: Bool)?
    ) async -> (message: String, succeeded: Bool)? {
        await withCheckedContinuation { continuation in
            let gate = RioPhoneReplyGate(continuation)
            Task { @MainActor in gate.finish(await work()) }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: replyTimeLimitSeconds * 1_000_000_000)
                gate.finish(nil)
            }
        }
    }
}

/// Resumes the reply once, with whichever comes first: the result or the time limit.
@MainActor
private final class RioPhoneReplyGate {
    private var continuation: CheckedContinuation<(message: String, succeeded: Bool)?, Never>?

    init(_ continuation: CheckedContinuation<(message: String, succeeded: Bool)?, Never>) {
        self.continuation = continuation
    }

    func finish(_ outcome: (message: String, succeeded: Bool)?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: outcome)
    }
}
