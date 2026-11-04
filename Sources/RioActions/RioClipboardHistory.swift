import AppKit
import ApplicationServices
import Foundation

/// Remembers the last 20 text copies, in memory only. Nothing is written to disk or logged, and
/// concealed, transient and password-manager copies are never stored (`RioClipboardFilter`).
/// Call `start()` at launch to remember everything from then on; the Knowledge handler also
/// starts it on first use, so history then begins at that moment.
@MainActor
final class RioClipboardHistory {
    static let shared = RioClipboardHistory()

    private static let pollInterval: TimeInterval = 0.75
    private static let restoreDelay: TimeInterval = 0.6

    private(set) var buffer = RioClipboardBuffer()
    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var lastChangeCount: Int
    /// Change counts caused by Rio's own paste and restore, which must not become history.
    private var ownChangeCounts = RioOwnChangeCounts()

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount - 1
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        poll()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func clear() { buffer = buffer.cleared() }

    private func poll() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        if ownChangeCounts.consume(count) { return }
        guard let snapshot = readCurrent(), let text = snapshot.text, !snapshot.isConcealed else { return }
        if RioClipboardFilter.shouldSkip(sourceBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) { return }
        buffer = buffer.adding(text, at: Date())
    }

    // MARK: Reading the live clipboard

    struct Snapshot {
        let text: String?
        let isConcealed: Bool
        let hasNonText: Bool
    }

    /// What is on the clipboard right now (not from history). Nil text for concealed content.
    func readCurrent() -> Snapshot? {
        let types = pasteboard.types?.map(\.rawValue) ?? []
        if RioClipboardFilter.shouldSkip(types: types) {
            return Snapshot(text: nil, isConcealed: true, hasNonText: false)
        }
        let text = pasteboard.string(forType: .string)
        let hasNonText = types.contains { type in
            type.hasPrefix("public.image") || type == "public.file-url" || type == "public.png" || type == "public.tiff"
        }
        return Snapshot(text: text, isConcealed: false, hasNonText: hasNonText && (text?.isEmpty ?? true))
    }

    // MARK: Pasting

    enum PasteError: Error { case needsAccessibility, couldNotPost }

    /// Puts `text` on the clipboard, presses Command-V, then puts the user's previous clipboard
    /// back (every type, so images and concealed markers survive).
    func paste(_ text: String) async throws {
        guard AXIsProcessTrusted() else { throw PasteError.needsAccessibility }
        let saved = saveItems()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ownChangeCounts.insert(pasteboard.changeCount)
        guard Self.postCommandV() else {
            restore(saved)
            throw PasteError.couldNotPost
        }
        try? await Task.sleep(nanoseconds: UInt64(Self.restoreDelay * 1_000_000_000))
        restore(saved)
    }

    private func saveItems() -> [[(NSPasteboard.PasteboardType, Data)]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private func restore(_ saved: [[(NSPasteboard.PasteboardType, Data)]]) {
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = saved.map { entries in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
        ownChangeCounts.insert(pasteboard.changeCount)
    }

    private static func postCommandV() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        let commandV: CGKeyCode = 9
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: commandV, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: commandV, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
