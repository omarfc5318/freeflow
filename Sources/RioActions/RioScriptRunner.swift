import AppKit
import Foundation

/// Runs one of the fixed AppleScript handlers (`RioScriptCall`). The source is a constant and the
/// user's text only ever travels as handler arguments.
@MainActor
enum RioScriptRunner {
    static let automationDenied = -1743

    /// nil on success, otherwise the AppleScript error number.
    static func run(_ call: RioScriptCall) -> Int? {
        if case .failure(let error) = runReturningString(call) { return error.code }
        return nil
    }

    /// Runs the handler and returns its string result (empty when it returns nothing).
    static func runReturningString(_ call: RioScriptCall) -> Result<String, RioScriptError> {
        guard let script = NSAppleScript(source: call.source) else { return .failure(RioScriptError(code: -1)) }
        var error: NSDictionary?
        _ = script.compileAndReturnError(&error)
        if let error { return .failure(RioScriptError(code: error[NSAppleScript.errorNumber] as? Int ?? -1)) }
        let event = RioMessagingScripts.appleEvent(for: call, target: NSAppleEventDescriptor.currentProcess())
        let result = script.executeAppleEvent(event, error: &error)
        if let error { return .failure(RioScriptError(code: error[NSAppleScript.errorNumber] as? Int ?? -1)) }
        return .success(result.stringValue ?? "")
    }
}

/// "note: ask Ali about the deck" appends to the Apple Notes note named "Rio Notes".
@MainActor
enum RioNotesWriter {
    /// The id of the note Rio created; appends go only to it.
    private static let noteIDKey = "rio_notes_note_id"

    static func append(_ text: String) -> RioActionResult {
        let savedID = UserDefaults.standard.string(forKey: noteIDKey)
        switch RioScriptRunner.runReturningString(RioNotesScripts.append(text: text, noteID: savedID)) {
        case .success(let id):
            if !id.isEmpty { UserDefaults.standard.set(id, forKey: noteIDKey) }
            return .done(summary: "Added to your Rio Notes")
        case .failure(let error) where error.code == RioScriptRunner.automationDenied:
            return .failed(message: "I'm not allowed to control Notes. You can allow it in System Settings, Privacy and Security, Automation.")
        case .failure:
            return .failed(message: "I couldn't add that to Notes.")
        }
    }
}

struct RioScriptError: Error, Equatable {
    let code: Int
}
