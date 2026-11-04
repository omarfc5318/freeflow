import SwiftUI

/// Settings for the multi-step task agent: the lead embeds this next to the screen settings.
/// Both switches default ON, and the sentence says what each step sends and to whom.
struct RioTaskSettingsSection: View {
    @AppStorage(RioTaskSettings.enabledKey) private var enabled = true
    @AppStorage(RioTaskSettings.screenshotsKey) private var screenshots = true
    @AppStorage(RioScreenSettings.enabledKey) private var screenUnderstanding = true

    private var providerName: String {
        let base = RioSmartSettings.llmConfig()?.baseURL ?? ""
        return URL(string: base)?.host ?? "your AI provider"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tasks")
                .font(.headline)
            Toggle("Let Rio do multi-step tasks in the browser", isOn: $enabled)
            Text(RioTaskObservationPolicy.disclosure(providerName: providerName))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if enabled {
                Toggle("Include a picture of the window", isOn: $screenshots)
                    .disabled(!screenUnderstanding)
                Text(screenUnderstanding
                     ? "Off: only the list of controls is sent, never a picture."
                     : "Pictures are off because \"Let Rio look at my screen\" is off, so only the list of controls is sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Rio never reads password managers or privacy settings, never types into the browser's address bar, and asks before anything that buys, sends, deletes or opens another site.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
