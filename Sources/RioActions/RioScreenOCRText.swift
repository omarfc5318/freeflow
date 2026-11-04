import Foundation

/// One recognised line of text and where it sat in the window. Coordinates are Vision's:
/// normalised 0...1 with the origin at the bottom left.
struct RioOCRLine: Equatable {
    let text: String
    let minX: Double
    let minY: Double
    let width: Double
    let height: Double

    var midY: Double { minY + height / 2 }
}

/// Puts Vision's separate text pieces back into reading order: rows top to bottom, each row left
/// to right, or right to left when the row is Arabic. Pure.
enum RioOCRText {
    struct Result: Equatable {
        let text: String
        let lineCount: Int
    }

    private static let paragraphGap = 1.0

    static func join(_ lines: [RioOCRLine]) -> Result {
        let usable = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let sorted = usable.sorted { $0.midY > $1.midY }

        var rows: [[RioOCRLine]] = []
        for line in sorted {
            if let last = rows.last, let anchor = last.first,
               abs(anchor.midY - line.midY) <= 0.5 * max(anchor.height, line.height) {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }

        var output = ""
        var previousBottom: Double?
        for row in rows {
            let ordered = rowText(row)
            let top = row.map { $0.minY + $0.height }.max() ?? 0
            let height = row.map(\.height).max() ?? 0
            if let previousBottom {
                output += "\n"
                if previousBottom - top > paragraphGap * height { output += "\n" }
            }
            output += ordered
            previousBottom = row.map(\.minY).min() ?? 0
        }
        return Result(text: output, lineCount: rows.count)
    }

    private static func rowText(_ row: [RioOCRLine]) -> String {
        let combined = row.map(\.text).joined(separator: " ")
        let isRightToLeft = RioArabicText.isArabic(combined)
        let ordered = row.sorted { isRightToLeft ? $0.minX > $1.minX : $0.minX < $1.minX }
        return ordered.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " ")
    }

    /// "Copied 12 lines".
    static func summary(lineCount: Int) -> String {
        lineCount == 1 ? "Copied 1 line" : "Copied \(lineCount) lines"
    }
}
