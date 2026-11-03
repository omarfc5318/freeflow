import SwiftUI

/// Settings for Rio's smart actions. The lead embeds this in the Settings window.
struct RioSmartSettingsSection: View {
    @AppStorage(RioSmartSettings.enabledKey) private var enabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Smart actions")
                .font(.headline)
            Toggle("Let Rio work out commands with AI", isOn: $enabled)
            Text("When Rio doesn't recognise a command, your words (and today's date and time zone) are sent to the AI provider you configured for dictation, the same one that cleans up your text. For \"summarize / explain / translate / improve this\", the text you have selected is sent too. Reading a message, a page or your selection aloud stays on your Mac. Texts are only sent after you confirm them in Rio's panel. Nothing is stored by Rio.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !enabled {
                Text("Off: only commands Rio understands on its own will work, and nothing is sent for smart actions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
