import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings row for the song Rio dances the Dougie to: a local audio file the user owns,
/// and where in it to start (e.g. at the chorus). Without one, Rio dances to a built-in beat.
struct DougieSongSettingsRow: View {
    @AppStorage(TeddyDougieSong.pathKey) private var songPath = ""
    @AppStorage(TeddyDougieSong.startSecondsKey) private var startSeconds = 0.0
    @AppStorage(TeddyDougieSong.bpmKey) private var syncedBPM = 0.0
    @AppStorage(TeddyDougieSong.syncedStartSecondsKey) private var syncedStart = -1.0
    @State private var analysisTask: Task<Void, Never>?
    @State private var isAnalyzing = false

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
                if let caption = syncCaption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("When you say \"Rio hit the Dougie\", this song plays in the background while he dances. Pick an audio file on your Mac. Without one, he dances to a built-in beat.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { if !songPath.isEmpty && syncedStart < 0 { resync() } }
        .onChange(of: songPath) { _ in resync() }
        .onChange(of: startSeconds) { _ in resync() }
        .onDisappear { analysisTask?.cancel() }
    }

    private var syncCaption: String? {
        if isAnalyzing { return "Finding the beat…" }
        guard syncedBPM > 0, syncedStart >= 0 else { return nil }
        return String(format: "Synced to the beat: %.1f BPM, starts %@", syncedBPM, formatted(syncedStart, tenths: true))
    }

    /// Re-detects the beat for the current file and start, off the main thread. The previous result
    /// is dropped at once, and an analysis that finishes after the selection changed is ignored.
    private func resync() {
        analysisTask?.cancel()
        TeddyDougieSong.clearSync()
        guard !songPath.isEmpty else {
            isAnalyzing = false
            return
        }
        let path = songPath
        let requested = startSeconds
        isAnalyzing = true
        analysisTask = Task {
            let result = await Task.detached(priority: .utility) {
                TeddyDougieSong.analyzeBeat(at: URL(fileURLWithPath: path), requestedStart: requested)
            }.value
            guard !Task.isCancelled, path == songPath, requested == startSeconds else { return }
            isAnalyzing = false
            if let result {
                TeddyDougieSong.storeSync(bpm: result.bpm, syncedStart: result.syncedStart)
            }
        }
    }

    private var songName: String {
        guard !songPath.isEmpty else { return "Built-in beat" }
        let name = (songPath as NSString).lastPathComponent
        return FileManager.default.isReadableFile(atPath: songPath) ? name : "\(name) (not found)"
    }

    private func formatted(_ seconds: Double, tenths: Bool = false) -> String {
        if tenths {
            let rounded = (seconds * 10).rounded() / 10
            let minutes = Int(rounded) / 60
            return String(format: "%d:%04.1f", minutes, rounded - Double(minutes * 60))
        }
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
