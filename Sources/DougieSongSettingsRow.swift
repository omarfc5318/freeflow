import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings row for the song Rio dances the Dougie to: a local audio file the user owns,
/// and where in it to start (e.g. at the chorus). Without one, Rio dances to a built-in beat.
struct DougieSongSettingsRow: View {
    @AppStorage(TeddyDougieSong.pathKey) private var songPath = ""
    @AppStorage(TeddyDougieSong.startSecondsKey) private var startSeconds = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rio's Dougie song")
                .font(.headline)
            HStack(spacing: 8) {
                Text(songName)
                    .foregroundStyle(songPath.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button("Choose…", action: chooseSong)
                if !songPath.isEmpty {
                    Button("Clear") { songPath = "" }
                }
            }
            if !songPath.isEmpty {
                Stepper(value: $startSeconds, in: 0...600, step: 1) {
                    Text("Start at \(formatted(startSeconds))")
                }
            }
            Text("When you say \"Rio hit the Dougie\", this song plays in the background while he dances. Pick an audio file on your Mac. Without one, he dances to a built-in beat.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var songName: String {
        guard !songPath.isEmpty else { return "Built-in beat" }
        let name = (songPath as NSString).lastPathComponent
        return FileManager.default.isReadableFile(atPath: songPath) ? name : "\(name) (not found)"
    }

    private func formatted(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func chooseSong() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose the song Rio dances the Dougie to"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        songPath = url.path
        startSeconds = 0
    }
}
