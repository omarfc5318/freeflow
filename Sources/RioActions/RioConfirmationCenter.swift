import AppKit
import SwiftUI

/// The panel that asks before Rio sends anything: who it goes to and the exact text. Return
/// confirms, Escape or Cancel declines, and 20 seconds of silence counts as Cancel. It never
/// confirms on its own.
@MainActor
final class RioConfirmationCenter: RioConfirming {
    static let shared = RioConfirmationCenter()

    private var panel: RioConfirmationPanel?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeout: Task<Void, Never>?

    func confirm(_ action: RioAction) async -> Bool {
        // Only one question at a time; a newer one cancels the older.
        finish(false)
        guard let content = content(for: action) else { return false }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            show(content)
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(RioConfirmationContent.timeoutSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finish(false)
            }
        }
    }

    private func content(for action: RioAction) -> RioConfirmationContent? {
        var recipient: String?
        if case .sendMessage(let to, _) = action { recipient = RioContactsLookup.resolvedName(spoken: to) }
        let appName = RioMessagingApps.info(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)?.name
        var title: String?
        if case .replyInConversation = action { title = Self.frontWindowTitle() }
        return RioConfirmationContent.make(for: action, appName: appName, resolvedRecipient: recipient, conversationTitle: title)
    }

    /// The front window's title (the conversation a reply would land in), read through
    /// Accessibility. Shown in the question only; never stored or logged.
    private static func frontWindowTitle() -> String? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }

    private func finish(_ result: Bool) {
        timeout?.cancel()
        timeout = nil
        panel?.orderOut(nil)
        panel = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: result)
    }

    private func show(_ content: RioConfirmationContent) {
        let view = RioConfirmationView(
            content: content,
            onConfirm: { [weak self] in self?.finish(true) },
            onCancel: { [weak self] in self?.finish(false) }
        )
        let hosting = NSHostingView(rootView: view)
        let size = NSSize(width: 340, height: max(150, min(360, hosting.fittingSize.height)))
        let panel = RioConfirmationPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.contentView = hosting
        panel.onConfirm = { [weak self] in self?.finish(true) }
        panel.onCancel = { [weak self] in self?.finish(false) }
        panel.setFrameOrigin(origin(for: size))
        self.panel = panel
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    /// Just above the corner bear, inside the visible screen.
    private func origin(for size: NSSize) -> NSPoint {
        guard let screen = RioCompanionHub.homeScreen() ?? NSScreen.screens.first else { return .zero }
        let anchor = RioCompanionLayout.anchor(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        let visible = screen.visibleFrame
        let x = min(max(anchor.x, visible.minX + 8), visible.maxX - size.width - 8)
        let y = min(max(anchor.y + 96, visible.minY + 8), visible.maxY - size.height - 8)
        return NSPoint(x: x, y: y)
    }
}

/// A panel that takes the keyboard (for Return and Escape) without activating Rio, so the app
/// the user is working in stays frontmost.
final class RioConfirmationPanel: NSPanel {
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        sharingType = RioCompanionPrivacy.sharingType
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onConfirm?()
        case 53: onCancel?()
        default: break
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

private struct RioConfirmationView: View {
    let content: RioConfirmationContent
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(content.title)
                .font(.system(size: 14, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                Text(content.detail)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
            Text("Cancels by itself in 20 seconds.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(content.confirmLabel, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .padding(2)
    }
}
