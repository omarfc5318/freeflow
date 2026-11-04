import Foundation

/// Pulls the spoken command out of what the recognizer heard: only the words after "Rio"
/// (or "hey Rio", "Ryo", "Reo" ...). Pure text logic. Speech without the name yields nil, so
/// the listener can drop it without ever keeping it.
///
/// The name must START the utterance (a greeting or filler may come first) or follow the end of
/// a sentence. "I told Rio to open Chrome" and a video that mentions Rio mid-sentence are not
/// commands. The listener ends an utterance at each pause, so "start of the transcript" means
/// "after a pause".
enum WakePhraseExtractor {
    /// The command after the first name in `transcript`, or nil when there is no name or
    /// nothing after it yet ("Rio" alone, "hey Rio"). Keeps the speaker's wording, casing and
    /// trailing punctuation; strips the name, a greeting before it and punctuation after it.
    static func command(in transcript: String) -> String? {
        let words = wordRanges(in: transcript)
        guard let first = words.indices.first(where: { isName(words[$0].text) && startsUtterance(at: $0, in: words, text: transcript) })
        else { return nil }
        var last = first
        while last + 1 < words.count, isName(words[last + 1].text) { last += 1 }
        let rest = transcript[words[last].range.upperBound...]
        let trimmed = rest
            .drop { !($0.isLetter || $0.isNumber) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains { $0.isLetter || $0.isNumber } ? trimmed : nil
    }

    /// Words that may come before the name without it being mid-sentence.
    private static let leadIns: Set<String> = [
        "hey", "hi", "hello", "yo", "yoo", "ok", "okay", "uh", "um", "so", "oh", "alright", "right", "well"
    ]

    private static func startsUtterance(
        at index: Int, in words: [(text: String, range: Range<String.Index>)], text: String
    ) -> Bool {
        if index == 0 { return true }
        if words[..<index].allSatisfy({ leadIns.contains($0.text.lowercased()) || isName($0.text) }) { return true }
        // After a sentence end ("Okay. Rio open Chrome").
        let before = text[words[index - 1].range.upperBound..<words[index].range.lowerBound]
        return before.contains { ".!?\n".contains($0) }
    }

    private static func isName(_ word: String) -> Bool {
        let lowered = word.lowercased()
        if TeddyCommand.names.contains(lowered) { return true }
        // "Yo Rio" run together by the recognizer, e.g. "Yorio".
        return lowered.hasPrefix("yo") && TeddyCommand.names.contains(String(lowered.dropFirst(2)))
    }

    /// Words are runs of letters, digits and inner apostrophes ("what's" is one word, so
    /// "Rio's" is not the name).
    private static func wordRanges(in text: String) -> [(text: String, range: Range<String.Index>)] {
        var result: [(String, Range<String.Index>)] = []
        var start: String.Index?
        var index = text.startIndex
        func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "\u{2019}" }
        while index < text.endIndex {
            if isWordCharacter(text[index]) {
                if start == nil { start = index }
            } else if let s = start {
                result.append((String(text[s..<index]), s..<index))
                start = nil
            }
            index = text.index(after: index)
        }
        if let s = start { result.append((String(text[s...]), s..<text.endIndex)) }
        return result
    }
}
