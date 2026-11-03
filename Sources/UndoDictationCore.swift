import Foundation

/// Finds a just-pasted dictation in a text field: it must end exactly at the cursor.
/// Anything else (edited text, a moved cursor, a copy elsewhere in the field) is not
/// treated as the dictation, so undo can never remove text the user wrote.
enum UndoDictationCore {
    /// UTF-16 range of the inserted text ending at the cursor. `inserted` is the text exactly
    /// as it was pasted, including any trailing space FreeFlow added; a version without that
    /// trailing whitespace is also accepted, since some editors trim it.
    static func rangeEndingAtCursor(inserted: String, fieldValue: String, selection: NSRange?) -> NSRange? {
        guard let selection, selection.length == 0 else { return nil }
        let value = fieldValue as NSString
        guard selection.location <= value.length else { return nil }
        for candidate in candidateTexts(for: inserted) {
            let length = (candidate as NSString).length
            guard selection.location >= length else { continue }
            let range = NSRange(location: selection.location - length, length: length)
            if value.substring(with: range) == candidate { return range }
        }
        return nil
    }

    private static func candidateTexts(for inserted: String) -> [String] {
        let trimmed = inserted.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        guard !trimmed.isEmpty else { return [] }
        return trimmed == inserted ? [inserted] : [inserted, trimmed]
    }
}
