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
            // Always names the channel: right after "open WhatsApp" the owner must not think it
            // goes over WhatsApp (finding 50).
            return RioConfirmationContent(
                title: "Send an iMessage to \(resolvedRecipient ?? to)?", detail: body, confirmLabel: "Send"
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

    // MARK: Conversation mode

    /// The question for an action conversation mode heard while "Trust conversation mode" is off
    /// (or one it always confirms). It shows exactly what will happen, never a generic line: the
    /// owner can only approve what the panel shows (security review).
    static func conversation(for action: RioAction) -> RioConfirmationContent {
        RioConfirmationContent(
            title: "Run this from conversation mode?", detail: conversationDetail(for: action), confirmLabel: "Run it"
        )
    }

    /// Typing and the Return that submits it, shown together so the owner sees that it will be
    /// sent or run: "Type “git push”, then press Return in Terminal". `alreadyTyped` is a Return
    /// for text an earlier command typed: "Press Return to submit “git push” in Terminal".
    static func conversationSubmit(_ steps: [RioAction], alreadyTyped: Bool, appName: String?) -> RioConfirmationContent {
        let place = appName.map { " in \($0)" } ?? ""
        let detail: String
        if alreadyTyped {
            let typed = steps.compactMap { step -> String? in
                if case .typeText(let text) = step { return text }
                return nil
            }.last
            detail = typed.map { "Press Return to submit \u{201C}\($0)\u{201D}\(place)" } ?? "Press Return\(place)"
        } else {
            let parts = steps.map { step -> String in
                switch step {
                case .typeText(let text): return "type \u{201C}\(text)\u{201D}"
                case .pressKeys(let combo): return "press \(keyName(combo))"
                default: return RioActionText.working(for: step).lowercased()
                }
            }
            let joined = parts.count > 1
                ? parts.dropLast().joined(separator: ", ") + ", then " + (parts.last ?? "")
                : parts.joined()
            detail = joined.prefix(1).uppercased() + joined.dropFirst() + place
        }
        return RioConfirmationContent(title: "Run this from conversation mode?", detail: detail, confirmLabel: "Run it")
    }

    private static func keyName(_ combo: KeyCombo) -> String {
        let spoken = RioKeyCombos.describe(combo)
        return combo.key == "return" && spoken == "return" ? "Return" : spoken
    }

    static func conversationDetail(for action: RioAction) -> String {
        switch action {
        case .typeText(let text): return text
        case .fillField(let label, let text): return "\(label): \(text)"
        case .click(let label, _): return "Click \(label)"
        case .runTask(let goal): return goal
        case .pressKeys(let combo): return "Press \(RioKeyCombos.describe(combo))"
        case .quitApp(let name): return "Quit \(name)"
        case .systemToggle(let setting, let isOn): return "Turn \(settingName(setting)) \(isOn ? "on" : "off")"
        case .clipboard(.pasteRecent(let hint)):
            if let hint = hint?.trimmingCharacters(in: .whitespaces), !hint.isEmpty {
                return "Paste the recent clipboard item matching \u{201C}\(hint)\u{201D}"
            }
            return "Paste the most recent clipboard item"
        case .startTranslation:
            return "Your microphone's sound will be sent to your transcription provider until you stop it."
        case .claudeCode(.send(let text)): return "Send to Claude Code: \(text)"
        case .scheduleCommand(let command, let when): return "Schedule \"\(command)\" \(when)"
        case .addTrigger(let command, let trigger): return "\(trigger), \(command)"
        case .runMacro(let name): return "Run the macro \"\(name)\""
        case .recordMacro(let name): return "Start recording a macro called \"\(name)\""
        case .removeAutomation(let name): return "Remove \"\(name)\""
        // Waves 4–5 writing and recording.
        case .writeForMe(let instruction): return "Write and type into the focused field: \(instruction)"
        case .smartPaste(let instruction):
            return "Send your clipboard to your AI provider, then paste the result: \(instruction)"
        case .editLastDictation(let instruction): return "Rewrite your last dictation in place: \(instruction)"
        case .selectionTask(.improve): return "Rewrite the selected text in place"
        case .notionAdd(let text, let page):
            return page.map { "Add to Notion (\($0)): \(text)" } ?? "Add to Notion: \(text)"
        case .meeting(.start): return "Start keeping the last few minutes of call audio (microphone and system sound)"
        default: return RioActionText.working(for: action)
        }
    }

    private static func settingName(_ setting: SystemSetting) -> String {
        switch setting {
        case .wifi: return "Wi-Fi"
        case .bluetooth: return "Bluetooth"
        case .darkMode: return "dark mode"
        case .nightShift: return "Night Shift"
        }
    }
}
