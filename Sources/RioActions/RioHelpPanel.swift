import AppKit
import SwiftUI

private let rioEscapeKeyCode: UInt16 = 53

/// The cheat sheet Rio holds up: a small non-activating panel next to the corner bear listing
/// what he can do, grouped by category with phrases that work. It never steals focus. It closes
/// on a click (on it or anywhere else), on Esc, or on its own after 20 seconds, and while it is
/// open `RioCompanionCenter.isHelpVisible` is true so the bear holds up his sign.
@MainActor final class RioHelpPanelController {
    static let shared = RioHelpPanelController()

    private var panel: HelpPanel?
    private var autoCloseTimer: Timer?
    private var monitors: [Any] = []
    private var resizeObserver: NSObjectProtocol?
    private let center = RioCompanionCenter.shared

    var isVisible: Bool { panel != nil }

    func show() {
        if let panel {
            restartAutoClose()
            panel.orderFrontRegardless()
            return
        }
        let panel = HelpPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
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
        let hosting = NSHostingView(rootView: RioHelpView(categories: RioHelpCatalogue.categories) { [weak self] in
            self?.close()
        })
        // Rio sizes the panel himself: SwiftUI resizing it later kept the top edge where a first,
        // too-tall measurement put it, 358 pt above the screen (finding 75).
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.setFrame(frame(for: Self.measuredSize(of: hosting)), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        center.isHelpVisible = true
        installMonitors()
        observeResizes(of: panel)
        restartAutoClose()
        // Measure again once the grid has laid out at its real width, then place it for good.
        DispatchQueue.main.async { [weak self, weak panel, weak hosting] in
            MainActor.assumeIsolated {
                guard let self, let panel, let hosting, panel === self.panel else { return }
                panel.setFrame(self.frame(for: Self.measuredSize(of: hosting)), display: true)
            }
        }
    }

    /// The view's height at the panel's fixed width (never measured without a width).
    private static func measuredSize(of hosting: NSView) -> CGSize {
        hosting.setFrameSize(NSSize(width: panelWidth, height: max(hosting.frame.height, 10)))
        hosting.layoutSubtreeIfNeeded()
        return CGSize(width: panelWidth, height: hosting.fittingSize.height)
    }

    /// Whatever resizes the panel, it stays wholly on its screen.
    private func observeResizes(of panel: NSPanel) {
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak panel] _ in
            MainActor.assumeIsolated {
                guard let panel, let visible = Self.homeScreen()?.visibleFrame else { return }
                let clamped = RioPanelPlacement.clamped(panel.frame, to: visible, margin: Self.margin)
                if clamped != panel.frame { panel.setFrame(clamped, display: true) }
            }
        }
    }

    func close() {
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil
        removeMonitors()
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resizeObserver = nil
        panel?.orderOut(nil)
        panel = nil
        center.isHelpVisible = false
    }

    // MARK: Placement

    private static var panelWidth: CGFloat { RioHelpView.width }
    private static let margin: CGFloat = 16

    /// To the right of the bear in the bottom-left corner, kept on screen.
    private func frame(for size: CGSize) -> CGRect {
        guard let screen = Self.homeScreen() else { return CGRect(origin: .zero, size: size) }
        let bearClearance: CGFloat = 84
        return RioPanelPlacement.frame(
            size: size, visible: screen.visibleFrame, leftInset: RioCompanionLayout.edgeInset + bearClearance, margin: Self.margin
        )
    }

    private static func homeScreen() -> NSScreen? {
        RioCompanionHub.homeScreen() ?? NSScreen.screens.first
    }

    // MARK: Closing

    private func restartAutoClose() {
        autoCloseTimer?.invalidate()
        autoCloseTimer = RioMainTimer.schedule(interval: RioHelpCatalogue.autoCloseSeconds, repeats: false) { [weak self] in
            self?.close()
        }
    }

    /// Esc anywhere and a click anywhere close it. The handlers only look at the key code and the
    /// event type, never at what was typed.
    private func installMonitors() {
        removeMonitors()
        let react: @Sendable (NSEvent) -> Void = { [weak self] event in
            let isEscape = event.type == .keyDown && event.keyCode == rioEscapeKeyCode
            let isClick = event.type == .leftMouseDown || event.type == .rightMouseDown
            guard isEscape || isClick else { return }
            MainActor.assumeIsolated { self?.close() }
        }
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: react) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            react(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }
}

/// Borderless panels refuse key status by default; this one accepts it so Esc reaches it even
/// when the app behind it is frontmost.
private final class HelpPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

// MARK: - View

struct RioHelpView: View {
    let categories: [RioHelpCategory]
    var keys: [RioHelpKey] = RioHelpCatalogue.keys
    var tips: [RioHelpTip] = RioHelpCatalogue.tips
    let onClose: () -> Void

    static let width: CGFloat = 720
    private static let accent = Color(red: 0.62, green: 0.38, blue: 0.2)
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .topLeading), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Things you can say to Rio")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Spacer()
                Text("Esc or click to close")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(categories, id: \.title) { category in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(category.title, systemImage: category.symbol)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(Self.accent)
                        ForEach(category.examples.prefix(RioHelpCatalogue.shownExamples), id: \.self) { example in
                            Text("\u{201C}\(example)\u{201D}")
                                .font(.system(size: 11.5, design: .rounded))
                                .foregroundStyle(.primary.opacity(0.85))
                                .lineLimit(1)
                        }
                    }
                }
            }
            Divider()
            HStack(alignment: .top, spacing: 14) {
                ForEach(tips, id: \.title) { tip in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(tip.title, systemImage: tip.symbol)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(Self.accent)
                        Text(tip.detail)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(tip.examples.prefix(2).map { "\u{201C}\($0)\u{201D}" }.joined(separator: "  "))
                            .font(.system(size: 11.5, design: .rounded))
                            .foregroundStyle(.primary.opacity(0.85))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(keys, id: \.keys) { key in
                    HStack(spacing: 4) {
                        Text(key.keys)
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Self.accent.opacity(0.14)))
                        Text(key.meaning)
                            .font(.system(size: 10.5, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: Self.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Self.accent.opacity(0.35), lineWidth: 1.5)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onClose)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Things you can say to Rio")
    }
}
