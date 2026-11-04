import Foundation
import SQLite3

/// Text Rio from the iPhone: handle matching, attributedBody decoding, row filtering over a
/// synthetic chat.db built in a temp dir. The real chat.db is never opened.
enum RioPhoneTests {
    static func run() {
        handles()
        decoding()
        commandText()
        replies()
        access()
        filterOverRows()
        syntheticDatabase()
    }

    private static func handles() {
        TestSupport.expectEqual(RioPhoneHandle.normalize("+1 (555) 010-0100"), "+15550100100")
        TestSupport.expectEqual(RioPhoneHandle.normalize("(555) 010-0100"), "5550100100")
        TestSupport.expectEqual(RioPhoneHandle.normalize(" Me@Example.COM "), "me@example.com")
        TestSupport.expect(RioPhoneHandle.matches("+15550100100", "+1 555 010 0100"), "formatting does not matter")
        TestSupport.expect(RioPhoneHandle.matches("5550100100", "+15550100100"), "a missing country code still matches")
        TestSupport.expect(!RioPhoneHandle.matches("+15550100100", "+15550100101"), "different numbers differ")
        TestSupport.expect(RioPhoneHandle.matches("me@example.com", "ME@example.com"), "emails ignore case")
        TestSupport.expect(!RioPhoneHandle.matches("", ""), "empty handles never match")
        TestSupport.expect(!RioPhoneHandle.matches("chat123456", "123456"), "a group chat id is not a number")
        TestSupport.expectEqual(RioPhoneHandle.parseList("+1 555 010 0100, me@example.com ;  "), ["+1 555 010 0100", "me@example.com"])
        TestSupport.expectEqual(RioPhoneHandle.parseList(" "), [])
    }

