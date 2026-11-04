import Foundation

/// "Rio, organize my Downloads": the plan, its safety rules, its wording and its inverse. Pure:
/// Foundation only. Nothing here touches the disk; the organizer feeds it directory listings and
/// carries out what it returns.
///
/// Rules: only loose files at the top level move; nothing is deleted or overwritten (a taken name
/// gets " 2", " 3"...); files changed in the last two minutes, still downloading, hidden, folders
/// and unknown types stay where they are.
enum RioDownloadCategory: String, CaseIterable, Equatable {
    case images = "Images"
    case pdfs = "PDFs"
    case documents = "Documents"
    case spreadsheets = "Spreadsheets"
    case presentations = "Presentations"
    case archives = "Archives"
    case installers = "Installers"
    case audio = "Audio"
    case video = "Video"

    private static let table: [String: RioDownloadCategory] = {
        let groups: [(RioDownloadCategory, [String])] = [
            (.images, ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "tif", "bmp", "svg", "raw", "dng"]),
            (.pdfs, ["pdf"]),
            (.documents, ["doc", "docx", "pages", "rtf", "odt", "txt", "md", "epub"]),
            (.spreadsheets, ["xls", "xlsx", "csv", "numbers", "ods"]),
            (.presentations, ["ppt", "pptx", "key", "odp"]),
            (.archives, ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"]),
            (.installers, ["dmg", "pkg", "iso"]),
            (.audio, ["mp3", "m4a", "wav", "aac", "flac", "aiff"]),
            (.video, ["mp4", "mov", "m4v", "avi", "mkv", "webm"]),
        ]
        var table: [String: RioDownloadCategory] = [:]
        for (category, extensions) in groups { for ext in extensions { table[ext] = category } }
        return table
    }()

    static func category(forExtension ext: String) -> RioDownloadCategory? { table[ext.lowercased()] }
}

struct RioDownloadEntry: Equatable {
    let name: String
    let isDirectory: Bool
    let modified: Date
}

/// One planned (or done) move. Paths are absolute.
struct RioDownloadMove: Equatable {
    let from: String
    let to: String
    let category: RioDownloadCategory

    var originalName: String { (from as NSString).lastPathComponent }
    var newName: String { (to as NSString).lastPathComponent }
    var folder: String { ((to as NSString).deletingLastPathComponent as NSString).lastPathComponent }
}

struct RioDownloadsPlan: Equatable {
    var moves: [RioDownloadMove] = []
    var skippedRecent = 0
    var skippedDownloading = 0
    var skippedOther = 0

    var isEmpty: Bool { moves.isEmpty }

    static let recentWindow: TimeInterval = 120
    static let inProgressExtensions: Set<String> = [
        "crdownload", "download", "part", "partial", "opdownload", "tmp", "temp", "filepart", "aria2", "!ut",
    ]
    /// Longest list shown whole in the confirmation; the panel stays a sensible size.
    static let maxListedMoves = 40

    // MARK: Building

