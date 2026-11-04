import Foundation

/// What a spoken "find the PDF Ali sent me last week" asks for: a person, a time window, file
/// kinds and a few leftover words. Pure: Foundation only.
enum RioFindKind: String, Equatable, Hashable, CaseIterable {
    case pdf, word, slides, sheet, image, video, audio, text, archive, link

    var extensions: Set<String> {
        switch self {
        case .pdf: return ["pdf"]
        case .word: return ["doc", "docx", "pages", "rtf", "odt"]
        case .slides: return ["ppt", "pptx", "key", "odp"]
        case .sheet: return ["xls", "xlsx", "csv", "numbers", "ods"]
        case .image: return ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "tif"]
        case .video: return ["mp4", "mov", "m4v"]
        case .audio: return ["mp3", "m4a", "wav", "aac", "caf"]
        case .text: return ["txt", "md", "markdown", "tex"]
        case .archive: return ["zip", "rar", "7z", "tar", "gz"]
        case .link: return ["webloc", "url"]
        }
    }
}

struct RioFindQuery: Equatable {
    /// A name or relation as spoken ("ali", "dr smith", "mom"). Nil when no person was named.
    var person: String?
    var kinds: Set<RioFindKind> = []
    var interval: DateInterval?
    /// Words that only help ranking ("invoice", "tax").
    var keywords: [String] = []

    /// True when the user asked for a link, which lives in message text Rio doesn't search.
    var wantsLink: Bool { kinds.contains(.link) }

    /// Extensions a result may have; empty means any.
    var allowedExtensions: Set<String> {
        kinds.reduce(into: Set<String>()) { $0.formUnion($1.extensions) }
    }

    /// Enough to search with at all: a person, a window or a kind.
    var isSearchable: Bool { person != nil || interval != nil || !kinds.isEmpty }

    // MARK: Vocabulary

    private static let verbs = "sent|shared|texted|messaged|emailed|mailed|airdropped|forwarded|gave|dropped"

    private static let stopWords: Set<String> = [
        "the", "a", "an", "that", "this", "those", "these", "my", "our", "your", "me", "us", "i", "ive", "it", "its",
        "what", "which", "whatever", "thing", "things", "stuff", "something", "file", "files", "one", "ones",
        "from", "by", "on", "in", "at", "of", "for", "to", "about", "with", "via", "over", "through", "during",
        "since", "after", "before", "back", "up", "out", "around", "please", "got", "get", "received", "downloaded",
        "saved", "attachment", "attachments", "and", "or", "was", "is", "were", "had", "have", "has", "just",
        "last", "past", "previous", "next", "ago", "earlier", "recently", "lately", "today", "yesterday",
        "morning", "night", "tonight", "week", "weeks", "month", "months", "day", "days", "hour", "hours",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "then", "also",
        "messages", "message", "imessage", "mail", "email", "text", "texts", "chat", "whatsapp",
    ]

    private static let kindWords: [String: [RioFindKind]] = [
        "pdf": [.pdf], "pdfs": [.pdf],
        "document": [.word, .pdf], "documents": [.word, .pdf], "doc": [.word, .pdf], "docs": [.word, .pdf],
        "docx": [.word], "word": [.word], "essay": [.word, .pdf], "paper": [.word, .pdf],
        "slides": [.slides, .pdf], "slide": [.slides, .pdf], "deck": [.slides, .pdf],
        "presentation": [.slides, .pdf], "powerpoint": [.slides], "keynote": [.slides], "pptx": [.slides],
        "spreadsheet": [.sheet], "spreadsheets": [.sheet], "excel": [.sheet], "sheet": [.sheet], "csv": [.sheet],
        "photo": [.image], "photos": [.image], "picture": [.image], "pictures": [.image], "pic": [.image],
        "pics": [.image], "image": [.image], "images": [.image], "screenshot": [.image], "screenshots": [.image],
        "selfie": [.image], "jpg": [.image], "png": [.image],
        "video": [.video], "videos": [.video], "clip": [.video], "movie": [.video],
        "audio": [.audio], "song": [.audio], "voicemail": [.audio], "recording": [.audio, .video],
        "zip": [.archive], "archive": [.archive],
        "link": [.link], "links": [.link], "url": [.link], "website": [.link],
    ]

    private static let sentVerbs = Set(verbs.split(separator: "|").map(String.init))

    private static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "")
            .replacingOccurrences(of: "'", with: "")
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    // MARK: Parsing

    static func parse(_ spoken: String, now: Date, calendar: Calendar = .current) -> RioFindQuery {
        var query = RioFindQuery()
        var text = fold(spoken)
        if let found = RioFindTime.extract(from: text, now: now, calendar: calendar) {
            query.interval = found.interval
            text = found.remainder
        }
        query.person = person(in: text)

        let personWords = Set(words(query.person ?? ""))
        for word in words(text) {
            if let kinds = kindWords[word] { query.kinds.formUnion(kinds); continue }
            if stopWords.contains(word) || personWords.contains(word) || sentVerbs.contains(word) { continue }
            if word.count < 3 && Int(word) == nil { continue }
            if !query.keywords.contains(word) { query.keywords.append(word) }
        }
        return query
    }

    private static let personStops: Set<String> = stopWords.union(Set(verbs.split(separator: "|").map(String.init)))
        .subtracting(["my"])

    private static func person(in text: String) -> String? {
        if let groups = RioText.firstMatch(#"^(.*?)\b(?:\#(verbs))\b\s*(?:it\s+|that\s+|this\s+)?(?:over\s+)?(?:to\s+)?(?:me|us)\b"#, in: text),
           let left = groups[1] {
            let found = tail(of: words(left))
            if !found.isEmpty { return found.joined(separator: " ") }
        }
        if let groups = RioText.firstMatch(#"\bfrom\s+(.+)$"#, in: text), let right = groups[1] {
            let found = head(of: words(right))
            if !found.isEmpty { return found.joined(separator: " ") }
        }
        return nil
    }

    private static func isNameWord(_ word: String) -> Bool {
        !personStops.contains(word) && kindWords[word] == nil
    }

    /// The run of name words right before the verb ("pdf that ali" -> ["ali"]).
    private static func tail(of tokens: [String]) -> [String] {
        var found: [String] = []
        for token in tokens.reversed() {
            if token == "my", let first = found.first, relations.contains(first) { break }
            guard isNameWord(token), found.count < 3 else { break }
            found.insert(token, at: 0)
        }
        return found
    }

    /// The run of name words right after "from" ("ali last week" -> ["ali"]).
    private static func head(of tokens: [String]) -> [String] {
        var rest = tokens[...]
        if rest.first == "my" { rest = rest.dropFirst() }
        var found: [String] = []
        for token in rest {
            guard isNameWord(token), found.count < 3 else { break }
            found.append(token)
        }
        return found
    }

    private static let relations: Set<String> = [
        "mom", "dad", "mother", "father", "brother", "sister", "boss", "wife", "husband", "friend", "professor",
        "prof", "teacher", "manager", "uncle", "aunt", "grandma", "grandpa", "mum",
    ]
}
