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
                    -- A note moved to Recently Deleted (any language) is gone: start a new one.
                    set folderName to name of container of theNote
                    if folderName does not contain "Deleted" and folderName does not contain "\u{0645}\u{062D}\u{0630}\u{0648}\u{0641}" and folderName is not in {"Zuletzt gel\u{00F6}scht", "Supprim\u{00E9}s r\u{00E9}cemment", "Eliminados recientemente", "Eliminati di recente", "\u{6700}\u{8FD1}\u{5220}\u{9664}", "\u{6700}\u{8FD1}\u{524A}\u{9664}", "Onlangs verwijderd"} then
                        set body of theNote to (body of theNote) & theHTML
                        return id of theNote
                    end if
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
