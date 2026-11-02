import AppKit
import SwiftUI

/// A place to dictate notes that aren't meant for any other app.
struct ScratchpadView: View {
    @ObservedObject private var store = ScratchpadStore.shared
    @State private var selectedID: UUID?
    @FocusState private var editorFocused: Bool

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    var body: some View {
        HStack(spacing: 0) {
            notesList
                .frame(width: 210)
            Divider()
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if selectedID == nil { selectedID = store.notes.first?.id }
        }
        .onDisappear { store.saveNow() }
    }

    private var selectedNote: ScratchpadNote? {
        store.notes.first { $0.id == selectedID }
    }

    private var notesList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let loadError = store.loadError {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(12)
            }
            HStack {
                Text("Notes")
                    .font(.headline)
                Spacer()
                Button(action: newNote) {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .help("New note")
            }
            .padding(12)

            if store.notes.isEmpty {
                Text("No notes yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.notes) { note in
                            Button {
                                selectedID = note.id
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(note.title)
                                        .font(.body)
                                        .lineLimit(1)
                                    Text(Self.dateFormatter.string(from: note.updatedAt))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(selectedID == note.id ? Color.accentColor.opacity(0.15) : Color.clear)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let note = selectedNote {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Click in the note and dictate with your shortcut. Notes stay on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(note.text, forType: .string)
                    }
                    .disabled(note.text.isEmpty)
                    Button("Delete", role: .destructive) {
                        deleteNote(note.id)
                    }
                }
                TextEditor(text: Binding(
                    get: { store.notes.first { $0.id == note.id }?.text ?? "" },
                    set: { store.updateText($0, for: note.id) }
                ))
                .font(.body)
                .focused($editorFocused)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
            }
            .padding(16)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "note.text")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                Text("Dictate notes here")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Ideas, to-dos and drafts that don't belong in another app yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button("New Note", action: newNote)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
    }

    private func newNote() {
        selectedID = store.createNote().id
        editorFocused = true
    }

    private func deleteNote(_ id: UUID) {
        let index = store.notes.firstIndex { $0.id == id } ?? 0
        store.delete(id)
        let remaining = store.notes
        selectedID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
    }
}
