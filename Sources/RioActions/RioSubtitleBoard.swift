import Foundation

struct RioSubtitleLine: Equatable, Identifiable {
    let id: Int
    let original: String
    /// nil while the translation is still on its way.
    var translation: String?
    let language: RioTranslatorLanguage?
    let target: RioTranslatorLanguage?
    let at: Date
}

/// What "say it" speaks: the newest finished translation and the language it is in.
struct RioLastTranslation: Equatable {
    let text: String
    let language: RioTranslatorLanguage
}

/// The caption lines on screen: the newest `maxLines`, each dropped after `maxAge` seconds. The
/// newest translation outlives its line so "say it" still works after the captions fade.
/// Immutable: every change returns a new board.
struct RioSubtitleBoard: Equatable {
    static let maxLines = 3
    static let maxAge: TimeInterval = 20

    private(set) var lines: [RioSubtitleLine] = []
    private(set) var lastTranslation: RioLastTranslation?
    private var nextID = 1

    /// Adds a heard line (translation pending) and returns the new board and the line's id.
    func adding(
        original: String, language: RioTranslatorLanguage?, target: RioTranslatorLanguage?, now: Date
    ) -> (board: RioSubtitleBoard, id: Int) {
        var next = self
        let line = RioSubtitleLine(
            id: nextID, original: original, translation: nil, language: language, target: target, at: now
        )
        next.nextID += 1
        next.lines = Array((lines + [line]).suffix(Self.maxLines))
        return (next, line.id)
    }

    /// Fills in a line's translation. A blank text, or a line that already scrolled away, changes nothing.
    func settingTranslation(id: Int, text: String) -> RioSubtitleBoard {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let index = lines.firstIndex(where: { $0.id == id }) else { return self }
        var next = self
        next.lines[index].translation = cleaned
        if let target = lines[index].target { next.lastTranslation = RioLastTranslation(text: cleaned, language: target) }
        return next
    }

    func pruned(now: Date) -> RioSubtitleBoard {
        var next = self
        next.lines = lines.filter { now.timeIntervalSince($0.at) < Self.maxAge }
        return next
    }

    func clearing() -> RioSubtitleBoard {
        var next = self
        next.lines = []
        return next
    }
}