    /// The typedstream layout Messages uses for `attributedBody`: class names, then "+", a length, the text.
    static func blob(_ text: String) -> Data {
        var bytes: [UInt8] = [0x04, 0x0B] + Array("streamtyped".utf8) + [0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84]
        bytes += Array("NSAttributedString".utf8) + [0x00, 0x84, 0x84, 0x08] + Array("NSObject".utf8) + [0x00, 0x85, 0x92, 0x84, 0x84, 0x84]
        bytes += Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B]
        let payload = Array(text.utf8)
        if payload.count < 0x80 {
            bytes.append(UInt8(payload.count))
        } else {
            bytes += [0x81, UInt8(payload.count & 0xFF), UInt8(payload.count >> 8)]
        }
        bytes += payload + [0x86, 0x84, 0x02] + Array("NSDictionary".utf8) + [0x00]
        return Data(bytes)
    }

    private static func decoding() {
        TestSupport.expectEqual(RioPhoneText.decode(text: "Rio open Chrome", attributedBody: nil), "Rio open Chrome")
        TestSupport.expectEqual(RioPhoneText.decode(text: nil, attributedBody: blob("Rio what's the weather")), "Rio what's the weather")
        TestSupport.expectEqual(RioPhoneText.decode(text: "", attributedBody: blob("Rio hi")), "Rio hi")
        let long = "Rio " + String(repeating: "x", count: 300)
        TestSupport.expectEqual(RioPhoneText.decode(text: nil, attributedBody: blob(long)), long)
        TestSupport.expectEqual(RioPhoneText.decode(text: nil, attributedBody: blob("Rio \u{627}\u{641}\u{62A}\u{62D} \u{643}\u{631}\u{648}\u{645}")), "Rio \u{627}\u{641}\u{62A}\u{62D} \u{643}\u{631}\u{648}\u{645}")
        TestSupport.expect(RioPhoneText.decode(text: nil, attributedBody: Data([1, 2, 3])) == nil, "garbage decodes to nothing")
        TestSupport.expect(RioPhoneText.decode(text: nil, attributedBody: nil) == nil, "no body, no text")
        var truncated = blob("Rio hello there")
        truncated.removeLast(40)
        TestSupport.expect(RioPhoneText.decode(text: nil, attributedBody: truncated) == nil, "a cut-off blob is not guessed at")
    }

    private static func commandText() {
        TestSupport.expectEqual(RioPhoneText.commandText("Rio open Chrome"), "Rio open Chrome")
        TestSupport.expectEqual(RioPhoneText.commandText("  rio, set a timer for 5 minutes "), "rio, set a timer for 5 minutes")
        TestSupport.expectEqual(RioPhoneText.commandText("RIO: what's due on Canvas"), "RIO: what's due on Canvas")
        TestSupport.expectEqual(RioPhoneText.commandText("Rio"), nil)
        TestSupport.expectEqual(RioPhoneText.commandText("Riot control"), nil)
        TestSupport.expectEqual(RioPhoneText.commandText("Rios pizza"), nil)
        TestSupport.expectEqual(RioPhoneText.commandText("hello Rio open Chrome"), nil)
        TestSupport.expectEqual(RioPhoneText.commandText("\(RioPhoneText.replyMarker) Opened Chrome"), nil)
        TestSupport.expectEqual(RioPhoneText.commandText("Rio \(String(repeating: "a", count: 600))"), nil)
    }

    private static func replies() {
        TestSupport.expectEqual(RioPhoneReply.text("Opened Chrome", succeeded: true), "\(RioPhoneText.replyMarker) Opened Chrome")
        TestSupport.expectEqual(RioPhoneReply.text("I couldn't find that", succeeded: false), "\(RioPhoneText.replyMarker) I couldn't find that")
        TestSupport.expect(RioPhoneReply.text(String(repeating: "x", count: 900), succeeded: true).count <= 500, "replies are short")
        TestSupport.expect(RioPhoneText.commandText(RioPhoneReply.text("Rio is great", succeeded: true)) == nil, "a reply is never read back as a command")
        TestSupport.expectEqual(RioPhoneReply.text("  ", succeeded: true), "\(RioPhoneText.replyMarker) Done")
    }

    private static func access() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rio-phone-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("chat.db")
        TestSupport.expectEqual(RioPhoneAccess.check(path: file.path), .missing)
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
        TestSupport.expectEqual(RioPhoneAccess.check(path: file.path), .ok)
        let locked = dir.appendingPathComponent("locked.db")
        FileManager.default.createFile(atPath: locked.path, contents: Data("x".utf8), attributes: [.posixPermissions: 0o000])
        if getuid() != 0 { TestSupport.expectEqual(RioPhoneAccess.check(path: locked.path), .denied) }
        TestSupport.expect(!RioPhoneAccess.setupSteps.isEmpty, "Full Disk Access steps are shown")
    }

    // MARK: Filtering

    private static let owner = ["+1 (555) 010-0100", "me@example.com"]

    private static func row(
        _ id: Int64, _ text: String?, mine: Bool = true, chat: String? = "+15550100100", people: Int = 1, body: Data? = nil
    ) -> RioChatRow {
        RioChatRow(rowID: id, text: text, attributedBody: body, isFromMe: mine, chatIdentifier: chat, participantCount: people)
    }

    private static func filterOverRows() {
        let rows = [
            row(10, "Rio open Chrome"),
            row(11, "hello there"),
            row(12, "Rio quit everything", mine: false, chat: "+15559990000"),
            row(13, "Rio open Chrome", chat: "+15559990000"),
            row(14, nil, body: blob("Rio what's the weather")),
            row(15, "Rio hi", chat: "chat123456", people: 3),
            row(16, "Riot control"),
            row(17, "\(RioPhoneText.replyMarker) Opened Chrome"),
            row(18, "rio, set a timer for 5 minutes", chat: "ME@example.com"),
            row(19, "Rio open Safari", mine: false),
            row(20, "Rio from a group that includes me", chat: "+15550100100", people: 2),
            row(5, "Rio old message"),
        ]
        let scan = RioPhoneFilter.scan(rows, ownerHandles: owner, after: 9)
        TestSupport.expectEqual(scan.commands.map(\.rowID), [10, 14, 18])
        TestSupport.expectEqual(scan.commands.map(\.text), ["Rio open Chrome", "Rio what's the weather", "rio, set a timer for 5 minutes"])
        TestSupport.expectEqual(scan.commands.last?.replyHandle, "ME@example.com")
        TestSupport.expectEqual(scan.lastRowID, 20)

        let again = RioPhoneFilter.scan(rows, ownerHandles: owner, after: scan.lastRowID)
        TestSupport.expect(again.commands.isEmpty, "nothing is run twice")
        TestSupport.expectEqual(again.lastRowID, 20)

        TestSupport.expect(RioPhoneFilter.scan(rows, ownerHandles: [], after: 0).commands.isEmpty, "no owner handle, no commands")
        TestSupport.expectEqual(RioPhoneFilter.scan([], ownerHandles: owner, after: 7).lastRowID, 7)
        let flood = (1...50).map { row(Int64($0), "Rio open Chrome") }
        let capped = RioPhoneFilter.scan(flood, ownerHandles: owner, after: 0)
        TestSupport.expectEqual(capped.commands.count, RioPhoneFilter.maxCommandsPerScan)
        TestSupport.expectEqual(capped.lastRowID, 50)
    }

    // MARK: Synthetic chat.db

    private static func exec(_ db: OpaquePointer?, _ sql: String) {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            fatalError("synthetic chat.db failed: \(error.map { String(cString: $0) } ?? "?") for \(sql)")
        }
    }

    private static func makeDatabase(at path: String) {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { fatalError("cannot create the synthetic chat.db") }
        defer { sqlite3_close(db) }
        exec(db, """
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT);
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, chat_identifier TEXT, style INTEGER);
        CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT, attributedBody BLOB, is_from_me INTEGER, handle_id INTEGER, date INTEGER);
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
        INSERT INTO handle (id) VALUES ('+15550100100'), ('+15559990000'), ('+15558880000');
        INSERT INTO chat (chat_identifier, style) VALUES ('+15550100100', 45), ('+15559990000', 45), ('chat123456', 43);
        INSERT INTO chat_handle_join VALUES (1, 1), (2, 2), (3, 1), (3, 2), (3, 3);
        """)
        func insert(_ text: String?, body: Data? = nil, mine: Int, chat: Int, handle: Int) {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO message (text, attributedBody, is_from_me, handle_id, date) VALUES (?, ?, ?, ?, 0)", -1, &statement, nil)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            if let text { sqlite3_bind_text(statement, 1, text, -1, transient) } else { sqlite3_bind_null(statement, 1) }
            if let body { _ = body.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(body.count), transient) } } else { sqlite3_bind_null(statement, 2) }
            sqlite3_bind_int(statement, 3, Int32(mine))
            sqlite3_bind_int(statement, 4, Int32(handle))
            sqlite3_step(statement)
            sqlite3_finalize(statement)
            exec(db, "INSERT INTO chat_message_join VALUES (\(chat), \(sqlite3_last_insert_rowid(db)))")
        }
        insert("Rio open Chrome", mine: 1, chat: 1, handle: 1)                   // 1: accepted
        insert("lunch?", mine: 1, chat: 1, handle: 1)                            // 2: no Rio
        insert("Rio quit everything", mine: 0, chat: 2, handle: 2)               // 3: a friend
        insert("Rio open Chrome", mine: 1, chat: 2, handle: 2)                   // 4: me, but to a friend
        insert(nil, body: blob("Rio what's the weather"), mine: 1, chat: 1, handle: 1) // 5: accepted (attributedBody)
        insert("Rio hello all", mine: 1, chat: 3, handle: 1)                     // 6: a group
        insert("\(RioPhoneText.replyMarker) Opened Chrome", mine: 1, chat: 1, handle: 1) // 7: Rio's own reply
        insert("Rio open Safari", mine: 0, chat: 1, handle: 1)                   // 8: not sent by me
    }

    private static func syntheticDatabase() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rio-phone-db-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("chat.db").path
        makeDatabase(at: path)

        guard let reader = RioChatDBReader(path: path) else { fatalError("the reader must open a readable database") }
        TestSupport.expectEqual(reader.maxRowID(), 8)
        let rows = reader.rows(after: 0, limit: 100)
        TestSupport.expectEqual(rows.map(\.rowID), [1, 2, 3, 4, 5, 6, 7, 8])
        TestSupport.expectEqual(rows[5].participantCount, 3)
        TestSupport.expectEqual(rows[0].chatIdentifier, "+15550100100")
        TestSupport.expectEqual(rows[0].isFromMe, true)
        TestSupport.expectEqual(reader.rows(after: 6, limit: 100).map(\.rowID), [7, 8])
        TestSupport.expectEqual(reader.rows(after: 0, limit: 3).map(\.rowID), [1, 2, 3])

        let scan = RioPhoneFilter.scan(rows, ownerHandles: ["+1 555 010 0100"], after: 0)
        TestSupport.expectEqual(scan.commands.map(\.rowID), [1, 5])
        TestSupport.expectEqual(scan.commands.map(\.text), ["Rio open Chrome", "Rio what's the weather"])
        TestSupport.expectEqual(scan.lastRowID, 8)

        // The reader is read-only: it cannot create, and a write through its connection is refused.
        TestSupport.expect(RioChatDBReader(path: dir.appendingPathComponent("missing.db").path) == nil, "read-only open never creates a file")
        TestSupport.expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("missing.db").path), "no file was created")
        TestSupport.expect(!reader.canWrite(), "the connection must be read-only")
    }
}
