import SwiftUI

/// Settings for automations: scheduled commands, triggers and macros, each with a delete button,
/// plus anything Rio had to skip. The lead embeds this in the Settings window.
struct RioAutomationSettingsSection: View {
    @ObservedObject private var recorder = RioMacroRecorder.shared
    @State private var data = RioAutomationStore.shared.data

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Automations and macros")
                .font(.headline)
            Text("Say \"Rio, every weekday at 9 open Slack\", \"Rio, when I connect my AirPods open Spotify\" or \"Rio, watch me\". Everything is kept in a private file on this Mac and nothing is sent anywhere. A macro stores the text you typed while recording (never in password fields). Wi-Fi triggers ask for Location access once, only to read the network name.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if recorder.isRecording {
                Text("Recording \"\(recorder.name)\": \(recorder.stepCount) steps so far.")
                    .font(.callout)
            }
            if data.isEmpty {
                Text("Nothing set up yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(data.schedules) { item in
                row("Scheduled: \(RioAutomationText.label(item))") { RioAutomationStore.shared.removeSchedule(id: item.id) }
            }
            ForEach(data.triggers) { rule in
                row("Trigger: \(RioAutomationText.label(rule))") {
                    RioAutomationStore.shared.removeTrigger(id: rule.id)
                    RioAutomationCenter.shared.refreshWatcher()
                }
            }
            ForEach(data.macros) { macro in
                row("Macro: \(macro.name) (\(macro.steps.count) steps)") { RioAutomationStore.shared.removeMacro(id: macro.id) }
            }
            if !data.notes.isEmpty {
                ForEach(Array(data.notes.enumerated()), id: \.offset) { _, note in
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Dismiss notes") { RioAutomationStore.shared.clearNotes() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: RioAutomationStore.changedNotification)) { _ in
            data = RioAutomationStore.shared.data
        }
        .onAppear { data = RioAutomationStore.shared.data }
    }

    private func row(_ text: String, delete: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: delete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete")
        }
    }
}
