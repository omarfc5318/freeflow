import Foundation
import SQLite3

// Reads Messages' chat.db read-only (builder S). Needs Full Disk Access.
// It never writes, never copies the file and never keeps message text beyond one poll.

enum RioPhoneAccess: Equatable {
    case ok
    case denied
    case missing

    static var defaultPath: String { NSHomeDirectory() + "/Library/Messages/chat.db" }

    /// Opens the file for reading, which is exactly what Full Disk Access gates.
    static func check(path: String = defaultPath) -> RioPhoneAccess {
        let descriptor = open(path, O_RDONLY)
        if descriptor >= 0 {
            close(descriptor)
            return .ok
        }
        return errno == ENOENT ? .missing : .denied
    }

    static let setupSteps = """
    1. Open System Settings, then Privacy and Security, then Full Disk Access.
    2. Turn on Rio Dictate (press + and add it from Applications if it isn't listed).
    3. Quit and reopen Rio Dictate, then come back here.
    """
}

final class RioChatDBReader {
    private var db: OpaquePointer?

    /// Nil when the file can't be opened read-only (missing, no access, not a database).
    init?(path: String = RioPhoneAccess.defaultPath) {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 1_000)
    }

    deinit { sqlite3_close(db) }

    func maxRowID() -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(ROWID), 0) FROM message", -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : 0
    }

    /// Messages newer than `last`, oldest first, with the chat they belong to.
    func rows(after last: Int64, limit: Int) -> [RioChatRow] {
        let sql = """
        SELECT m.ROWID, m.text, m.attributedBody, m.is_from_me, c.chat_identifier,
               (SELECT COUNT(*) FROM chat_handle_join j WHERE j.chat_id = c.ROWID)
        FROM message m
        LEFT JOIN chat_message_join cm ON cm.message_id = m.ROWID
        LEFT JOIN chat c ON c.ROWID = cm.chat_id
        WHERE m.ROWID > ?1
        ORDER BY m.ROWID ASC
        LIMIT ?2
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, last)
        sqlite3_bind_int(statement, 2, Int32(limit))
        var rows: [RioChatRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(RioChatRow(
                rowID: sqlite3_column_int64(statement, 0),
                text: string(statement, 1),
                attributedBody: blob(statement, 2),
                isFromMe: sqlite3_column_int(statement, 3) != 0,
                chatIdentifier: string(statement, 4),
                participantCount: Int(sqlite3_column_int(statement, 5))
            ))
        }
        return rows
    }

    /// Test hook: whether this connection could write. It must never be able to.
    func canWrite() -> Bool {
        sqlite3_exec(db, "CREATE TABLE rio_write_probe (x INTEGER)", nil, nil, nil) == SQLITE_OK
    }

    private func string(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    private func blob(_ statement: OpaquePointer?, _ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}
