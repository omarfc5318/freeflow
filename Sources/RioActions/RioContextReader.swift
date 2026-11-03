import AppKit
import ApplicationServices

/// Reads things from the front app for "read it to me" commands, and replies into the open
/// conversation. Best effort per app: every failure turns into a plain sentence for Rio to say.
@MainActor
enum RioContextReader {
    static let needsAccessibility = "I need Accessibility permission for that. You can allow it in System Settings, Privacy and Security."
    static let readLimit = 1_500

    // MARK: Selection

    static func readSelection() async -> RioActionResult {
        guard RioAX.isTrusted else { return .failed(message: needsAccessibility) }
        guard let app = RioAX.frontmostApp(), let text = await RioAX.selectedText(in: app) else {
            return .failed(message: "I don't see any selected text. Select something first.")
        }
        return .done(summary: RioReadingText.condense([text], limit: readLimit))
    }

    // MARK: Last message

    static func readLastMessage() -> RioActionResult {
        guard RioAX.isTrusted else { return .failed(message: needsAccessibility) }
        guard let app = RioAX.frontmostApp() else { return .failed(message: "Open a conversation first.") }
        guard let info = RioMessagingApps.info(for: app.bundleIdentifier) else {
            return .failed(message: "Open a conversation in Messages, WhatsApp, Slack, Discord or Telegram first.")
        }
        guard info.canReadMessages else { return .failed(message: "I can't read messages in \(info.name) yet.") }
        var candidates: [RioMessageCandidate] = []
        let focused = RioAX.focusedElement(of: app)
        if let window = RioAX.element(RioAX.appElement(app), kAXFocusedWindowAttribute as String) {
            var budget = TraversalBudget(maxNodes: 3_000, deadline: Date().addingTimeInterval(1.2))
            collectMessages(window, inheritedDescription: nil, skip: focused, budget: &budget, into: &candidates)
        }
        guard let message = RioMessagePicker.lastIncoming(from: candidates) else {
            return .failed(message: "I couldn't find the last message in \(info.name). This works best in Messages.")
        }
        return .done(summary: RioReadingText.condense([message], limit: readLimit))
    }

    private struct TraversalBudget {
        var remaining: Int
        let deadline: Date
        init(maxNodes: Int, deadline: Date) {
            remaining = maxNodes
            self.deadline = deadline
        }
        mutating func spend() -> Bool {
            remaining -= 1
            return remaining > 0 && Date() < deadline
        }
    }

    private static func collectMessages(
        _ element: AXUIElement, inheritedDescription: String?, skip: AXUIElement?,
        budget: inout TraversalBudget, into candidates: inout [RioMessageCandidate]
    ) {
        guard budget.spend() else { return }
        if let skip, CFEqual(element, skip) { return }
        let description = RioAX.string(element, kAXDescriptionAttribute as String) ?? inheritedDescription
        let role = RioAX.role(element)
        if role == kAXStaticTextRole as String,
           let text = RioAX.string(element, kAXValueAttribute as String) ?? RioAX.string(element, kAXDescriptionAttribute as String) {
            candidates.append(RioMessageCandidate(text: text, description: description))
        }
        for child in RioAX.children(element) {
            collectMessages(child, inheritedDescription: description, skip: skip, budget: &budget, into: &candidates)
        }
    }

    // MARK: Page

    private static let chromiumBundlePrefixes = [
        "com.google.chrome", "com.brave.browser", "com.microsoft.edgemac", "company.thebrowser", "com.vivaldi", "com.operasoftware",
    ]
    private static let browserBundleIDs: Set<String> = ["com.apple.safari", "com.apple.safaritechnologypreview", "org.mozilla.firefox"]

