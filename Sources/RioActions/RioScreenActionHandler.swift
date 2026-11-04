import AppKit
import Foundation

/// Runs `.describeScreen`, `.click` and `.fillField` (builder J). Safety rules, all enforced here
/// or in the files it calls: never act in Rio's own windows (Rio is never the target app, and the
/// capture is one window by ID), never in System Settings privacy panes, password prompts or
/// permission alerts, never type into password, code or card fields, and a screenshot goes only
/// to the configured AI provider and only when the user asked a screen question.
@MainActor final class RioScreenActionHandler: RioActionHandling {
    static let shared = RioScreenActionHandler()

    private let vision: RioVisionClient
    private let overlay = RioClickChoiceOverlay.shared
    private var pending: PendingChoice?

    /// Matches Rio just numbered on screen, waiting for "the second one".
    private struct PendingChoice {
        let snapshot: RioClickSnapshot
        let choices: [RioClickElement]
        let toggle: RioToggleIntent?
        let fillText: String?
        let created: Date
    }

    private static let pendingLifetime: TimeInterval = 30

    init(vision: RioVisionClient = RioVisionClient(config: { RioScreenSettings.visionConfig() })) {
        self.vision = vision
    }

    func handle(_ action: RioAction, executor: RioActionExecuting) async -> RioActionResult? {
        switch action {
        case .describeScreen(let question):
            return await describe(question)
        case .click(let label, let ordinal):
            return await click(label: label, ordinal: ordinal)
        case .fillField(let label, let text):
            return await fill(label: label, text: text)
        default:
            return nil
        }
    }

    // MARK: Messages

    private enum Text {
        static let needsAccessibility = "I need Accessibility permission for that. You can allow it in System Settings, Privacy and Security."
        static let disabled = RioVisionMessages.disabled
        static let offline = RioVisionMessages.offline
        static let needsScreenRecording = RioVisionMessages.needsScreenRecording
        static let noWindow = RioVisionMessages.noWindow
        static let sensitive = RioVisionMessages.sensitive
        static let captureFailed = RioVisionMessages.captureFailed
        static let switchFirst = "Switch to the app you want me to click in first."
        static let blocked = "I don't click in System Settings privacy panes or password prompts. Please do that one yourself."
        static let sensitiveField = "I don't type passwords, codes or card numbers. Please do that one yourself."
        static let nothingPending = "I'm not sure what you mean. Say what to click, like click Send."
    }

    // MARK: Describe the screen

    private func describe(_ question: String?) async -> RioActionResult {
        overlay.hide()
        pending = nil
        guard RioScreenSettings.isEnabled else { return .failed(message: Text.disabled) }
        guard NetworkMonitor.shared.isOnline else { return .failed(message: Text.offline) }
        if let failure = RioVisionMessages.preflightFailure(config: RioScreenSettings.visionConfig()) {
            return .failed(message: failure)
        }
        let jpeg: Data
        do {
            jpeg = try RioScreenCapture.capture()
        } catch RioScreenCapture.Failure.noPermission {
            return .failed(message: Text.needsScreenRecording)
        } catch RioScreenCapture.Failure.noWindow {
            return .failed(message: Text.noWindow)
        } catch RioScreenCapture.Failure.sensitiveWindow {
            return .failed(message: Text.sensitive)
        } catch {
            return .failed(message: Text.captureFailed)
        }
        do {
            return .done(summary: try await vision.describe(jpeg: jpeg, question: question))
        } catch let error as RioVisionError {
            return .failed(message: RioVisionMessages.text(for: error))
        } catch {
            return .failed(message: RioVisionMessages.unreachable)
        }
    }

    // MARK: Target app

    private enum Prepared {
        case ready(RioClickSnapshot)
        case failed(RioActionResult)
    }

