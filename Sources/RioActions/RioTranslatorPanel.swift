import AppKit
import Combine
import SwiftUI

/// What the subtitle card shows. The mode writes it; the view only reads it.
@MainActor final class RioTranslatorCaptionModel: ObservableObject {
    @Published var board = RioSubtitleBoard()
    @Published var isPaused = false
    /// A short problem line ("Offline"), cleared by the next good result.
    @Published var status: String?
    /// Where the room audio goes, shown on the card the whole time.
    @Published var providerHost = ""
    @Published var otherLanguage = RioTranslatorLanguage.arabic
}

private struct RioCaptionLineView: View {
    let line: RioSubtitleLine

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            text(line.original, size: 12, opacity: 0.62)
            if let translation = line.translation {
                text(translation, size: 17, opacity: 1).fontWeight(.semibold)
            } else {
                text("…", size: 17, opacity: 0.5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }

    private func text(_ value: String, size: CGFloat, opacity: Double) -> some View {
        let isRTL = RioArabicText.isArabic(value)
        return Text(value)
            .font(.system(size: size))
            .foregroundStyle(Color.white.opacity(opacity))
            .multilineTextAlignment(isRTL ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: isRTL ? .trailing : .leading)
            .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct RioTranslatorCaptionView: View {
    @ObservedObject var model: RioTranslatorCaptionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "headphones")
                Text("Live translation · English ⇄ \(model.otherLanguage.name)")
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                Circle()
                    .fill(model.isPaused ? Color.orange : Color.red)
                    .frame(width: 7, height: 7)
            }
            .foregroundStyle(Color.white.opacity(0.85))
            .padding(.trailing, 26)

            ForEach(model.board.lines) { RioCaptionLineView(line: $0) }

            if model.board.lines.isEmpty {
                Text(model.isPaused ? "Paused while Rio is busy…" : "Listening… talk and I'll translate")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            if let status = model.status {
                Text(status).font(.system(size: 11)).foregroundStyle(Color.orange)
            }
            Text("Room audio is sent to \(model.providerHost) while this is on. Say \"stop translating\" or press Esc.")
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: RioTranslatorLayout.captionWidth - 28, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.07, green: 0.07, blue: 0.09).opacity(0.86))
        )
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.08)))
        .padding(14)
        .animation(.easeOut(duration: 0.2), value: model.board.lines.map(\.id))
    }
}

/// The subtitle card (click-through, never takes focus) and its tiny close button (the only part
/// that takes a click), both hidden from screen capture unless the bear is allowed in captures.
@MainActor final class RioTranslatorPanelController {
    private let model: RioTranslatorCaptionModel
    private let onClose: () -> Void
    private var captionPanel: NSPanel?
    private var closePanel: NSPanel?
    private var host: NSHostingView<RioTranslatorCaptionView>?
    private var observer: AnyCancellable?

    init(model: RioTranslatorCaptionModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    func show() {
        guard captionPanel == nil else { return }
        let host = NSHostingView(rootView: RioTranslatorCaptionView(model: model))
        let caption = Self.makePanel(contentView: host)
        caption.ignoresMouseEvents = true
        let close = Self.makePanel(contentView: NSHostingView(rootView: RioCloseButton(action: { [weak self] in self?.onClose() })))
        close.setContentSize(NSSize(width: 26, height: 26))
        self.host = host
        captionPanel = caption
        closePanel = close
        observer = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.layout() }
        }
        layout()
        caption.orderFrontRegardless()
        close.orderFrontRegardless()
    }

    func hide() {
        observer = nil
        for panel in [captionPanel, closePanel] {
            panel?.orderOut(nil)
            panel?.contentView = nil
            panel?.close()
        }
        captionPanel = nil
        closePanel = nil
        host = nil
    }

    private func layout() {
        guard let caption = captionPanel, let host, let screen = NSScreen.screens.first else { return }
        host.layoutSubtreeIfNeeded()
        let frame = RioTranslatorLayout.captionFrame(
            screenFrame: screen.frame, visibleFrame: screen.visibleFrame, height: host.fittingSize.height
        )
        caption.setFrame(frame, display: true)
        closePanel?.setFrameOrigin(NSPoint(x: frame.maxX - 40, y: frame.maxY - 40))
    }

    private static func makePanel(contentView: NSView) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: RioTranslatorLayout.captionWidth, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.sharingType = RioCompanionPrivacy.sharingType
        panel.contentView = contentView
        return panel
    }
}

private struct RioCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
        .help("Stop translating")
        .accessibilityLabel("Stop translating")
        .frame(width: 26, height: 26)
    }
}
