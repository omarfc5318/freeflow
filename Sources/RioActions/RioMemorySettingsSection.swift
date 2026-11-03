import SwiftUI

/// Settings for Rio's memory. The lead embeds this in the Settings window: a switch, the list of
/// what Rio remembers (each row deletable) and a "forget everything" button. Memories never leave
/// this Mac.
struct RioMemorySettingsSection: View {
    @AppStorage(RioMemorySettings.enabledKey) private var enabled = true
    @State private var facts: [RioMemoryFact] = []
    @State private var confirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rio's memory")
                .font(.headline)
            Toggle("Let Rio remember things I tell it", isOn: $enabled)
            Text("Say \"Rio, remember my locker code is 4321\", then \"what's my locker code?\". Memories are kept in a private file on this Mac. They are never sent anywhere, not even to the AI provider, and Rio never writes them to its logs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if facts.isEmpty {
                Text("Nothing remembered yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(facts) { fact in
                    HStack(alignment: .firstTextBaseline) {
                        Text(fact.text)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            RioMemoryStore.shared.remove(id: fact.id)
                            reload()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Forget this")
                    }
                }
                Button("Forget everything", role: .destructive) { confirmingClear = true }
            }
        }
        .onAppear(perform: reload)
        .confirmationDialog("Forget everything Rio remembers?", isPresented: $confirmingClear) {
            Button("Forget everything", role: .destructive) {
                RioMemoryStore.shared.removeAll()
                reload()
            }
        }
    }

    private func reload() {
        facts = RioMemoryStore.shared.facts
    }
}