    /// `existing` maps a category folder name to the lowercase names already inside it, so a move
    /// never lands on top of something. Moves are planned in name order.
    static func build(
        entries: [RioDownloadEntry], downloadsPath: String, existing: [String: Set<String>], now: Date
    ) -> RioDownloadsPlan {
        var plan = RioDownloadsPlan()
        var taken = existing
        for entry in entries.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            let ext = (entry.name as NSString).pathExtension.lowercased()
            if entry.isDirectory || entry.name.hasPrefix(".") { plan.skippedOther += 1; continue }
            if inProgressExtensions.contains(ext) || entry.name.hasPrefix(".com.google.Chrome") {
                plan.skippedDownloading += 1
                continue
            }
            if now.timeIntervalSince(entry.modified) < recentWindow { plan.skippedRecent += 1; continue }
            guard let category = RioDownloadCategory.category(forExtension: ext) else { plan.skippedOther += 1; continue }
            let folder = category.rawValue
            let wanted = tidyName(entry.name)
            let finalName = uniqueName(wanted, taken: taken[folder] ?? [])
            taken[folder, default: []].insert(finalName.lowercased())
            plan.moves.append(RioDownloadMove(
                from: downloadsPath + "/" + entry.name,
                to: downloadsPath + "/" + folder + "/" + finalName,
                category: category
            ))
        }
        return plan
    }

    // MARK: Names

    /// Only obvious fixes: macOS's narrow no-break space in screenshot names, "Screen Shot" ->
    /// "Screenshot", doubled spaces. Anything else keeps its name.
    static func tidyName(_ name: String) -> String {
        var tidy = name
        for odd in ["\u{202F}", "\u{00A0}", "\u{2009}"] { tidy = tidy.replacingOccurrences(of: odd, with: " ") }
        if tidy.hasPrefix("Screen Shot ") { tidy = "Screenshot " + tidy.dropFirst("Screen Shot ".count) }
        tidy = RioText.collapseWhitespace(tidy)
        let stem = (tidy as NSString).deletingPathExtension
        let ext = (tidy as NSString).pathExtension
        let trimmedStem = stem.trimmingCharacters(in: .whitespaces)
        guard !trimmedStem.isEmpty else { return name }
        return ext.isEmpty ? trimmedStem : trimmedStem + "." + ext
    }

    /// "a.pdf" -> "a 2.pdf" -> "a 3.pdf" until the lowercase name is free (APFS ignores case).
    static func uniqueName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name.lowercased()) else { return name }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            if !taken.contains(candidate.lowercased()) { return candidate }
            counter += 1
        }
    }

    // MARK: Wording

    /// The whole plan, as the confirmation shows it.
    var description: String {
        guard !moves.isEmpty else { return "Nothing needs tidying." }
        var lines = ["Move \(moves.count) file\(moves.count == 1 ? "" : "s") into folders inside Downloads:"]
        for move in moves.prefix(Self.maxListedMoves) {
            lines.append(move.originalName == move.newName
                ? "\(move.originalName)  \u{2192}  \(move.folder)/"
                : "\(move.originalName)  \u{2192}  \(move.folder)/\(move.newName)")
        }
        if moves.count > Self.maxListedMoves { lines.append("...and \(moves.count - Self.maxListedMoves) more") }
        var kept: [String] = []
        if skippedRecent > 0 { kept.append("\(skippedRecent) changed in the last 2 minutes") }
        if skippedDownloading > 0 { kept.append("\(skippedDownloading) still downloading") }
        if !kept.isEmpty { lines.append("Left where they are: " + kept.joined(separator: ", ") + ".") }
        lines.append("Nothing is deleted or overwritten. Say \"Rio, undo\" to put everything back.")
        return lines.joined(separator: "\n")
    }

    var confirmationContent: RioConfirmationContent {
        guard !moves.isEmpty else {
            return RioConfirmationContent(title: "Your Downloads are already tidy", detail: description, confirmLabel: "OK")
        }
        return RioConfirmationContent(title: "Tidy up your Downloads?", detail: description, confirmLabel: "Tidy up")
    }

    var summary: String {
        "Moved \(moves.count) file\(moves.count == 1 ? "" : "s") into folders in Downloads"
    }
}

/// What "undo" does for a finished tidy-up.
struct RioDownloadsUndoPlan: Equatable {
    var restores: [RioDownloadMove] = []
    /// Files that are no longer where Rio put them (moved or trashed since).
    var missing = 0

    /// Newest move first. A file goes back under its original name; when something now sits in
    /// that spot, it comes back with a number added instead of replacing it.
    static func inverse(of moves: [RioDownloadMove], exists: (String) -> Bool) -> RioDownloadsUndoPlan {
        var plan = RioDownloadsUndoPlan()
        var reserved = Set<String>()
        for move in moves.reversed() {
            guard exists(move.to) else { plan.missing += 1; continue }
            let directory = (move.from as NSString).deletingLastPathComponent
            var target = move.from
            if exists(target) || reserved.contains(target.lowercased()) {
                var counter = 2
                let name = move.originalName
                let stem = (name as NSString).deletingPathExtension
                let ext = (name as NSString).pathExtension
                repeat {
                    let candidate = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
                    target = directory + "/" + candidate
                    counter += 1
                } while exists(target) || reserved.contains(target.lowercased())
            }
            reserved.insert(target.lowercased())
            plan.restores.append(RioDownloadMove(from: move.to, to: target, category: move.category))
        }
        return plan
    }
}
