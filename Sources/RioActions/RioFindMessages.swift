import Foundation

/// How Messages' own database describes an attachment, turned into search results. Pure: the
/// reading itself (read-only, in memory, never logged or kept) lives in `RioFindSources`.
enum RioMessagesAttachments {
    /// Attachments in the window, newest first. `?1` is the earliest message date (see `storedDate`).
    static let sql = """
        SELECT a.filename, m.date, m.is_from_me, h.id \
        FROM attachment a \
        JOIN message_attachment_join j ON j.attachment_id = a.ROWID \
        JOIN message m ON m.ROWID = j.message_id \
        LEFT JOIN handle h ON h.ROWID = m.handle_id \
        WHERE a.filename IS NOT NULL AND m.date >= ?1 \
        ORDER BY m.date DESC LIMIT 400
        """

    private static let appleEpochOffset: TimeInterval = 978_307_200
    private static let nanosecondThreshold: Double = 100_000_000_000

    struct Row: Equatable {
        let filename: String?
        let date: Int64
        let isFromMe: Bool
        let handle: String?
    }

    /// Seconds or nanoseconds since 2001-01-01, as the table stores them (older macOS used seconds).
    static func date(fromStored value: Int64) -> Date {
        let raw = Double(value)
        let seconds = abs(raw) >= nanosecondThreshold ? raw / 1_000_000_000 : raw
        return Date(timeIntervalSince1970: seconds + appleEpochOffset)
    }

    /// The value to bind for "messages since `date`", in the modern nanosecond unit.
    static func storedDate(for date: Date) -> Int64 {
        Int64(max(0, date.timeIntervalSince1970 - appleEpochOffset) * 1_000_000_000)
    }

    /// Nil for rows without a usable file name. Only messages from someone else carry a sender,
    /// so "Ali sent me" never matches a file the user sent to Ali.
    static func result(from row: Row, home: String) -> RioFindResult? {
        guard var path = row.filename, !path.isEmpty else { return nil }
        if path.hasPrefix("~/") { path = home + String(path.dropFirst(1)) }
        guard path.hasPrefix("/") else { return nil }
        return RioFindResult(
            path: path, date: date(fromStored: row.date), sender: row.isFromMe ? nil : row.handle, sources: [.messages]
        )
    }
}
