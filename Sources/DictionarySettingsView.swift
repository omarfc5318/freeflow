import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Vocabulary (spellings the cleanup step should use) and replacements (fixed rewrites).
struct DictionarySettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var vocabularyInput = ""
    /// The vocabulary the editor buffer was last synced from; lets a commit keep words learned meanwhile.
    @State private var vocabularyBase = ""
    @FocusState private var vocabularyFocused: Bool
    @State private var newHeard = ""
    @State private var newReplacement = ""
    @State private var fileMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                SettingsCard("Vocabulary", icon: "text.book.closed.fill") {
                    vocabularySection
                }
                SettingsCard("Replacements", icon: "arrow.left.arrow.right") {
                    replacementsSection
                }
            }
            .padding(24)
        }
        .onAppear { syncVocabularyBuffer() }
        .onDisappear { commitVocabulary() }
        .onChange(of: appState.customVocabulary) { vocabulary in
            // Pick up words learned or imported while this tab is open, unless mid-edit.
            if !vocabularyFocused { syncVocabularyBuffer(vocabulary) }
        }
    }

    // MARK: Vocabulary

    private var vocabularySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Names, jargon and other words to spell exactly this way after dictation.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $vocabularyInput)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 100, maxHeight: 180)
                .focused($vocabularyFocused)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .onChange(of: vocabularyFocused) { focused in
                    if !focused { commitVocabulary() }
                }

            HStack {
                Text("Separate entries with commas, new lines, or semicolons.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Import…", action: importVocabulary)
                Button("Export…", action: exportVocabulary)
                    .disabled(appState.customVocabulary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let fileMessage {
                Text(fileMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Learn from my corrections", isOn: $appState.learnFromCorrectionsEnabled)
                .padding(.top, 4)

            Text("When you fix a misheard name or term right after dictating, \(AppName.displayName) adds the corrected spelling here so it's right next time. The text field is read on this Mac only while you edit; only the corrected word is saved.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func syncVocabularyBuffer(_ vocabulary: String? = nil) {
        let latest = vocabulary ?? appState.customVocabulary
        vocabularyInput = latest
        vocabularyBase = latest
    }

    private func commitVocabulary() {
        let merged = VocabularyMergeCore.commit(
            buffer: vocabularyInput, base: vocabularyBase, current: appState.customVocabulary
        )
        if appState.customVocabulary != merged {
            appState.customVocabulary = merged
        }
        syncVocabularyBuffer(merged)
    }

    private func importVocabulary() {
        commitVocabulary()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .commaSeparatedText, .text]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a text or CSV file with one word or phrase per line."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let added = try appState.importVocabulary(from: url)
            syncVocabularyBuffer()
            fileMessage = added.isEmpty
                ? "No new words found in \(url.lastPathComponent)."
                : "Added \(added.count) word\(added.count == 1 ? "" : "s") from \(url.lastPathComponent)."
        } catch {
            fileMessage = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func exportVocabulary() {
        commitVocabulary()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(AppName.displayName) Vocabulary.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try appState.exportVocabulary(to: url)
            fileMessage = "Exported to \(url.lastPathComponent)."
        } catch {
            fileMessage = "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: Replacements

    private var replacementsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("When a word keeps being misheard the same way, rewrite it every time. Matching ignores case and only replaces whole words.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !appState.wordReplacements.isEmpty {
                VStack(spacing: 6) {
                    ForEach($appState.wordReplacements) { $rule in
                        HStack(spacing: 8) {
                            TextField("Heard", text: $rule.heard)
                                .textFieldStyle(.roundedBorder)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)
                            TextField("Write instead", text: $rule.replacement)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                appState.wordReplacements.removeAll { $0.id == rule.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                            .help("Delete this replacement")
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("When I say…", text: $newHeard)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addReplacement)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                TextField("Write…", text: $newReplacement)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addReplacement)
                Button("Add", action: addReplacement)
                    .disabled(!canAddReplacement)
            }

            Text("Example: \"clawed\" → \"Claude\", or \"gonna\" → \"going to\".")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var canAddReplacement: Bool {
        !newHeard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !newReplacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Adding a phrase that already has a rule updates that rule instead of duplicating it.
    private func addReplacement() {
        guard canAddReplacement else { return }
        let heard = newHeard.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = newReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = appState.wordReplacements.firstIndex(where: { $0.heard.lowercased() == heard.lowercased() }) {
            appState.wordReplacements[index].replacement = replacement
        } else {
            appState.wordReplacements.append(WordReplacement(heard: heard, replacement: replacement))
        }
        newHeard = ""
        newReplacement = ""
    }
}
