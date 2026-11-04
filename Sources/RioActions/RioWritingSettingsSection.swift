import SwiftUI

/// Settings for Rio's writing actions. The lead embeds this in the Settings window.
struct RioWritingSettingsSection: View {
    @AppStorage(RioWritingSettings.enabledKey) private var enabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Writing help")
                .font(.headline)
            Toggle("Let Rio rewrite, write and paste for me", isOn: $enabled)
            Text("\"Make that more formal\", \"write for me a reply saying yes\" and \"paste it translated\" send what you said, the text being rewritten (your last dictation) and, for smart paste, the text on your clipboard to the AI provider you configured for dictation. Nothing is stored by Rio, and your clipboard is put back after pasting. Rio never types or pastes into terminals or password fields, and leaves your text alone if it changed while Rio was working.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !enabled {
                Text("Off: these commands are refused and nothing is sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
