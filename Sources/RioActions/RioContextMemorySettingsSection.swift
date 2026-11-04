import SwiftUI

/// Settings for Rio's context and memory: the writing-style profile (on/off, what Rio learned,
/// reset) and a note on follow-ups and dictation search. All of it stays on this Mac.
struct RioContextMemorySettingsSection: View {
    @AppStorage(RioStyleProfileProvider.enabledKey) private var styleEnabled = true
    @State private var lines: [String] = []
    @State private var confirmingReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Context and memory")
                .font(.headline)
            Text("Rio understands follow-ups like \"open it again\", \"close that\" or \"send that to Ali too\" for a few minutes after a command, and can search your dictations: \"what did I say about the budget?\". Both work on this Mac only and are never logged.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Learn my writing style", isOn: $styleEnabled)
                .onChange(of: styleEnabled) { _ in reload() }
            Text("Rio looks at your recent dictations for habits such as lowercase starts, final full stops, emoji, sign-offs and mixing Arabic and English, then uses them to tidy your dictation and to write for you. It only keeps counts and a few stock phrases, never your sentences, and nothing is saved to disk.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if styleEnabled {
                if lines.isEmpty {
                    Text("Nothing learned yet. Rio needs about \(RioStyleProfile.minimumSamples) dictations.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("What Rio learned")
                            .font(.subheadline)
                        ForEach(lines, id: \.self) { Text($0).font(.callout) }
                    }
                }
                Button("Reset what Rio learned", role: .destructive) { confirmingReset = true }
            }
        }
        .onAppear(perform: reload)
        .confirmationDialog("Forget your writing style?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) {
                RioStyleProfileProvider.shared.reset()
                reload()
            }
        } message: {
            Text("Rio starts again from your next dictation.")
        }
    }

    private func reload() {
        lines = RioStyleProfileProvider.shared.current?.learnedLines() ?? []
    }
}
