import SwiftUI

/// Settings for Rio's voice. The lead embeds this in the Settings window.
struct RioVoiceSettingsSection: View {
    @AppStorage(RioVoiceDefaults.enabledKey) private var talksBack = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rio's voice")
                .font(.headline)
            Toggle("Rio talks back", isOn: $talksBack)
            Text("Rio says what he did out loud, using a voice built into your Mac. He stays quiet while another app is using the microphone, such as during a call, and while he is listening to you.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Hear Rio") {
                RioVoice.shared.speak("Hi, I'm Rio! I can open apps, set timers, and more.")
            }
            .disabled(!talksBack)
        }
    }
}
