import Foundation

// Builder P: the data Rio keeps for scheduled commands, triggers and macros. Pure value types,
// Foundation only, so the store and the tests need no AppKit.

enum RioRecurrence: Equatable, Codable {
    case once
    case daily
    case weekdays
    /// `weekday` follows `Calendar`: 1 is Sunday, 2 is Monday.
    case weekly(weekday: Int)
}

/// A command Rio runs later ("open Slack every weekday at 9"). `command` is the text the owner
/// would say; it runs through the normal Rio pipeline as `.automation`.
struct RioScheduledCommand: Equatable, Codable, Identifiable {
    let id: UUID
    var command: String
    var recurrence: RioRecurrence
    var hour: Int
    var minute: Int
    var nextFire: Date
    let createdAt: Date
}

enum RioTriggerKind: Equatable, Codable {
    case displayConnected
    case audioOutput(name: String)
    case wifi(ssid: String)

    /// The text kept in `.addTrigger(trigger:)`: "display", "audio:AirPods", "wifi:Home".
    var spec: String {
        switch self {
        case .displayConnected: return "display"
        case .audioOutput(let name): return "audio:\(name)"
        case .wifi(let ssid): return "wifi:\(ssid)"
        }
    }

    init?(spec: String) {
        let text = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased() == "display" { self = .displayConnected; return }
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let prefix = text[..<colon].lowercased()
        let value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        switch prefix {
        case "audio": self = .audioOutput(name: value)
        case "wifi": self = .wifi(ssid: value)
        default: return nil
        }
    }

    /// "a display connects", "AirPods connect", "I join Home": how the owner would say it.
    var spoken: String {
        switch self {
        case .displayConnected: return "a display connects"
        case .audioOutput(let name): return "\(name) connect"
        case .wifi(let ssid): return "I join \(ssid)"
        }
    }

    var needsLocation: Bool {
        if case .wifi = self { return true }
        return false
    }
}

struct RioTriggerRule: Equatable, Codable, Identifiable {
    let id: UUID
    var command: String
    var kind: RioTriggerKind
    let createdAt: Date
    var lastFired: Date?
}

/// A recorded macro: closed-set actions only, replayed through the executor.
struct RioMacro: Equatable, Codable, Identifiable {
    let id: UUID
    var name: String
    var steps: [RioAction]
    let createdAt: Date
}

struct RioAutomationData: Equatable, Codable {
    var schedules: [RioScheduledCommand] = []
    var triggers: [RioTriggerRule] = []
    var macros: [RioMacro] = []
    /// Things Rio owes the owner an explanation for, such as a run skipped while the Mac slept.
    var notes: [String] = []

    var isEmpty: Bool { schedules.isEmpty && triggers.isEmpty && macros.isEmpty }
}
