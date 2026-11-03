import Foundation

// Clipboard history logic (pure). The history lives in memory only and is never written
// anywhere; secrets are filtered before they are ever stored. See RioClipboardHistory for the
// pasteboard side.

enum RioClipboardKind: Equatable {
    case link, email, phone, address, number, text

    private static let commonTLDs = "com|org|net|io|co|app|dev|ai|edu|gov|me|us|uk|qa|ae|sa|xyz|info|ly|so|to|tv|gg|fm|sh|cloud|page|site|online|tech"

    static func classify(_ text: String) -> RioClipboardKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .text }
        let singleToken = !trimmed.contains(where: \.isWhitespace)
        if singleToken, isLink(trimmed) { return .link }
        if singleToken, RioText.matches(#"^(?:mailto:)?[A-Z0-9._%+-]+@[A-Z0-9-]+(?:\.[A-Z0-9-]+)*\.[A-Z]{2,}$"#, trimmed) { return .email }
        if isPhone(trimmed) { return .phone }
        if RioText.matches(#"^[+-]?\d[\d,]*(?:\.\d+)?$"#, trimmed) { return .number }
        if isAddress(trimmed) { return .address }
        return .text
    }

    private static func isLink(_ token: String) -> Bool {
        if RioText.matches(#"^https?://[^\s/]+\S*$"#, token) { return true }
        if RioText.matches(#"^www\.[^\s/]+\.[A-Z]{2,}\S*$"#, token) { return true }
        return RioText.matches(#"^[A-Z0-9-]+(?:\.[A-Z0-9-]+)*\.(?:\#(commonTLDs))(?:[/?#]\S*)?$"#, token)
    }

    private static func isPhone(_ text: String) -> Bool {
        guard RioText.matches(#"^\+?[\d\s().-]+$"#, text) else { return false }
        if RioText.matches(#"^\d{4}-\d{2}-\d{2}$"#, text) { return false }
        let digits = text.filter(\.isNumber)
        guard (7...15).contains(digits.count) else { return false }
        let hasSeparators = text.contains(where: { " ().-".contains($0) })
        return text.hasPrefix("+") || hasSeparators || digits.count >= 10
    }

    private static func isAddress(_ text: String) -> Bool {
        guard text.count <= 200, text.split(separator: "\n").count <= 4,
              RioText.matches(#"^\d+[A-Z]?\s+\S"#, text) else { return false }
        let street = #"\b(?:street|st|avenue|ave|road|rd|boulevard|blvd|drive|dr|lane|ln|way|parkway|pkwy|court|ct|place|pl|square|sq|highway|hwy|terrace|circle)\b"#
        return RioText.matches(street, text) || RioText.matches(#"\b[A-Z]{2}\s+\d{5}\b"#, text)
    }
}

struct RioClipboardItem: Equatable {
    let text: String
    let date: Date
    let kind: RioClipboardKind

    init(text: String, date: Date) {
        self.text = text
        self.date = date
        self.kind = RioClipboardKind.classify(text)
    }
}

/// Decides what is never remembered: concealed and transient pasteboard types, password
/// managers, blank or enormous text.
enum RioClipboardFilter {
    static let maxCharacters = 20_000

    private static let secretTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
        "de.petermaurer.TransientPasteboardType", "com.agilebits.onepassword", "com.1password.password",
        "com.typeit4me.clipping", "net.antelle.keeweb",
    ]

    private static let passwordManagers: Set<String> = [
        "com.1password.1password", "com.1password.1password7", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.lastpass.lastpassmacdesktop", "com.dashlane.dashlanephonefinal",
        "org.keepassxc.keepassxc", "com.apple.keychainaccess", "com.apple.passwords", "com.apple.Passwords",
        "com.enpass.enpass-mac", "in.sinew.enpass-desktop", "com.nordsec.nordpass", "com.protonpass.pass",
    ]

    static func shouldSkip(types: [String]) -> Bool {
        types.contains { secretTypes.contains($0) }
    }

    static func shouldSkip(sourceBundleID: String?) -> Bool {
        guard let id = sourceBundleID?.lowercased() else { return false }
        return passwordManagers.contains { $0.lowercased() == id }
    }

    static func isStorable(text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= maxCharacters
    }
}

/// The last 20 text items, newest first. A value type: every change returns a new buffer.
struct RioClipboardBuffer: Equatable {
    static let capacity = 20
    let items: [RioClipboardItem]

    init(items: [RioClipboardItem] = []) {
        self.items = items
    }

    func adding(_ text: String, at date: Date) -> RioClipboardBuffer {
        guard RioClipboardFilter.isStorable(text: text) else { return self }
        var next = items.filter { $0.text != text }
        next.insert(RioClipboardItem(text: text, date: date), at: 0)
        return RioClipboardBuffer(items: Array(next.prefix(Self.capacity)))
    }

    func cleared() -> RioClipboardBuffer { RioClipboardBuffer() }
}

enum RioClipboardMatcher {
    private static let stopWords: Set<String> = [
        "the", "a", "an", "my", "that", "this", "i", "copied", "earlier", "from", "before", "one", "thing", "last",
        "previous", "text", "clipboard", "of", "to", "for",
    ]

    /// The item the hint asks for. A type word (link, email, phone, address, number) picks the
    /// newest item of that type; other words must all appear in the text; no hint means the
    /// previous item (the newest is what's on the clipboard right now).
    static func match(hint: String?, in buffer: RioClipboardBuffer) -> RioClipboardItem? {
        let items = buffer.items
        guard !items.isEmpty else { return nil }
        let cleaned = (hint ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return items.count >= 2 ? items[1] : items[0] }

        if let kind = kind(in: cleaned) { return items.first { $0.kind == kind } }
        let words = cleaned.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { !stopWords.contains($0) }
        guard !words.isEmpty else { return items.count >= 2 ? items[1] : items[0] }
        return items.first { item in
            let text = item.text.lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    private static func kind(in hint: String) -> RioClipboardKind? {
        if RioText.matches(#"\be\s?-?\s?mail\b"#, hint) { return .email }
        if RioText.matches(#"\b(?:links?|urls?|websites?|web\s?pages?|web\s+address|sites?)\b"#, hint) { return .link }
        if RioText.matches(#"\b(?:phone|telephone|cell)\b"#, hint) { return .phone }
        if RioText.matches(#"\baddress\b"#, hint) { return .address }
        if RioText.matches(#"^(?:number|code|digits)$"#, hint) { return .number }
        return nil
    }
}

/// What Rio says about the clipboard.
enum RioClipboardSpeech {
    static let maxSnippet = 80

    static func describe(_ item: RioClipboardItem) -> String {
        switch item.kind {
        case .link: return "a link to \(host(of: item.text))"
        case .email: return "an email address, \(item.text.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .phone: return "a phone number, \(item.text.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .address, .number, .text: return quoted(item.text)
        }
    }

    private static func quoted(_ text: String) -> String {
        let line = RioText.collapseWhitespace(text)
        guard line.count > maxSnippet else { return "\u{201C}\(line)\u{201D}" }
        let cut = String(line.prefix(maxSnippet)).trimmingCharacters(in: .whitespaces)
        return "\u{201C}\(cut)\u{2026}\u{201D}"
    }

    private static func host(of text: String) -> String {
        var token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = token.range(of: "://") { token = String(token[range.upperBound...]) }
        let host = token.split(whereSeparator: { "/?#".contains($0) }).first.map(String.init) ?? token
        return host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func current(_ item: RioClipboardItem?, hasConcealed: Bool, hasNonText: Bool) -> String {
        if hasConcealed { return "Your clipboard has something private, so I won't read it out." }
        guard let item else {
            return hasNonText ? "Your clipboard has something that isn't text." : "Your clipboard is empty."
        }
        return "Your clipboard has \(describe(item))."
    }

    static func history(_ buffer: RioClipboardBuffer) -> String {
        let items = buffer.items
        switch items.count {
        case 0: return "Nothing in your clipboard history yet."
        case 1: return "You have 1 recent copy: \(describe(items[0]))."
        default:
            let latest = items.prefix(3).map(describe).joined(separator: ", ")
            return "You have \(items.count) recent copies. Latest: \(latest)."
        }
    }
}
