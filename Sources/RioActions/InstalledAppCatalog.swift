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
            URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications"),  // Safari lives here
            URL(fileURLWithPath: "/System/Library/CoreServices"),  // Finder lives here
            home.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/Applications"),  // Simulator
        ]
    }

    static func scan() -> [InstalledApp] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let userApplications = home.appendingPathComponent("Applications", isDirectory: true).path
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        for directory in searchDirectories(home: home) {
            let path = directory.path
            let bundles = appBundles(
                in: directory,
                scanFolders: path == "/Applications" || path == userApplications,
                onlyFinder: path == "/System/Library/CoreServices"
            )
            for url in bundles {
                let name = url.deletingPathExtension().lastPathComponent
                guard seen.insert(name.lowercased()).inserted else { continue }
                apps.append(InstalledApp(name: name, bundleIdentifier: Bundle(url: url)?.bundleIdentifier, url: url))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// `.app` bundles directly in `directory`, plus one level down in plain folders when
    /// `scanFolders` is set ("/Applications/Setapp", "/Applications/RStudio-2023.09.0-463").
    /// CoreServices is limited to Finder: its other bundles are not apps a person would ask for.
    static func appBundles(in directory: URL, scanFolders: Bool, onlyFinder: Bool = false) -> [URL] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [URL] = []
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            if entry.pathExtension.lowercased() == "app" {
                if !onlyFinder || entry.lastPathComponent == "Finder.app" { result.append(entry) }
            } else if scanFolders, !onlyFinder,
                      (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                      entry.lastPathComponent != "Utilities" {
                let inner = (try? manager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                result.append(contentsOf: inner.filter { $0.pathExtension.lowercased() == "app" }.sorted { $0.path < $1.path })
            }
        }
        return result
    }
}
