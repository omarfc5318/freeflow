import Foundation

// The undo inverse table and stack. Pure (Foundation only): the journal captures a snapshot
// before an action runs, and this decides what undoing it means.

/// Something an action created that undo can delete again. E's and H's handlers report these to
/// `RioUndoJournal.shared.noteCreated(_:)` right after they create the item.
enum RioCreatedItem: Equatable {
    case calendarEvent(identifier: String)
    case reminder(identifier: String)
}

/// What the journal learned about the world just before (and just after) an action ran.
struct RioUndoSnapshot: Equatable {
    /// Whether the app the action names was already running, and its resolved display name.
    var wasRunning: Bool?
    var resolvedAppName: String?
    var previousFrontApp: String?
    var volumeLevel: Int?
    var wasMuted: Bool?
    var brightness: Int?
    var hasWindowSnapshot = false
    var timerRemaining: Int?
    var timerLabel: String?
    var created: RioCreatedItem?
}

enum RioUndoInverse: Equatable {
    /// Run these actions, in order, through the executor.
    case actions([RioAction])
    /// Put the window back with the saved snapshot (not expressible in the closed action set).
    case restoreWindow
    case deleteCreated(RioCreatedItem)
    /// Cancel the countdown Rio started, and nothing else: never "stop", which would also stop a
    /// running task. Goes straight to the timer centre, not through the executor.
    case cancelCountdown

    /// False when a failed inverse means its target is gone (the timer already finished), so
    /// the record is dropped instead of answering "no timer" for the next 15 minutes.
    var isRetryableAfterFailure: Bool {
        switch self {
        case .cancelCountdown: return false
        default: return true
        }
    }
}

enum RioUndoPlan {
    enum Disposition: Equatable {
        /// Read-only or a no-op: never recorded, so it doesn't hide an earlier undoable action.
        case ignore
        /// Happened, but can't be taken back ("I can't undo that one").
        case irreversible
        case reversible(RioUndoInverse)
    }

    static let cantUndoMessage = "I can't undo that one"
    static let nothingToUndoMessage = "There's nothing to undo"

    /// How long an action stays undoable, and how many are remembered.
    static let maxAge: TimeInterval = 15 * 60
    static let stackLimit = 10

    static func disposition(for action: RioAction, snapshot: RioUndoSnapshot) -> Disposition {
        switch action {
        case .openApp, .switchToApp:
            return appLaunch(snapshot)
        case .quitApp:
            switch (snapshot.wasRunning, snapshot.resolvedAppName) {
            case (true?, let name?): return .reversible(.actions([.openApp(name: name)]))
            case (false?, _): return .ignore
            default: return .irreversible
            }
        case .hideApp:
            switch (snapshot.wasRunning, snapshot.resolvedAppName) {
            case (true?, let name?): return .reversible(.actions([.switchToApp(name: name)]))
            case (false?, _): return .ignore
            default: return .irreversible
            }
        case .volume(let change):
            return volume(change, snapshot)
        case .brightness:
            guard let level = snapshot.brightness else { return .irreversible }
            return .reversible(.actions([.brightness(.set(level))]))
        case .window:
            return snapshot.hasWindowSnapshot ? .reversible(.restoreWindow) : .irreversible
        case .startTimer:
            return .reversible(.cancelCountdown)
        case .cancelTimer:
            guard let remaining = snapshot.timerRemaining, remaining >= 1 else { return .ignore }
            return .reversible(.actions([.startTimer(seconds: remaining, label: snapshot.timerLabel)]))
        case .media(let command):
            switch command {
            case .playPause: return .reversible(.actions([.media(.playPause)]))
            case .next: return .reversible(.actions([.media(.previous)]))
            case .previous: return .reversible(.actions([.media(.next)]))
            }
        case .doNotDisturb(let isOn):
            return .reversible(.actions([.doNotDisturb(isOn: !isOn)]))
        case .systemToggle(let setting, let isOn):
            // Wi-Fi and Bluetooth can only be put back after turning them off: when they were
            // turned on we don't know whether they were already on.
            if (setting == .wifi || setting == .bluetooth) && isOn { return .irreversible }
            return .reversible(.actions([.systemToggle(setting, isOn: !isOn)]))
        case .createEvent:
            if case .calendarEvent? = snapshot.created, let item = snapshot.created { return .reversible(.deleteCreated(item)) }
            return .irreversible
        case .createReminder:
            if case .reminder? = snapshot.created, let item = snapshot.created { return .reversible(.deleteCreated(item)) }
            return .irreversible
        case .selectionTask(let task):
            if case .improve = task { return .irreversible }
            return .ignore
        case .clipboard(let command):
            if case .pasteRecent = command { return .irreversible }
            return .ignore
        case .undoLast, .showHelp, .timerStatus, .answer, .readAloud, .calendarAgenda, .batteryStatus, .stopListening,
             .describeScreen, .recall, .calculate, .startTranslation, .stopTranslation, .speakLastTranslation:
            return .ignore
        case .openURL, .webSearch, .lockScreen, .screenshot, .typeText, .sendMessage, .replyInConversation,
             .openFile, .revealFile, .joinNextMeeting, .pressKeys, .browser, .emptyTrash,
             .click, .fillField, .runTask, .remember, .forget, .draftEmail, .addNote:
            return .irreversible
        }
    }

