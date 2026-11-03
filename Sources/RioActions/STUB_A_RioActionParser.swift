import Foundation

// Throwaway stand-in for Builder B's RioActionParser. The lead deletes this file at merge.
struct RioActionParser: RioActionParsing {
    init(installedApps: [InstalledApp]) {}
    func parse(_ transcript: String) -> RioActionParse {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .empty : .unknown(trimmed)
    }
}
