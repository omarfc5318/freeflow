import Foundation

/// What the confirmation panel says for an action that needs the user's yes. Pure.
struct RioConfirmationContent: Equatable {
    /// The panel never auto-confirms; after this long it counts as Cancel.
    static let timeoutSeconds: TimeInterval = 20

    let title: String
    /// The exact text that will be sent, shown whole.
    let detail: String
    let confirmLabel: String

    /// `appName` is the frontmost messaging app (for replies); `resolvedRecipient` is the
    /// contact's full name when it is already known.
    static func make(for action: RioAction, appName: String?, resolvedRecipient: String?) -> RioConfirmationContent? {
        switch action {
        case .sendMessage(let to, let body):
            return RioConfirmationContent(
                title: "Send a message to \(resolvedRecipient ?? to)?", detail: body, confirmLabel: "Send"
            )
        case .replyInConversation(let body):
            let title = appName.map { "Reply in \($0)?" } ?? "Reply in this conversation?"
            return RioConfirmationContent(title: title, detail: body, confirmLabel: "Send")
        case .emptyTrash:
            return RioConfirmationContent(title: "Empty the Trash?", detail: "This can't be undone.", confirmLabel: "Empty Trash")
        default:
            return nil
        }
    }
}
