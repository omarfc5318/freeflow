import Foundation

/// Something that happened on the Mac. The watcher turns system notifications into these; the
/// matcher is pure so the tests never register a real observer.
enum RioSystemEvent: Equatable {
    case displayConnected
    case audioOutput(deviceName: String)
    case wifiJoined(ssid: String)
}

enum RioTriggerMatcher {
    /// The same trigger will not fire again within this many seconds: a display or a pair of
    /// earbuds can raise several notifications for one connection.
    static let cooldown: TimeInterval = 30

    static func matches(_ kind: RioTriggerKind, _ event: RioSystemEvent) -> Bool {
        switch (kind, event) {
        case (.displayConnected, .displayConnected):
            return true
        case (.audioOutput(let name), .audioOutput(let device)):
            let wanted = RioText.compact(name)
            return !wanted.isEmpty && RioText.compact(device).contains(wanted)
        case (.wifi(let ssid), .wifiJoined(let joined)):
            let wanted = RioText.compact(ssid)
            return !wanted.isEmpty && RioText.compact(joined) == wanted
        default:
            return false
        }
    }

    static func shouldFire(lastFired: Date?, now: Date) -> Bool {
        guard let last = lastFired else { return true }
        return now.timeIntervalSince(last) >= cooldown
    }
}
