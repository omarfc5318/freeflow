import Foundation

/// What a `BrowserCommand` does in the frontmost app: a standard shortcut, or a scroll-wheel
/// nudge over whatever is under the pointer.
enum BrowserPlan: Equatable {
    case keys(KeyCombo)
    /// Positive scrolls the page down, negative up.
    case scroll(pixelsDown: Int)
}

enum RioBrowserKeys {
    static let scrollPixels = 480

    private static func combo(_ key: String, command: Bool = false, shift: Bool = false, control: Bool = false) -> BrowserPlan {
        .keys(KeyCombo(key: key, command: command, shift: shift, option: false, control: control))
    }

    static func plan(for command: BrowserCommand) -> BrowserPlan {
        switch command {
        case .newTab: return combo("t", command: true)
        case .closeTab: return combo("w", command: true)
        case .reopenTab: return combo("t", command: true, shift: true)
        case .nextTab: return combo("tab", control: true)
        case .previousTab: return combo("tab", shift: true, control: true)
        case .back: return combo("leftbracket", command: true)
        case .forward: return combo("rightbracket", command: true)
        case .reload: return combo("r", command: true)
        case .find: return combo("f", command: true)
        case .scrollToTop: return combo("up", command: true)
        case .scrollToBottom: return combo("down", command: true)
        case .scrollDown: return .scroll(pixelsDown: scrollPixels)
        case .scrollUp: return .scroll(pixelsDown: -scrollPixels)
        }
    }

    static func summary(for command: BrowserCommand) -> String {
        switch command {
        case .newTab: return "Opened a new tab"
        case .closeTab: return "Closed the tab"
        case .reopenTab: return "Reopened the tab"
        case .nextTab: return "Next tab"
        case .previousTab: return "Previous tab"
        case .back: return "Went back"
        case .forward: return "Went forward"
        case .reload: return "Refreshed the page"
        case .find: return "Opened find"
        case .scrollToTop: return "Scrolled to the top"
        case .scrollToBottom: return "Scrolled to the bottom"
        case .scrollDown: return "Scrolled down"
        case .scrollUp: return "Scrolled up"
        }
    }
}

/// What Rio noticed about a tab it closed itself (finding 77): only whether it was a blank New
/// Tab page, in which app, and when. The window title it was read from is never kept, logged or
/// stored; this lives in memory only.
struct RioClosedTabNote: Equatable {
    let appID: String?
    let wasBlank: Bool
    let at: TimeInterval
}

enum RioReopenTabPlan: Equatable {
    /// Shift-Cmd-T, the browser's own reopen.
    case reopen
    /// The tab Rio just closed was blank, and browsers don't keep blank tabs: Shift-Cmd-T would
    /// bring back some older closed window instead. Open a new blank tab (Cmd-T).
    case openBlank
}

extension RioBrowserKeys {
    /// A "reopen" this soon after Rio closed a blank tab in the same app means that tab.
    static let reopenMemorySeconds: TimeInterval = 120

    static let reopenedBlankSummary = "That tab was blank, so I opened a new one"
    static let reopenedWindowSummary = "The browser brought back a closed window"

    /// Titles of a browser's empty tab (Chrome, Safari, Firefox, Arc, Brave, Edge), as the front
    /// window reports them, sometimes followed by " - Google Chrome" or a profile name.
    private static let blankTabTitles = [
        "new tab", "new private tab", "new incognito tab", "start page", "favorites", "favourites",
        "top sites", "untitled", "blank page", "about:blank", "private browsing", "new window",
    ]

    static func isBlankTabTitle(_ title: String?) -> Bool {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !title.isEmpty else { return false }
        return blankTabTitles.contains { title == $0 || title.hasPrefix($0 + " - ") || title.hasPrefix($0 + " \u{2014} ") || title.hasPrefix($0 + " \u{2013} ") }
    }

    static func reopenPlan(lastClosed: RioClosedTabNote?, appID: String?, now: TimeInterval) -> RioReopenTabPlan {
        guard let lastClosed, lastClosed.wasBlank, lastClosed.appID == appID,
              (0...reopenMemorySeconds).contains(now - lastClosed.at) else { return .reopen }
        return .openBlank
    }

    /// What to say after Shift-Cmd-T: a whole window coming back is said out loud.
    static func reopenSummary(windowsBefore: Int?, windowsAfter: Int?) -> String {
        if let windowsBefore, let windowsAfter, windowsAfter > windowsBefore { return reopenedWindowSummary }
        return summary(for: .reopenTab)
    }
}