    private static func appLaunch(_ snapshot: RioUndoSnapshot) -> Disposition {
        guard let running = snapshot.wasRunning, let name = snapshot.resolvedAppName else { return .irreversible }
        if !running { return .reversible(.actions([.quitApp(name: name)])) }
        if let previous = snapshot.previousFrontApp, previous.lowercased() != name.lowercased() {
            return .reversible(.actions([.switchToApp(name: previous)]))
        }
        return .irreversible
    }

    private static func volume(_ change: VolumeChange, _ snapshot: RioUndoSnapshot) -> Disposition {
        switch change {
        case .mute:
            guard let muted = snapshot.wasMuted else { return .irreversible }
            return muted ? .ignore : .reversible(.actions([.volume(.unmute)]))
        case .unmute:
            guard let muted = snapshot.wasMuted else { return .irreversible }
            return muted ? .reversible(.actions([.volume(.mute)])) : .ignore
        case .up, .down, .set:
            guard let level = snapshot.volumeLevel else { return .irreversible }
            // Raising the volume unmutes, so a muted Mac needs the mute put back too.
            let restore: [RioAction] = snapshot.wasMuted == true
                ? [.volume(.set(level)), .volume(.mute)]
                : [.volume(.set(level))]
            return .reversible(.actions(restore))
        }
    }

    // MARK: Wording

    static func undoneSummary(for inverse: RioUndoInverse) -> String {
        switch inverse {
        case .restoreWindow: return "Undone: window put back"
        case .cancelCountdown: return "Undone: timer cancelled"
        case .deleteCreated(.calendarEvent): return "Undone: removed the event"
        case .deleteCreated(.reminder): return "Undone: removed the reminder"
        case .actions(let actions):
            guard let first = actions.first else { return "Undone" }
            return "Undone: \(phrase(for: first))"
        }
    }

    private static func phrase(for action: RioAction) -> String {
        switch action {
        case .quitApp(let name): return "closed \(name)"
        case .openApp(let name): return "reopened \(name)"
        case .switchToApp(let name): return "back to \(name)"
        case .volume(.set(let level)): return "volume back to \(level) percent"
        case .volume(.unmute): return "unmuted"
        case .volume(.mute): return "muted again"
        case .brightness(.set(let level)): return "brightness back to \(level) percent"
        case .cancelTimer: return "timer cancelled"
        case .startTimer: return "timer is back"
        case .media: return "flipped it back"
        case .doNotDisturb(let isOn): return "Do Not Disturb back \(isOn ? "on" : "off")"
        case .systemToggle(let setting, let isOn): return "\(settingName(setting)) back \(isOn ? "on" : "off")"
        default: return "done"
        }
    }

    private static func settingName(_ setting: SystemSetting) -> String {
        switch setting {
        case .wifi: return "Wi-Fi"
        case .bluetooth: return "Bluetooth"
        case .darkMode: return "dark mode"
        case .nightShift: return "Night Shift"
        }
    }
}

/// One remembered action.
struct RioUndoRecord {
    let id = UUID()
    let action: RioAction
    let disposition: RioUndoPlan.Disposition
    let date: Date
}

/// The last few actions, newest last. Old entries expire so "undo" never reaches back an hour.
struct RioUndoStack {
    private(set) var records: [RioUndoRecord] = []
    let limit: Int
    let maxAge: TimeInterval

    init(limit: Int = RioUndoPlan.stackLimit, maxAge: TimeInterval = RioUndoPlan.maxAge) {
        self.limit = limit
        self.maxAge = maxAge
    }

    var count: Int { records.count }

    mutating func push(_ record: RioUndoRecord) {
        records.append(record)
        if records.count > limit { records.removeFirst(records.count - limit) }
    }

    /// Records the action unless it is read-only or a no-op.
    mutating func record(_ action: RioAction, disposition: RioUndoPlan.Disposition, now: Date) {
        if disposition == .ignore { return }
        push(RioUndoRecord(action: action, disposition: disposition, date: now))
    }

    /// The newest record that hasn't expired.
    mutating func pop(now: Date) -> RioUndoRecord? {
        records.removeAll { now.timeIntervalSince($0.date) > maxAge }
        return records.popLast()
    }
}
