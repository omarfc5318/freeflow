import AppKit
import SwiftUI

/// What finding files, tidying Downloads and copying screen text need and do (builder Q). The
/// lead embeds this in the Settings window.
struct RioFindSettingsSection: View {
    @State private var access = RioFindSources.messagesAccess()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Finding files and tidying Downloads")
                .font(.headline)
            Text("\"Find the PDF Ali sent me last week\" searches Spotlight, your Downloads folder, Mail's downloads and the attachments in Messages. It only reads file names and dates on this Mac, never message text, and nothing is sent anywhere. Results show in a small panel; documents open and anything else is shown in Finder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(statusText).font(.caption)
                Spacer()
                if access == .needsFullDiskAccess {
                    Button("Open Full Disk Access") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Button("Check again") { access = RioFindSources.messagesAccess() }
            }
            Text("\"Organize my Downloads\" always asks first, shows every move, never deletes or overwrites anything, leaves files from the last 2 minutes and unfinished downloads alone, and \"Rio, undo\" puts everything back. \"Copy the text from my screen\" reads the front window with on-device text recognition (English and Arabic) and puts the text on your clipboard.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusText: String {
        switch access {
        case .granted: return "Messages attachments: Rio can search them."
        case .needsFullDiskAccess: return "Messages attachments: turn on Full Disk Access for Rio Dictate to search them."
        case .absent: return "Messages attachments: none found on this Mac."
        }
    }
}
