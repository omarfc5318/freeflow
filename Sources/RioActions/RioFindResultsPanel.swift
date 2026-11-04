import AppKit
import SwiftUI

private let rioFindEscapeKeyCode: UInt16 = 53

/// The small panel "find that thing" shows next to the bear: the best matches, one row each.
/// Clicking a row opens it (documents) or shows it in Finder (anything else), through the same
/// allowlist as "open my resume". It never takes focus, closes on Esc, outside click, or after
/// 25 seconds, and holds file names only for as long as it is on screen.
@MainActor final class RioFindResultsPanel {
    static let shared = RioFindResultsPanel()

    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        let detail: String
    }

    private static let autoCloseSeconds: TimeInterval = 25
    private static let width: CGFloat = 420

    private var panel: Panel?
    private var timer: Timer?
    private var monitors: [Any] = []

    func show(rows: [Row], onSelect: @escaping (String) -> Void) {
        close()
        let panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 10),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.sharingType = RioCompanionPrivacy.sharingType
        panel.onEscape = { [weak self] in self?.close() }
        let hosting = NSHostingView(rootView: RioFindResultsView(rows: rows) { [weak self] id in
            onSelect(id)
            self?.close()
        })
        panel.contentView = hosting
        panel.setFrame(frame(for: hosting.fittingSize), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        installMonitors()
        let timer = Timer(timeInterval: Self.autoCloseSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func close() {
        timer?.invalidate()
        timer = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        panel?.orderOut(nil)
        panel = nil
    }

    private func frame(for size: CGSize) -> CGRect {
        guard let screen = RioCompanionHub.homeScreen() ?? NSScreen.screens.first else { return CGRect(origin: .zero, size: size) }
        let visible = screen.visibleFrame
        let x = min(visible.minX + RioCompanionLayout.edgeInset + 84, visible.maxX - size.width - 16)
        return CGRect(origin: CGPoint(x: max(x, visible.minX + 16), y: visible.minY + 16), size: size)
    }

    /// Esc and clicks outside the panel close it. The handlers read only the key code and event type.
    private func installMonitors() {
        let react: @Sendable (NSEvent) -> Void = { [weak self] event in
            let isEscape = event.type == .keyDown && event.keyCode == rioFindEscapeKeyCode
            let isOutsideClick = event.type == .leftMouseDown || event.type == .rightMouseDown
            guard isEscape || isOutsideClick else { return }
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                if isOutsideClick, event.window === panel { return }
                self.close()
            }
        }
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: react) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            react(event)
            return event
        }) { monitors.append(local) }
    }

    private final class Panel: NSPanel {
        var onEscape: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { onEscape?() }
    }
}

struct RioFindResultsView: View {
    let rows: [RioFindResultsPanel.Row]
    let onSelect: (String) -> Void

    private let accent = Color(red: 0.62, green: 0.38, blue: 0.2)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Here's what I found")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            ForEach(rows) { row in
                Button { onSelect(row.id) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name).font(.system(size: 13, weight: .medium, design: .rounded)).lineLimit(1)
                        Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(row.name), \(row.detail)")
            }
            Text("Click one to open it. Esc to close.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 420, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(accent.opacity(0.35), lineWidth: 1.5))
        )
    }
}
