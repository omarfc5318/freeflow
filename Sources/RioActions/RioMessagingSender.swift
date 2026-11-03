import AppKit
import Contacts
import Foundation

/// Looks people up in Contacts. The lookup happens on this Mac, in memory, for one command;
/// contact details are never logged, stored or sent anywhere.
@MainActor
enum RioContactsLookup {
    static var isAuthorized: Bool {
        CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    static func requestAccess() async -> Bool {
        if isAuthorized { return true }
        guard CNContactStore.authorizationStatus(for: .contacts) == .notDetermined else { return false }
        return await withCheckedContinuation { continuation in
            CNContactStore().requestAccess(for: .contacts) { granted, _ in continuation.resume(returning: granted) }
        }
    }

    /// nil when Contacts access isn't granted.
    static func choose(spoken: String) async -> RioContactChoice? {
        guard await requestAccess() else { return nil }
        return RioContactChooser.choose(spoken: spoken, from: candidates(matching: spoken))
    }

    /// Only call when `isAuthorized`, so it never prompts. Used to show the full name in the
    /// confirmation panel.
    static func resolvedName(spoken: String) -> String? {
        guard isAuthorized, RioRecipient.directHandle(from: spoken) == nil else { return nil }
        if case .match(let name, _) = RioContactChooser.choose(spoken: spoken, from: candidates(matching: spoken)) { return name }
        return nil
    }

    private static func candidates(matching spoken: String) -> [RioContactCandidate] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
            CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
        ].map { $0 as CNKeyDescriptor }
        var contacts = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: spoken), keysToFetch: keys)) ?? []
        if contacts.isEmpty {
            // Nicknames like "Mom" aren't always matched by name; look through everyone.
            try? store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in contacts.append(contact) }
        }
        return contacts.compactMap { contact in
            let person = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            let fullName = person.isEmpty ? (contact.organizationName.isEmpty ? contact.nickname : contact.organizationName) : person
            guard !fullName.isEmpty else { return nil }
            return RioContactCandidate(
                fullName: fullName, givenName: contact.givenName, familyName: contact.familyName, nickname: contact.nickname,
                phones: contact.phoneNumbers.map { RioContactPhone(label: $0.label, number: $0.value.stringValue) },
                emails: contact.emailAddresses.map { $0.value as String }
            )
        }
    }
}

/// Sends a message through Messages. The recipient and text go in as AppleScript parameters
/// (`RioMessagingScripts`), never as part of the script source. The caller has already got the
/// user's confirmation.
@MainActor
enum RioMessageSender {
    static func send(to spoken: String, body: String) async -> RioActionResult {
        let name: String
        let handle: String
        if let direct = RioRecipient.directHandle(from: spoken) {
            name = spoken
            handle = direct
        } else {
            guard let choice = await RioContactsLookup.choose(spoken: spoken) else {
                return .failed(message: "I need permission to read your Contacts. You can allow it in System Settings, Privacy and Security.")
            }
            switch choice {
            case .match(let matched, let found):
                name = matched
                handle = found
            case .ambiguous(let names):
                return .failed(message: "I found more than one \(spoken): \(names.prefix(3).joined(separator: ", ")). Say the full name.")
            case .noHandle(let matched):
                return .failed(message: "\(matched) has no phone number or email in Contacts.")
            case .notFound:
                return .failed(message: "I couldn't find \(spoken) in your Contacts.")
            }
        }
        let first = run(RioMessagingScripts.sendIMessage(handle: handle, body: body))
        if first == nil { return .done(summary: "Sent your message to \(name)") }
        if first != automationDenied, run(RioMessagingScripts.sendSMS(handle: handle, body: body)) == nil {
            return .done(summary: "Sent your message to \(name)")
        }
        if first == automationDenied {
            return .failed(message: "I'm not allowed to control Messages. You can allow it in System Settings, Privacy and Security, Automation.")
        }
        return .failed(message: "I couldn't send that message to \(name).")
    }

    private static let automationDenied = -1743

    /// nil on success, otherwise the AppleScript error number.
    private static func run(_ call: RioScriptCall) -> Int? {
        guard let script = NSAppleScript(source: call.source) else { return -1 }
        var error: NSDictionary?
        _ = script.compileAndReturnError(&error)
        if let error { return error[NSAppleScript.errorNumber] as? Int ?? -1 }
        let event = RioMessagingScripts.appleEvent(for: call, target: NSAppleEventDescriptor.currentProcess())
        _ = script.executeAppleEvent(event, error: &error)
        guard let error else { return nil }
        return error[NSAppleScript.errorNumber] as? Int ?? -1
    }
}
