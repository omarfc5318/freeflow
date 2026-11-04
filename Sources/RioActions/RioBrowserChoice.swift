import Foundation

/// Which browser a web link opens in (finding 27). "open github in Safari" parses as Safari, then
/// the link: the link goes to the browser Rio just brought forward, and "open github" while Safari
/// is in front stays in Safari. Anything else gets the default browser. Pure: app bundle URLs in,
/// an app bundle URL (or nil for the default browser) out.
enum RioBrowserChoice {
    /// A browser opened or switched to this recently is where the next link goes, even while
    /// macOS is still bringing it to the front.
    static let recentOpenSeconds: TimeInterval = 10

    static func target(
        recentlyOpened: URL?, openedSecondsAgo: TimeInterval?, frontmost: URL?, browsers: Set<URL>
    ) -> URL? {
        let browserPaths = Set(browsers.map(\.standardizedFileURL.path))
        func isBrowser(_ url: URL?) -> Bool { url.map { browserPaths.contains($0.standardizedFileURL.path) } ?? false }
        if let recentlyOpened, let age = openedSecondsAgo, (0...recentOpenSeconds).contains(age), isBrowser(recentlyOpened) {
            return recentlyOpened
        }
        if let frontmost, isBrowser(frontmost) { return frontmost }
        return nil
    }
}
