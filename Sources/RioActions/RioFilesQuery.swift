import Foundation

/// What the user asked for when they named a file ("the MAT108 homework 6 PDF"), turned into
/// search words, file types and a recency preference. Pure: Foundation only.
enum RioFileType: String, Equatable, Hashable {
    case pdf, word, slides, sheet, image, text, folder

    var extensions: [String] {
        switch self {
        case .pdf: return ["pdf"]
        case .word: return ["doc", "docx", "pages", "rtf", "odt"]
        case .slides: return ["ppt", "pptx", "key"]
        case .sheet: return ["xls", "xlsx", "csv", "numbers"]
        case .image: return ["png", "jpg", "jpeg", "heic", "gif", "webp"]
        case .text: return ["txt", "md", "tex"]
        case .folder: return []
        }
    }

    static func forExtension(_ ext: String) -> RioFileType? {
        let lowered = ext.lowercased()
        return [RioFileType.pdf, .word, .slides, .sheet, .image, .text].first { $0.extensions.contains(lowered) }
    }
}

struct RioFileQuery: Equatable {
    /// Words that must appear in the file's name (or its folder's name).
    var coreTokens: [String] = []
    /// Words that only help ranking ("deck", "slides").
    var softTokens: [String] = []
    var types: Set<RioFileType> = []
    var preferRecent = false

    var isEmpty: Bool { coreTokens.isEmpty && softTokens.isEmpty && types.isEmpty }

    /// The words a name must contain: the core words, or the soft ones when there are no others.
    var effectiveTokens: [String] { coreTokens.isEmpty ? softTokens : coreTokens }

    // MARK: Parsing

    private static let stopWords: Set<String> = [
        "my", "the", "a", "an", "that", "this", "our", "of", "called", "named", "titled", "from", "about", "on",
        "in", "for", "with", "i", "ive", "saved", "downloaded", "to", "and", "copy", "version", "it", "me",
        "please", "most", "file", "files", "one",
    ]
    private static let recencyWords: Set<String> = ["latest", "last", "recent", "newest", "newer", "recently"]

    private static let extensionPattern = "pdf|docx?|pptx?|xlsx?|csv|txt|md|pages|key|numbers|png|jpe?g|zip|tex"

