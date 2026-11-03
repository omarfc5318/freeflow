import AppKit
import Contacts
import Foundation

/// Looks up an email address in Contacts for one command. In memory only; nothing is logged,
/// stored or sent anywhere.
@MainActor
enum RioEmailContacts {
    /// nil when Contacts access isn't granted.
    static func choose(spoken: String) async -> RioContactChoice? {
        if RioRecipient.directHandle(from: spoken) != nil, spoken.contains("@") {
            return RioMailRecipient.resolve(spoken: spoken, candidates: [])
        }
        guard await RioContactsLookup.requestAccess() else { return nil }
        return RioMailRecipient.resolve(spoken: spoken, candidates: candidates(matching: RioMailRecipient.withoutTitle(spoken)))
    }

    private static func candidates(matching name: String) -> [RioContactCandidate] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
            CNContactEmailAddressesKey,
        ].map { $0 as CNKeyDescriptor }
        var contacts = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys)) ?? []
        if contacts.isEmpty {
            try? store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in contacts.append(contact) }
        }
        return contacts.compactMap { contact in
            let person = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            let fullName = person.isEmpty ? (contact.organizationName.isEmpty ? contact.nickname : contact.organizationName) : person
            guard !fullName.isEmpty else { return nil }
            return RioContactCandidate(
                fullName: fullName, givenName: contact.givenName, familyName: contact.familyName, nickname: contact.nickname,
                phones: [], emails: contact.emailAddresses.map { $0.value as String }
            )
        }
    }
}

/// Opens a compose window with the email already written. It never sends: Apple Mail gets a
/// fixed script that only makes an outgoing message and shows it, other apps get a compose URL.
@MainActor
enum RioEmailDrafter {
    static func draft(to spoken: String?, subject: String?, body: String) async -> RioActionResult {
        var address: String?
        var recipientName: String?
        var note = ""
        if let spoken, !spoken.isEmpty {
            if let choice = await RioEmailContacts.choose(spoken: spoken) {
                switch choice {
                case .match(let name, let handle):
                    address = handle
                    recipientName = name
                case .ambiguous(let names):
                    note = " I found more than one \(spoken) (\(names.prefix(3).joined(separator: ", "))), so I left the To line empty."
                case .noHandle(let name):
                    note = " \(name) has no email address in Contacts, so I left the To line empty."
                case .notFound:
                    note = " I couldn't find \(spoken) in your Contacts, so I left the To line empty."
                }
            } else {
                note = " I need permission to read your Contacts to fill in the To line."
            }
        }
        let opened = open(to: address, subject: subject, body: body)
        if case .failed = opened { return opened }
        let who = recipientName.map { " to \($0)" } ?? ""
        return .done(summary: "Opened an email draft\(who). It's ready for you to read and send." + note)
    }

    private static func open(to address: String?, subject: String?, body: String) -> RioActionResult {
        let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "mailto:")!).flatMap { Bundle(url: $0)?.bundleIdentifier }
        switch RioMailRouter.route(defaultHandlerBundleID: handler) {
        case .appleMail:
            switch RioScriptRunner.run(RioMailScripts.draft(to: address, subject: subject, body: body)) {
            case nil: return .done(summary: "")
            case RioScriptRunner.automationDenied?:
                return .failed(message: "I'm not allowed to control Mail. You can allow it in System Settings, Privacy and Security, Automation.")
            default: return openURL(RioEmailLinks.mailto(to: address, subject: subject, body: body))
            }
        case .gmailWeb:
            return openURL(RioEmailLinks.gmailCompose(to: address, subject: subject, body: body)
                ?? RioEmailLinks.mailto(to: address, subject: subject, body: body))
        case .mailtoDefault:
            return openURL(RioEmailLinks.mailto(to: address, subject: subject, body: body))
        }
    }

    private static func openURL(_ url: URL?) -> RioActionResult {
        guard let url else { return .failed(message: "That email is too long to open as a draft. Try a shorter one.") }
        return NSWorkspace.shared.open(url) ? .done(summary: "") : .failed(message: "I couldn't open your mail app.")
    }
}
