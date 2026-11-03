import Foundation

/// The fixed Apple Notes script for "note: ...". The user's text only ever travels as an HTML-
/// escaped argument; the source is constant and never deletes anything.
enum RioNotesScripts {
    static let noteTitle = "Rio Notes"
    static let maxLength = 1_000

    static let source = """
    on appendnote(theTitle, theHTML)
        tell application "Notes"
            set theMatches to (notes whose name is theTitle)
            if (count of theMatches) is 0 then
                make new note with properties {body:"<div><h1>" & theTitle & "</h1></div>" & theHTML}
            else
                set theNote to item 1 of theMatches
                set body of theNote to (body of theNote) & theHTML
            end if
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

    static func append(text: String) -> RioScriptCall {
        RioScriptCall(source: source, handler: "appendnote", arguments: [noteTitle, html(for: text)])
    }
}
