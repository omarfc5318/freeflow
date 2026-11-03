import Combine
import Foundation

// STUB (lead): builder D replaces this file. The corner bear observes it.
@MainActor final class RioConversationMode: ObservableObject {
    static let shared = RioConversationMode()
    @Published private(set) var isOn = false
    /// True while conversation mode is on but paused (another app is using the mic, or dictation).
    @Published private(set) var isPaused = false
}
