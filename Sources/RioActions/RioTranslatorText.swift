import Foundation

/// Drops what Whisper makes up for quiet or noisy audio (it loves "Thanks for watching").
enum RioTranscriptFilter {
    private static let phrases = [
        "thanks for watching", "thank you for watching", "please subscribe", "like and subscribe",
        "subscribe to my channel", "subscribe to the channel", "subtitles by", "subtitled by", "amara org",
        "نانسي قنقر", "شكرا على المشاهدة", "شكرا للمشاهدة", "اشتركوا في القناة", "اشترك في القناة",
    ].map { RioArabicText.normalize($0) }

    static func isNoise(_ text: String) -> Bool {
        guard text.unicodeScalars.contains(where: { $0.properties.isAlphabetic }) else { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // "[Music]", "(applause)": a caption for a sound, not speech.
        if (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) || (trimmed.hasPrefix("(") && trimmed.hasSuffix(")")) {
            return true
        }
        let flat = RioArabicText.normalize(text)
            .lowercased()
            .replacingOccurrences(of: ".", with: " ")
        let words = flat.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map(String.init)
        let joined = words.joined(separator: " ")
        if phrases.contains(where: { joined.contains($0) }) { return true }
        // "you you you you you": a decoding loop.
        return words.count >= 5 && Set(words).count <= 1
    }
}

/// The translation request for one heard sentence.
enum RioTranslatorPrompt {
    static func system(from source: String?, to target: RioTranslatorLanguage) -> String {
        let from = source.flatMap { RioTranslatorLanguage.named($0)?.name ?? $0 } ?? "the spoken language"
        var text = "You are a live interpreter. Translate the user's message from \(from) into \(target.name). "
            + "Reply with the translation only: no quotes, no notes, no explanations, no labels. "
            + "Keep names and numbers. If the message is already in \(target.name), repeat it unchanged."
        if target == .arabic {
            text += " Use natural, conversational Arabic that a Gulf speaker would say, not stiff textbook phrasing."
        } else {
            text += " Use natural, conversational \(target.name)."
        }
        return text
    }

    /// Removes quotes, labels ("Translation:") and line breaks a model sometimes adds.
    static func clean(_ response: String) -> String {
        var text = response.split(whereSeparator: { $0.isNewline }).map(String.init)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        let names = (["Translation", "Translated"] + (RioTranslatorLanguage.all + [.english]).map(\.name)).joined(separator: "|")
        text = RioText.replacing("^(?:\(names))(?:\\s+translation)?\\s*:\\s*", with: "", in: text)
        let quotes = CharacterSet(charactersIn: "\"'\u{201C}\u{201D}\u{2018}\u{2019}\u{00AB}\u{00BB}")
        return text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: quotes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
