import SwiftUI
import AppKit

/// Floating window that holds the editor. One instance; reopening while it is visible keeps
/// the user's in-progress edit unless a newer dictation arrived.
/// Used on the main thread only.
final class FixLastDictationPanel {
    static let shared = FixLastDictationPanel()

    private var panel: NSPanel?
    private var shownOriginal: String?

    func show(original: String, appState: AppState) {
        if let panel, panel.isVisible, shownOriginal == original {
            bringToFront(panel)
            return
        }
        close()
        let view = FixLastDictationView(
            original: original,
            onTeach: { edited in appState.teachRio(original: original, edited: edited) },
            onClose: { [weak self] in self?.close() }
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Fix Last Dictation"
        panel.contentView = NSHostingView(rootView: view)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.center()
        self.panel = panel
        shownOriginal = original
        bringToFront(panel)
    }

    func close() {
        panel?.close()
        panel = nil
        shownOriginal = nil
    }

    /// The app is a menu bar agent, so it must activate itself for the editor to take keystrokes.
    private func bringToFront(_ panel: NSPanel) {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}

struct FixLastDictationView: View {
    let original: String
    let onTeach: (String) -> Bool
    let onClose: () -> Void

    @State private var text: String
    @State private var message: String?
    @State private var didCopy = false

    init(original: String, onTeach: @escaping (String) -> Bool, onClose: @escaping () -> Void) {
        self.original = original
        self.onTeach = onTeach
        self.onClose = onClose
        _text = State(initialValue: original)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Correct the spelling of names and special words. Rio learns them for next time.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.body)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                .onChange(of: text) { _ in
                    message = nil
                    didCopy = false
                }

            if let message {
                Label(message, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button(didCopy ? "Copied" : "Copy fixed text") { copyFixedText() }
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Teach Rio") { teach() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(16)
        .frame(width: 460, height: 300)
    }

    private func teach() {
        if onTeach(text) {
            onClose()
        } else {
            message = "No new words found — only names and special spellings are learned"
        }
    }

    private func copyFixedText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        didCopy = true
    }
}
