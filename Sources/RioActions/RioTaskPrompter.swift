import AppKit
import SwiftUI

/// The panel the task agent uses to ask before a risky step ("Do this exact step?") and to hand
/// control back to the user (a password, a question). It reuses the confirmation panel and
/// content types. A confirmation takes the keyboard (Return = yes, Escape = no); a hand-back does
/// NOT, so the user can type in the page behind it, then press Continue. Silence never counts as
/// yes: confirmations lapse to "no" after 30 s, hand-backs after 2 minutes.
@MainActor
final class RioTaskPrompter: RioTaskUserPrompting {
    private static let confirmTimeout: TimeInterval = 30
    private static let handBackTimeout: TimeInterval = 120

    private var panel: RioConfirmationPanel?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeout: Task<Void, Never>?

    func confirmStep(title: String, detail: String) async -> Bool {
        await ask(
            RioConfirmationContent(title: title, detail: detail, confirmLabel: "Do it"),
            takesKeyboard: true, timeoutSeconds: Self.confirmTimeout, footer: "Cancels by itself in 30 seconds."
        )
    }

    func handBack(message: String) async -> Bool {
        await ask(
            RioConfirmationContent(title: "Rio needs you", detail: message, confirmLabel: "Continue"),
            takesKeyboard: false, timeoutSeconds: Self.handBackTimeout, footer: "Rio never types passwords, card numbers or codes."
        )
    }

    /// Ends whatever question is open (a stop trigger fired).
    func dismiss() { finish(false) }

    private func ask(_ content: RioConfirmationContent, takesKeyboard: Bool, timeoutSeconds: TimeInterval, footer: String) async -> Bool {
        finish(false)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            show(content, takesKeyboard: takesKeyboard, footer: footer)
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finish(false)
            }
        }
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

    private func show(_ content: RioConfirmationContent, takesKeyboard: Bool, footer: String) {
        let view = RioTaskPromptView(
            content: content, footer: footer,
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
        if takesKeyboard { panel.makeKey() }
    }

    private func origin(for size: NSSize) -> NSPoint {
        guard let screen = NSScreen.screens.first else { return .zero }
        let anchor = RioCompanionLayout.anchor(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        let visible = screen.visibleFrame
        let x = min(max(anchor.x, visible.minX + 8), visible.maxX - size.width - 8)
        let y = min(max(anchor.y + 96, visible.minY + 8), visible.maxY - size.height - 8)
        return NSPoint(x: x, y: y)
    }
}

private struct RioTaskPromptView: View {
    let content: RioConfirmationContent
    let footer: String
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
            Text(footer)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Stop", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(content.confirmLabel, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .padding(2)
    }
}
