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

    /// Longest country calling code.
    private static let maxCountryCodeDigits = 3

    /// Same address or the same phone number. Two numbers that both carry a country code must be
    /// identical. When only one does, the other must be its complete national number (at least 10
    /// digits) behind a country code of one to three digits; a number that merely ends in the same
    /// 10 digits is someone else.
    static func matches(_ first: String, _ second: String) -> Bool {
        let a = normalize(first), b = normalize(second)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        guard isPhoneLike(first), isPhoneLike(second) else { return false }
        let ad = a.filter(\.isNumber), bd = b.filter(\.isNumber)
        guard ad.count >= 10, bd.count >= 10 else { return false }
        let aInternational = a.hasPrefix("+"), bInternational = b.hasPrefix("+")
        if aInternational == bInternational { return ad == bd }
        let (international, national) = aInternational ? (ad, bd) : (bd, ad)
        let codeDigits = international.count - national.count
        return (1...maxCountryCodeDigits).contains(codeDigits) && international.hasSuffix(national)
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

extension RioPhoneReply {
    /// What the phone is told for each way a command can end. Every outcome gets a reply, so the
    /// phone never waits out a timeout for a command that did nothing.
    static func message(for outcome: RioActionOutcome, summary: String) -> (message: String, succeeded: Bool) {
        switch outcome {
        case .succeeded(let text): return (text, true)
        case .failed(let message): return (message, false)
        case .unknown: return (summary, false)
        case .nothing: return ("There was nothing for me to do there.", false)
        case .cancelled: return ("I didn't do that one. Anything that needs a yes has to be done on your Mac.", false)
        }
    }
}

// MARK: - Commands waiting for Rio (phone texts and automations)

/// Commands that don't come from the owner's voice (a schedule, a trigger, a text from the phone)
/// wait here while Rio is busy: a command running, a recording or transcription, or a question
/// on screen. They run in order once he is free, so none is refused and lost, and none types into
/// a field while the owner is dictating. One that waited too long is dropped with a note.
struct RioWaitingCommands<Item> {
    static var maxWaitSeconds: TimeInterval { 120 }
    static var capacity: Int { 10 }

    private(set) var items: [(item: Item, since: Date)] = []

    var isEmpty: Bool { items.isEmpty }

    /// False when the line is full; the caller says so instead of queueing.
    mutating func add(_ item: Item, at now: Date) -> Bool {
        guard items.count < Self.capacity else { return false }
        items.append((item, now))
        return true
    }

    /// A taken item that could not start after all goes back to the front, keeping its age.
    mutating func putBack(_ item: Item, since: Date) {
        items.insert((item, since), at: 0)
    }

    enum Next {
        case wait
        case run(Item)
        case expired(Item)
    }

    /// The next thing to do. Expired items come out first, even while busy, so the note is prompt.
    mutating func next(now: Date, isBusy: Bool) -> Next {
        guard let first = items.first else { return .wait }
        if now.timeIntervalSince(first.since) > Self.maxWaitSeconds {
            items.removeFirst()
            return .expired(first.item)
        }
        guard !isBusy else { return .wait }
        items.removeFirst()
        return .run(first.item)
    }
}
