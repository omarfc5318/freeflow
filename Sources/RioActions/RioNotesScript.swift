import Foundation

/// The fixed Apple Notes script for "note: ...". The user's text only ever travels as an HTML-
/// escaped argument; the source is constant and never deletes anything.
enum RioNotesScripts {
    static let noteTitle = "Rio Notes"
    static let maxLength = 1_000

    static let source = """
    on appendnote(theID, theTitle, theHTML)
        tell application "Notes"
            if theID is not "" then
                try
                    set theNote to note id theID
                    set body of theNote to (body of theNote) & theHTML
                    return id of theNote
                end try
            end if
            set theNote to make new note at default folder of default account with properties {body:"<div><h1>" & theTitle & "</h1></div>" & theHTML}
            return id of theNote
        end tell
    end appendnote
    """

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// One `<div>` per line; a blank line is an empty one.
    static func html(for text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "<div><br></div>" : "<div>\(escape(String($0)))</div>" }
            .joined()
    }

    /// `noteID` is the id of the note Rio created earlier (nil the first time); the script returns
    /// the id it appended to, which the caller saves. Rio never looks notes up by name.
    static func append(text: String, noteID: String?) -> RioScriptCall {
        RioScriptCall(source: source, handler: "appendnote", arguments: [noteID ?? "", noteTitle, html(for: text)])
    }
}
