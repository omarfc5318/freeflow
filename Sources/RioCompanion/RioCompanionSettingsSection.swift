import SwiftUI

/// Settings for the corner bear. The lead embeds this in the Settings window.
struct RioCompanionSettingsSection: View {
    @AppStorage(RioStyle.defaultsKey) private var styleRaw = RioStyle.corner.rawValue
    @AppStorage(RioCompanionHub.dockRunDefaultsKey) private var dockRunEnabled = true
    @AppStorage(RioCompanionPrivacy.defaultsKey) private var showInCaptures = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rio style")
                .font(.headline)
            Picker("Rio style", selection: $styleRaw) {
                Text("Corner bear").tag(RioStyle.corner.rawValue)
                Text("Classic pill").tag(RioStyle.pill.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(styleRaw == RioStyle.pill.rawValue
                 ? "Rio drops down from the menu bar while you dictate, like before."
                 : "A small Rio sleeps in the bottom-left corner of your screen. Dictation wakes him and he speaks into a mic there instead of the pill.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Run to the Dock icon when opening an app", isOn: $dockRunEnabled)
                .disabled(styleRaw == RioStyle.pill.rawValue)
            Text("Only with the Dock at the bottom and not hidden. The app never waits for him.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Show Rio in screenshots & screen shares", isOn: $showInCaptures)
            Text("Off by default: Rio stays on your screen but is left out of screenshots, recordings and screen sharing.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