    private func prepare() async -> Prepared {
        guard RioAX.isTrusted else { return .failed(.failed(message: Text.needsAccessibility)) }
        guard let app = RioAX.frontmostApp(), app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return .failed(.failed(message: Text.switchFirst))
        }
        let bundleID = app.bundleIdentifier
        if RioClickSafety.isBlockedApp(bundleID: bundleID)
            || RioClickSafety.isBlockedWindow(bundleID: bundleID, title: RioClickAX.windowTitle(of: app)) {
            return .failed(.failed(message: Text.blocked))
        }
        guard let snapshot = await RioClickAX.snapshot(of: app), !snapshot.elements.isEmpty else {
            let name = app.localizedName ?? "this app"
            return .failed(.failed(message: "I couldn't see any buttons in \(name). Try again in a moment."))
        }
        if RioClickSafety.isBlockedWindow(bundleID: bundleID, title: snapshot.windowTitle) {
            return .failed(.failed(message: Text.blocked))
        }
        return .ready(snapshot)
    }

    // MARK: Click

    private func click(label: String, ordinal: Int?) async -> RioActionResult {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return await pickPending(ordinal) }
        overlay.hide()
        pending = nil
        let prepared = await prepare()
        guard case .ready(let snapshot) = prepared else {
            if case .failed(let result) = prepared { return result }
            return .failed(message: Text.switchFirst)
        }
        let resolution = RioClickMatcher.resolve(label: trimmed, ordinal: ordinal, in: snapshot.elements)
        switch resolution.outcome {
        case .none:
            return .failed(message: "I couldn't find \"\(Self.shortened(trimmed))\" on this screen.")
        case .ordinalOutOfRange(let available):
            return .failed(message: "I only see \(available) of those.")
        case .unique(let element):
            return perform(element, in: snapshot, toggle: resolution.toggle)
        case .ambiguous(let choices):
            return askWhich(choices, in: snapshot, toggle: resolution.toggle, fillText: nil)
        }
    }

    private func askWhich(
        _ choices: [RioClickElement], in snapshot: RioClickSnapshot, toggle: RioToggleIntent?, fillText: String?
    ) -> RioActionResult {
        pending = PendingChoice(snapshot: snapshot, choices: choices, toggle: toggle, fillText: fillText, created: Date())
        overlay.show(frames: choices.compactMap(\.frame))
        return .done(summary: "Which one? I numbered \(choices.count) of them on screen. Say the second one.")
    }

    private func pickPending(_ ordinal: Int?) async -> RioActionResult {
        guard let ordinal, let choice = pending,
              Date().timeIntervalSince(choice.created) < Self.pendingLifetime,
              RioAX.frontmostApp()?.processIdentifier == choice.snapshot.app.processIdentifier else {
            overlay.hide()
            pending = nil
            return .failed(message: Text.nothingPending)
        }
        let position = ordinal < 0 ? choice.choices.count + ordinal : ordinal - 1
        guard position >= 0, position < choice.choices.count else {
            return .failed(message: "I only numbered \(choice.choices.count). Say a number from one to \(choice.choices.count).")
        }
        // The badges are Rio's own windows: they go before anything is pressed.
        overlay.hide()
        pending = nil
        let element = choice.choices[position]
        if let text = choice.fillText {
            return await performFill(element, text: text, in: choice.snapshot)
        }
        return perform(element, in: choice.snapshot, toggle: choice.toggle)
    }

    private func perform(_ element: RioClickElement, in snapshot: RioClickSnapshot, toggle: RioToggleIntent?) -> RioActionResult {
        guard element.index < snapshot.handles.count else { return .failed(message: "That control went away.") }
        let handle = snapshot.handles[element.index]
        let name = Self.displayName(element)
        let isBox = element.kind == .checkbox || element.kind == .radio
        if isBox, let toggle {
            let current = RioClickAX.isChecked(handle) ?? element.isChecked
            if !RioClickMatcher.needsToggle(toggle, current: current) {
                return .done(summary: "\(name) is already \(toggle == .on ? "checked" : "unchecked")")
            }
        }
        let ok = element.kind == .textField
            ? RioClickAX.focus(element, handle: handle, app: snapshot.app)
            : RioClickAX.press(element, handle: handle, app: snapshot.app)
        guard ok else { return .failed(message: "I couldn't click \(name). This app may not let me press it.") }
        guard isBox else { return .done(summary: "Clicked \(name)") }
        switch toggle {
        case .on: return .done(summary: "Checked \(name)")
        case .off: return .done(summary: "Unchecked \(name)")
        case nil: return .done(summary: "Toggled \(name)")
        }
    }

    // MARK: Fill a field

    private func fill(label: String, text: String) async -> RioActionResult {
        overlay.hide()
        pending = nil
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !text.isEmpty, !text.contains("\n") else { return .failed(message: "I didn't catch what to type or where.") }
        if RioClickSafety.isSensitiveFieldLabel(trimmed) { return .failed(message: Text.sensitiveField) }
        let prepared = await prepare()
        guard case .ready(let snapshot) = prepared else {
            if case .failed(let result) = prepared { return result }
            return .failed(message: Text.switchFirst)
        }
        let fields = snapshot.elements.filter { $0.kind == .textField }
        let resolution = RioClickMatcher.resolve(label: trimmed, ordinal: nil, in: fields)
        switch resolution.outcome {
        case .none, .ordinalOutOfRange:
            return .failed(message: "I couldn't find a \"\(Self.shortened(trimmed))\" field on this screen.")
        case .unique(let field):
            return await performFill(field, text: text, in: snapshot)
        case .ambiguous(let choices):
            return askWhich(choices, in: snapshot, toggle: nil, fillText: text)
        }
    }

    private func performFill(_ field: RioClickElement, text: String, in snapshot: RioClickSnapshot) async -> RioActionResult {
        guard field.index < snapshot.handles.count else { return .failed(message: "That field went away.") }
        if field.texts.contains(where: RioClickSafety.isSensitiveFieldLabel) { return .failed(message: Text.sensitiveField) }
        let handle = snapshot.handles[field.index]
        guard RioClickAX.focus(field, handle: handle, app: snapshot.app) else {
            return .failed(message: "I couldn't click into that field.")
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
        RioClickAX.selectAll(in: handle)
        guard await RioAX.paste(text, into: snapshot.app) else {
            return .failed(message: "I couldn't type there. Switch back to the app and try again.")
        }
        return .done(summary: "Filled in \(Self.displayName(field))")
    }

    // MARK: Names

    private static func displayName(_ element: RioClickElement) -> String {
        guard let first = element.texts.first(where: { !$0.isEmpty }) else { return "that" }
        return shortened(first)
    }

    private static func shortened(_ text: String) -> String {
        let flat = RioText.collapseWhitespace(text)
        return flat.count > 40 ? String(flat.prefix(40)) + "…" : flat
    }
}
