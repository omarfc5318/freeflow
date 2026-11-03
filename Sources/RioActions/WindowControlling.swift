import Foundation

/// Moves and resizes another app's window. The executor depends on this protocol only, so
/// tests can substitute a fake and never touch a real window.
@MainActor protocol WindowControlling {
    /// Applies the command to the named app's focused window, or the frontmost app's when
    /// `appName` is nil. Never throws: failures come back as a user-facing message.
    func apply(_ command: WindowCommand) -> RioActionResult
}
