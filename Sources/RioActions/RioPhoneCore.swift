import Foundation

// Text Rio from the iPhone (builder S): the pure rules. Foundation only.
//
// Safety rules enforced here, before any command can run:
//  - only messages the owner SENT (is_from_me), in a one-person chat whose identifier is one of
//    the owner's own handles (a text to themselves). Everything else is ignored: other people,
//    groups, and the owner's texts to friends.
//  - the text must start with the word "Rio".
//  - only rows newer than the last processed ROWID, so nothing ever runs twice.
//  - Rio's own replies start with a marker and are never read back as commands.

struct RioChatRow: Equatable {
    let rowID: Int64
    let text: String?
    let attributedBody: Data?
    let isFromMe: Bool
    let chatIdentifier: String?
    let participantCount: Int
}

struct RioPhoneCommand: Equatable {
    let rowID: Int64
    let text: String
    /// The chat the command came from (one of the owner's own handles); the reply goes here.
    let replyHandle: String
}

struct RioPhoneScan: Equatable {
    let commands: [RioPhoneCommand]
    /// The highest ROWID seen, whether or not it was a command: store it so none repeats.
    let lastRowID: Int64
}

enum RioPhoneHandle {
    /// Digits, spaces and phone punctuation only: no letters, no "@".
    private static func isPhoneLike(_ handle: String) -> Bool {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.allSatisfy { $0.isNumber || " +()-.".contains($0) }
    }

    static func normalize(_ handle: String) -> String {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPhoneLike(trimmed) else { return trimmed.lowercased() }
        return (trimmed.hasPrefix("+") ? "+" : "") + trimmed.filter(\.isNumber)
    }

    /// Same address or the same phone number (a missing country code still matches).
    static func matches(_ first: String, _ second: String) -> Bool {
        let a = normalize(first), b = normalize(second)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        guard isPhoneLike(first), isPhoneLike(second) else { return false }
        let ad = a.filter(\.isNumber), bd = b.filter(\.isNumber)
        guard ad.count >= 10, bd.count >= 10 else { return false }
        return ad.suffix(10) == bd.suffix(10)
    }

    static func parseList(_ text: String) -> [String] {
        text.split(whereSeparator: { ",;\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

enum RioPhoneText {
    /// Every Rio reply starts with this, so Rio never answers its own answers.
    static let replyMarker = "\u{1F43B}"
    static let maxCommandLength = 500

    /// Newer macOS stores a message's text only inside the `attributedBody` typedstream:
    /// "NSString", five bytes, then a length (one byte, or 0x81 and two little-endian bytes), then UTF-8.
    static func decode(text: String?, attributedBody: Data?) -> String? {
        if let text, !text.isEmpty { return text }
        guard let body = attributedBody else { return nil }
        let bytes = [UInt8](body)
        let marker = Array("NSString".utf8)
        guard bytes.count > marker.count + 6,
              let start = (0...(bytes.count - marker.count)).first(where: { Array(bytes[$0..<$0 + marker.count]) == marker }) else { return nil }
        var index = start + marker.count
        guard let plus = (index..<min(index + 8, bytes.count)).first(where: { bytes[$0] == 0x2B }) else { return nil }
        index = plus + 1
        guard index < bytes.count else { return nil }
        var length = Int(bytes[index])
        index += 1
        if length == 0x81 {
            guard index + 2 <= bytes.count else { return nil }
            length = Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
            index += 2
        }
        guard length > 0, index + length <= bytes.count else { return nil }
        return String(data: Data(bytes[index..<index + length]), encoding: .utf8)
    }

    /// The trimmed text when it begins with the word "Rio" followed by something to do.
    static func commandText(_ body: String) -> String? {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= maxCommandLength, !text.hasPrefix(replyMarker),
              RioText.matches(#"^rio(?![\p{L}\p{N}_'’])\W*\S"#, text) else { return nil }
        return text
    }
}

enum RioPhoneFilter {
    /// Flood guard: more than this many commands in one look are dropped (never run).
    static let maxCommandsPerScan = 3

    static func scan(_ rows: [RioChatRow], ownerHandles: [String], after last: Int64) -> RioPhoneScan {
        var commands: [RioPhoneCommand] = []
        var highest = last
        for row in rows.sorted(by: { $0.rowID < $1.rowID }) where row.rowID > last {
            highest = max(highest, row.rowID)
            guard commands.count < maxCommandsPerScan, row.isFromMe, row.participantCount <= 1,
                  let chat = row.chatIdentifier, ownerHandles.contains(where: { RioPhoneHandle.matches($0, chat) }),
                  let body = RioPhoneText.decode(text: row.text, attributedBody: row.attributedBody),
                  let text = RioPhoneText.commandText(body) else { continue }
            commands.append(RioPhoneCommand(rowID: row.rowID, text: text, replyHandle: chat))
        }
        return RioPhoneScan(commands: commands, lastRowID: highest)
    }
}

enum RioPhoneReply {
    static let maxLength = 480

    static func text(_ message: String, succeeded: Bool) -> String {
        var body = RioText.collapseWhitespace(message)
        if body.isEmpty { body = "Done" }
        if body.count > maxLength { body = String(body.prefix(maxLength - 1)) + "\u{2026}" }
        return "\(RioPhoneText.replyMarker) \(body)"
    }
}
