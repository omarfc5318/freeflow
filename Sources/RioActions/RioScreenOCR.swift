import Foundation
import Vision

/// On-device text recognition for "copy the text from my screen". Vision runs on this Mac only;
/// the picture is in memory for the length of one call and the text goes to the clipboard, never
/// to a file, a log or the network.
enum RioScreenOCR {
    static let languages = ["en-US", "ar-SA"]

    /// Heavy: call off the main thread. Lines come back in Vision's order; `RioOCRText.join`
    /// puts them in reading order.
    static func recognize(imageData: Data) throws -> [RioOCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.revision = VNRecognizeTextRequestRevision3
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let wanted = languages.filter { supported.contains($0) }
        if !wanted.isEmpty { request.recognitionLanguages = wanted }

        try VNImageRequestHandler(data: imageData, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return RioOCRLine(text: candidate.string, minX: box.minX, minY: box.minY, width: box.width, height: box.height)
        }
    }
}
