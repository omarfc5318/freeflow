import AppKit

/// Whether Rio's windows show up in screenshots, screen recordings and screen shares.
/// Off by default: he is still on the real display, just not in captures.
enum RioCompanionPrivacy {
    static let defaultsKey = "rio_show_in_captures"

    static func sharingType(showInCaptures: Bool) -> NSWindow.SharingType {
        showInCaptures ? .readOnly : .none
    }

    static var sharingType: NSWindow.SharingType {
        sharingType(showInCaptures: UserDefaults.standard.bool(forKey: defaultsKey))
    }
}
