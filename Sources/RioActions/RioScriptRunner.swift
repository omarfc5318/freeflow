import AppKit
import Foundation

/// Runs one of the fixed AppleScript handlers (`RioScriptCall`). The source is a constant and the
/// user's text only ever travels as handler arguments.
@MainActor
enum RioScriptRunner {
    static let automationDenied = -1743

    /// nil on success, otherwise the AppleScript error number.
    static func run(_ call: RioScriptCall) -> Int? {
        guard let script = NSAppleScript(source: call.source) else { return -1 }
        var error: NSDictionary?
        _ = script.compileAndReturnError(&error)
        if let error { return error[NSAppleScript.errorNumber] as? Int ?? -1 }
        let event = RioMessagingScripts.appleEvent(for: call, target: NSAppleEventDescriptor.currentProcess())
        _ = script.executeAppleEvent(event, error: &error)
        guard let error else { return nil }
        return error[NSAppleScript.errorNumber] as? Int ?? -1
    }
}

/// "note: ask Ali about the deck" appends to the Apple Notes note named "Rio Notes".
@MainActor
enum RioNotesWriter {
    static func append(_ text: String) -> RioActionResult {
        switch RioScriptRunner.run(RioNotesScripts.append(text: text)) {
        case nil:
            return .done(summary: "Added to your Rio Notes")
        case RioScriptRunner.automationDenied?:
            return .failed(message: "I'm not allowed to control Notes. You can allow it in System Settings, Privacy and Security, Automation.")
        default:
            return .failed(message: "I couldn't add that to Notes.")
        }
    }
}
