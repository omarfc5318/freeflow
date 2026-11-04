import Foundation

/// What the confirmation panel says for an action that needs the user's yes. Pure.
struct RioConfirmationContent: Equatable {
    /// The panel never auto-confirms; after this long it counts as Cancel.
    static let timeoutSeconds: TimeInterval = 20

    let title: String
    /// The exact text that will be sent, shown whole.
    let detail: String
    let confirmLabel: String

    /// Longest conversation or window title shown in the question.
    static let maxTitleLength = 60

    /// "Sam", "Sam — Messages": a window title trimmed to something that fits on one line.
    static func shortTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let text = RioText.collapseWhitespace(raw)
        guard !text.isEmpty else { return nil }
        guard text.count > maxTitleLength else { return text }
        return String(text.prefix(maxTitleLength - 1)) + "\u{2026}"
    }

    /// `appName` is the frontmost messaging app (for replies); `resolvedRecipient` is the
    /// contact's full name when it is already known; `conversationTitle` is the front window's
    /// title, which names who or what a reply goes to.
    static func make(
        for action: RioAction, appName: String?, resolvedRecipient: String?, conversationTitle: String? = nil
    ) -> RioConfirmationContent? {
        switch action {
        case .sendMessage(let to, let body):
            return RioConfirmationContent(
                title: "Send a message to \(resolvedRecipient ?? to)?", detail: body, confirmLabel: "Send"
            )
        case .replyInConversation(let body):
            let title: String
            // The window title is shown only inside a recognised messaging app, and labelled as the
            // window's name: it isn't a verified recipient (any app or page can set its title).
            switch (shortTitle(conversationTitle), appName) {
            case (let name?, let app?) where name.lowercased() != app.lowercased(): title = "Reply in \(app) (window “\(name)”)?"
            case (_, let app?): title = "Reply in \(app)?"
            default: title = "Reply in this conversation?"
            }
            return RioConfirmationContent(title: title, detail: body, confirmLabel: "Send")
        case .emptyTrash:
            return RioConfirmationContent(title: "Empty the Trash?", detail: "This can't be undone.", confirmLabel: "Empty Trash")
        default:
            return nil
        }
    }
}