    static func readPage() async -> RioActionResult {
        guard RioAX.isTrusted else { return .failed(message: needsAccessibility) }
        guard let app = RioAX.frontmostApp(), let bundle = app.bundleIdentifier?.lowercased() else {
            return .failed(message: "Open a page in your browser first.")
        }
        let isChromium = chromiumBundlePrefixes.contains { bundle.hasPrefix($0) }
        guard isChromium || browserBundleIDs.contains(bundle) else {
            return .failed(message: "I can read pages in Safari, Chrome, Firefox, Brave, Edge and Arc. Switch to one of those first.")
        }
        var text = pageText(in: app)
        if text.isEmpty, isChromium {
            // Chromium builds its accessibility tree only when asked.
            AXUIElementSetAttributeValue(RioAX.appElement(app), "AXManualAccessibility" as CFString, kCFBooleanTrue)
            try? await Task.sleep(nanoseconds: 400_000_000)
            text = pageText(in: app)
        }
        guard !text.isEmpty else { return .failed(message: "I couldn't read this page. Try selecting the text and asking me to read the selection.") }
        return .done(summary: text)
    }

    private static func pageText(in app: NSRunningApplication) -> String {
        guard let window = RioAX.element(RioAX.appElement(app), kAXFocusedWindowAttribute as String) else { return "" }
        var budget = TraversalBudget(maxNodes: 4_000, deadline: Date().addingTimeInterval(1.5))
        guard let web = findWebArea(window, budget: &budget) else { return "" }
        var fragments: [String] = []
        var textBudget = TraversalBudget(maxNodes: 4_000, deadline: Date().addingTimeInterval(1.5))
        collectText(web, characters: 0, budget: &textBudget, into: &fragments)
        return RioReadingText.condense(fragments, limit: readLimit)
    }

    private static func findWebArea(_ element: AXUIElement, budget: inout TraversalBudget) -> AXUIElement? {
        guard budget.spend() else { return nil }
        if RioAX.role(element) == "AXWebArea" { return element }
        for child in RioAX.children(element) {
            if let found = findWebArea(child, budget: &budget) { return found }
        }
        return nil
    }

    @discardableResult
    private static func collectText(
        _ element: AXUIElement, characters: Int, budget: inout TraversalBudget, into fragments: inout [String]
    ) -> Int {
        guard characters < readLimit * 2, budget.spend() else { return characters }
        var count = characters
        if RioAX.role(element) == kAXStaticTextRole as String, let text = RioAX.string(element, kAXValueAttribute as String) {
            fragments.append(text)
            count += text.count
        }
        for child in RioAX.children(element) {
            count = collectText(child, characters: count, budget: &budget, into: &fragments)
        }
        return count
    }

    // MARK: Reply

    private static let textRoles: Set<String> = [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String]

    /// Types `body` into the focused compose field of the frontmost messaging app and sends it.
    /// Refuses if the focused element isn't a text field. The confirmation already happened.
    static func reply(_ body: String) async -> RioActionResult {
        guard RioAX.isTrusted else { return .failed(message: needsAccessibility) }
        guard let app = RioAX.frontmostApp(), let info = RioMessagingApps.info(for: app.bundleIdentifier) else {
            return .failed(message: "I can reply in Messages, WhatsApp, Slack, Discord, Telegram or Mail. Open a conversation there first.")
        }
        guard let field = RioAX.focusedElement(of: app), isEditable(field) else {
            return .failed(message: "I don't see a message box to type in. Click the message field first.")
        }
        guard await RioAX.paste(body, into: app) else { return .failed(message: "I lost track of the conversation, so I didn't send anything.") }
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            return .failed(message: "I lost track of the conversation, so I didn't press send.")
        }
        RioAX.pressSend(info.sendKey, in: app)
        return .done(summary: "Replied in \(info.name)")
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        if let role = RioAX.role(element), textRoles.contains(role) { return true }
        // Editable web content (Slack, Mail, WhatsApp on some builds) reports itself as editable.
        if let editable = RioAX.value(element, "AXEditable") as? Bool { return editable }
        return false
    }
}
