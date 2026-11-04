import AppKit
import Contacts
import Foundation
import SQLite3

/// Where "find that thing" looks, besides Spotlight. Everything is read-only and in memory: file
/// names and message dates are turned into `RioFindResult`s for one command and dropped. Message
/// text is never read, and nothing is logged or stored.
enum RioFindSources {
    enum MessagesAccess: Equatable {
        case granted
        /// Messages exists but macOS blocks the folder: Full Disk Access is off.
        case needsFullDiskAccess
        case absent
    }

    static var home: String { NSHomeDirectory() }

    private static var messagesDirectory: String { home + "/" + RioFindRanker.messagesAttachmentsSubpath }
    private static var messagesDatabase: String { home + "/Library/Messages/chat.db" }
    private static var mailDirectory: String { home + "/" + RioFindRanker.mailDownloadsSubpath }

    // MARK: Full Disk Access

    static func messagesAccess() -> MessagesAccess {
        guard let handle = opendir(messagesDirectory) else {
            return errno == EPERM || errno == EACCES ? .needsFullDiskAccess : .absent
        }
        closedir(handle)
        return .granted
    }

    // MARK: Messages attachments

    /// Attachments sent or received since `since`, with who they came from. Runs on a background queue.
    static func messageAttachments(since: Date) async -> [RioFindResult] {
        let home = home
        let path = messagesDatabase
        return await Task.detached(priority: .userInitiated) { readMessages(databasePath: path, since: since, home: home) }.value
    }

    private static func readMessages(databasePath: String, since: Date, home: String) -> [RioFindResult] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            sqlite3_close(database)
            return []
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, RioMessagesAttachments.sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, RioMessagesAttachments.storedDate(for: since))

        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
        var results: [RioFindResult] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let row = RioMessagesAttachments.Row(
                filename: text(0), date: sqlite3_column_int64(statement, 1),
                isFromMe: sqlite3_column_int(statement, 2) != 0, handle: text(3)
            )
            if let result = RioMessagesAttachments.result(from: row, home: home),
               FileManager.default.fileExists(atPath: result.path) {
                results.append(result)
            }
        }
        return results
    }

    // MARK: Downloads and Mail downloads

    /// Files in Downloads and Mail's download folder changed since `since` (two folders deep).
    static func downloadFolders(since: Date) async -> [RioFindResult] {
        let roots: [(String, RioFindSource)] = [(home + "/Downloads", .downloads), (mailDirectory, .mail)]
        return await Task.detached(priority: .userInitiated) {
            roots.flatMap { scan(root: $0.0, source: $0.1, since: since) }
        }.value
    }

    private static func scan(root: String, source: RioFindSource, since: Date) -> [RioFindResult] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root, isDirectory: true), includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var results: [RioFindResult] = []
        for case let url as URL in enumerator {
            if enumerator.level > 3 { enumerator.skipDescendants(); continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified >= since else { continue }
            results.append(RioFindResult(path: url.path, date: modified, sender: nil, sources: [source]))
            if results.count >= 500 { break }
        }
        return results
    }

    // MARK: Spotlight

    @MainActor static func spotlight(for query: RioFindQuery) async -> [RioFindResult] {
        var parts: [NSPredicate] = []
        let extensions = query.allowedExtensions.sorted()
        if !extensions.isEmpty {
            parts.append(NSCompoundPredicate(orPredicateWithSubpredicates: extensions.map {
                NSPredicate(format: "kMDItemFSName ENDSWITH[cd] %@", "." + $0)
            }))
        }
        if let interval = query.interval {
            parts.append(NSPredicate(
                format: "kMDItemFSContentChangeDate >= %@ AND kMDItemFSContentChangeDate <= %@",
                interval.start as NSDate, interval.end as NSDate
            ))
        }
        // A person alone can only be found by name (Spotlight doesn't know who sent a file).
        if parts.isEmpty, let person = query.person {
            let words = person.split(separator: " ").map(String.init).filter { $0.count >= 2 }
            guard !words.isEmpty else { return [] }
            parts.append(NSCompoundPredicate(andPredicateWithSubpredicates: words.map { NSPredicate(format: "kMDItemFSName CONTAINS[cd] %@", $0) }))
        }
        guard !parts.isEmpty else { return [] }
        let found = await RioFileSearch.shared.search(NSCompoundPredicate(andPredicateWithSubpredicates: parts))
        return found.filter { !$0.isDirectory }.map {
            RioFindResult(path: $0.path, date: $0.modified ?? $0.lastUsed, sender: nil, sources: [.spotlight])
        }
    }

    // MARK: Contacts

    /// Every phone number and email Contacts has for people matching `spoken`, or nil when
    /// Contacts access isn't granted (this never prompts). Used in memory for one command.
    @MainActor static func handles(for spoken: String) async -> [String]? {
        guard await RioContactsLookup.requestAccess() else { return nil }
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
        ].map { $0 as CNKeyDescriptor }
        var contacts = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: spoken), keysToFetch: keys)) ?? []
        if contacts.isEmpty {
            // Nicknames like "Mom" aren't matched by name: look for them in everyone.
            let wanted = spoken.lowercased()
            try? store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
                if contact.nickname.lowercased() == wanted { contacts.append(contact) }
            }
        }
        return contacts.flatMap { contact in
            contact.phoneNumbers.map { $0.value.stringValue } + contact.emailAddresses.map { $0.value as String }
        }
    }
}
