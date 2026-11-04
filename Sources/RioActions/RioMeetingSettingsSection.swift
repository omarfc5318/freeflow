import SwiftUI

/// Where the meeting copilot and Claude Code by voice read their switches (builder T).
enum RioMeetingSettings {
    static let enabledKey = "rio_meeting_copilot_enabled"
    static let sendAudioKey = "rio_meeting_send_audio_enabled"
    static let claudeStatusKey = "rio_claude_code_status_ai_enabled"

    /// Off by default: nothing listens until the owner turns it on and says "start".
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
    }

    /// Off by default: asking about the call is what sends audio, so it needs its own yes.
    static var isSendAllowed: Bool {
        UserDefaults.standard.object(forKey: sendAudioKey) as? Bool ?? false
    }

    static var isClaudeStatusAllowed: Bool {
        UserDefaults.standard.object(forKey: claudeStatusKey) as? Bool ?? true
    }
}

/// Settings for the meeting copilot and Claude Code by voice. The lead embeds this in the Settings window.
struct RioMeetingSettingsSection: View {
    @AppStorage(RioMeetingSettings.enabledKey) private var enabled = false
    @AppStorage(RioMeetingSettings.sendAudioKey) private var sendAudio = false
    @AppStorage(RioMeetingSettings.claudeStatusKey) private var claudeStatus = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Meeting copilot")
                .font(.headline)
            Toggle("Allow the meeting copilot", isOn: $enabled)
            Text("Say \"start the meeting copilot\" and Rio keeps the last five minutes of the call (the sound your Mac plays, plus your microphone) in memory only. Nothing is saved or logged, and it is wiped when Rio stops. It stops when you say \"stop the meeting copilot\", about two minutes after the call ends, or after two hours. A badge on the bear shows while it listens. It needs Screen & System Audio Recording permission in System Settings, Privacy and Security.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Let Rio send call audio when I ask a question", isOn: $sendAudio)
                .disabled(!enabled)
            Text("Audio leaves your Mac only when you ask \"what did they just say\", \"action items\" or \"recap the meeting\". Then the last minute (or the buffer, for action items and recap) goes to your transcription provider, and the text goes to your AI provider, the same ones you set up for dictation. Off: those questions are refused and nothing is sent.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            Text("Claude Code by voice")
                .font(.headline)
            Text("\"Tell Claude to fix the tests\", \"approve that\", \"deny that\" and \"what's Claude doing\" work with a Claude Code session open in Warp, Terminal or iTerm. Rio reads the window's text through Accessibility, pastes your prompt and presses Return, or presses the key Claude Code's permission prompt expects. Approving always asks you first and shows the prompt. Needs Accessibility permission.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Let Rio send Claude Code's screen text to AI for \"what's Claude doing\"", isOn: $claudeStatus)
            Text("Only the last screenful of that terminal window is sent, to your AI provider, only when you ask. Off: Rio still tells you when Claude is waiting for permission, but won't summarise.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
