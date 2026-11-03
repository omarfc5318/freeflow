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