    static func parse(_ spoken: String) -> RioFileQuery {
        var text = fold(spoken)
        text = RioText.replacing(#"\s+dot\s+(\#(extensionPattern))\b"#, with: ".$1", in: text)
        var query = RioFileQuery()

        // "resume.pdf" -> the file type from the extension, the stem stays as a word.
        while let groups = RioText.firstMatch(#"([a-z0-9_-]+)\.(\#(extensionPattern))\b"#, in: text),
              let whole = groups[0], let stem = groups[1], let ext = groups[2] {
            if let type = RioFileType.forExtension(ext) { query.types.insert(type) }
            text = text.replacingOccurrences(of: whole, with: stem)
        }

        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        var index = 0
        while index < words.count {
            let word = words[index]
            index += 1
            if stopWords.contains(word) {
                if word == "one", !query.coreTokens.isEmpty { query.coreTokens.append("1") }
                continue
            }
            if recencyWords.contains(word) { query.preferRecent = true; continue }
            if word == "word", index < words.count, ["document", "doc", "docx"].contains(words[index]) {
                query.types.insert(.word)
                index += 1
                continue
            }
            if applyKeyword(word, to: &query) { continue }
            let value = RioText.number(from: word).map(String.init) ?? word
            query.coreTokens.append(contentsOf: splitBoundaries(value))
        }
        return query
    }

    /// Words with a fixed meaning: a file type, or a soft ranking word. True when consumed.
    private static func applyKeyword(_ word: String, to query: inout RioFileQuery) -> Bool {
        switch word {
        case "pdf", "pdfs": query.types.insert(.pdf)
        case "doc", "docs", "docx", "document", "documents": query.types.insert(.word)
        case "spreadsheet", "spreadsheets", "excel", "xlsx", "csv", "sheet": query.types.insert(.sheet)
        case "powerpoint", "ppt", "pptx", "keynote": query.types.insert(.slides)
        case "image", "images", "picture", "pictures", "photo", "photos", "png", "jpg", "jpeg": query.types.insert(.image)
        case "folder", "folders", "directory": query.types.insert(.folder)
        case "deck", "slides", "slide", "presentation":
            query.softTokens.append(word)
            query.types.formUnion([.slides, .pdf])
        case "screenshot", "screenshots":
            query.softTokens.append("screenshot")
            query.types.insert(.image)
        default: return false
        }
        return true
    }

    /// Lowercase, diacritics and quotes removed.
    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
    }

    /// "mat108" -> ["mat", "108"].
    static func splitBoundaries(_ word: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var currentIsDigit = false
        for character in word {
            let isDigit = character.isNumber
            if !current.isEmpty, isDigit != currentIsDigit {
                pieces.append(current)
                current = ""
            }
            current.append(character)
            currentIsDigit = isDigit
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    // MARK: Aliases

    private static let aliasGroups: [[String]] = [
        ["homework", "hw", "hmwk", "assignment"],
        ["resume", "cv"],
        ["syllabus", "syll"],
        ["lecture", "lec"],
        ["midterm", "mt"],
        ["presentation", "deck", "slides", "slide", "pres"],
    ]

    /// Words that mean the same in a file name, including the word itself.
    static func equivalents(of token: String) -> [String] {
        for group in aliasGroups where group.contains(token) { return group }
        return [token]
    }
}

/// Folders people name directly ("open my downloads folder").
enum RioWellKnownFolder: String, Equatable, CaseIterable {
    case desktop, documents, downloads, home, pictures, movies, music, iCloudDrive, applications

    /// Nil unless the whole phrase is a folder. Names that are also apps (Music, Photos, Home)
    /// only count when "folder" is said, so "open Music" still reaches the app logic.
    static func match(spoken: String) -> RioWellKnownFolder? {
        var words = RioFileQuery.fold(spoken).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        while let first = words.first, ["my", "the", "your", "our"].contains(first) { words.removeFirst() }
        var hasFolderWord = false
        if let last = words.last, ["folder", "directory"].contains(last) {
            hasFolderWord = true
            words.removeLast()
        }
        let name = words.joined(separator: " ")
        switch name {
        case "desktop": return .desktop
        case "documents": return .documents
        case "downloads", "download": return name == "download" && !hasFolderWord ? nil : .downloads
        case "icloud drive", "icloud": return .iCloudDrive
        case "home": return hasFolderWord ? .home : nil
        case "pictures": return hasFolderWord ? .pictures : nil
        case "movies": return hasFolderWord ? .movies : nil
        case "music": return hasFolderWord ? .music : nil
        case "applications": return hasFolderWord ? .applications : nil
        default: return nil
        }
    }

    func path(home: String) -> String {
        let base = home.hasSuffix("/") && home.count > 1 ? String(home.dropLast()) : home
        switch self {
        case .desktop: return base + "/Desktop"
        case .documents: return base + "/Documents"
        case .downloads: return base + "/Downloads"
        case .home: return base
        case .pictures: return base + "/Pictures"
        case .movies: return base + "/Movies"
        case .music: return base + "/Music"
        case .iCloudDrive: return base + "/Library/Mobile Documents/com~apple~CloudDocs"
        case .applications: return "/Applications"
        }
    }

    /// How Rio names it: "your Downloads folder", "iCloud Drive".
    var displayName: String {
        switch self {
        case .iCloudDrive: return "iCloud Drive"
        case .home: return "your home folder"
        case .applications: return "the Applications folder"
        default: return "your \(rawValue.prefix(1).uppercased() + rawValue.dropFirst()) folder"
        }
    }
}

/// Builds the Spotlight predicates. Values always go in as predicate arguments, never into the
/// format string, so spoken text can't change the shape of a query.
enum RioSpotlightPredicates {
    private static func nameContains(_ word: String) -> NSPredicate {
        NSPredicate(format: "kMDItemFSName CONTAINS[cd] %@", word)
    }

    private static func extensionPredicate(_ types: Set<RioFileType>) -> NSPredicate? {
        let extensions = types.flatMap(\.extensions).sorted()
        guard !extensions.isEmpty else { return nil }
        return NSCompoundPredicate(orPredicateWithSubpredicates: extensions.map {
            NSPredicate(format: "kMDItemFSName ENDSWITH[cd] %@", "." + $0)
        })
    }

    /// File names that contain every word (or an equivalent, like "hw" for "homework").
    static func name(for query: RioFileQuery) -> NSPredicate? {
        let tokens = query.effectiveTokens
        if tokens.isEmpty { return extensionPredicate(query.types) }
        let groups = tokens.map { token in
            NSCompoundPredicate(orPredicateWithSubpredicates: RioFileQuery.equivalents(of: token).map(nameContains))
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: groups)
    }

    /// Files whose text contains the words (used only when no name matches).
    static func content(for query: RioFileQuery) -> NSPredicate? {
        let words = query.effectiveTokens.filter { $0.count >= 3 && $0.allSatisfy(\.isLetter) }
        guard !words.isEmpty else { return nil }
        var parts: [NSPredicate] = words.map { NSPredicate(format: "kMDItemTextContent CONTAINS[cd] %@", $0) }
        if let types = extensionPredicate(query.types) { parts.append(types) }
        return NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    static func nameFormat(for query: RioFileQuery) -> String? { name(for: query)?.predicateFormat }
    static func contentFormat(for query: RioFileQuery) -> String? { content(for: query)?.predicateFormat }
}
