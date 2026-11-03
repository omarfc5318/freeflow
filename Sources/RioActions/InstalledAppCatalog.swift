import Foundation

/// The apps installed on this Mac, read from the standard Applications folders. Read-only:
/// nothing is launched. Names are file names without ".app".
enum InstalledAppCatalog {
    /// Searched in this order; the first folder wins when two apps share a name.
    static func searchDirectories(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Library/CoreServices"),  // Finder lives here
            home.appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    static func scan() -> [InstalledApp] {
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        for directory in searchDirectories() {
            for url in appBundles(in: directory) {
                let name = url.deletingPathExtension().lastPathComponent
                guard seen.insert(name.lowercased()).inserted else { continue }
                apps.append(InstalledApp(name: name, bundleIdentifier: Bundle(url: url)?.bundleIdentifier, url: url))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// `.app` bundles directly in `directory`, plus one level down for plain folders such as
    /// "/Applications/Setapp". CoreServices is limited to Finder: its other bundles are not apps
    /// a person would ask for.
    private static func appBundles(in directory: URL) -> [URL] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        let onlyFinder = directory.path == "/System/Library/CoreServices"
        var result: [URL] = []
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            if entry.pathExtension == "app" {
                if !onlyFinder || entry.lastPathComponent == "Finder.app" { result.append(entry) }
            } else if !onlyFinder, directory.path == "/Applications",
                      (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                      entry.lastPathComponent != "Utilities" {
                let inner = (try? manager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                result.append(contentsOf: inner.filter { $0.pathExtension == "app" }.sorted { $0.path < $1.path })
            }
        }
        return result
    }
}
