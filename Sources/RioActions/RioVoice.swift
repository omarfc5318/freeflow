import Combine
import Foundation

// STUB (lead): builder G replaces this file. The corner bear observes it.
@MainActor final class RioVoice: ObservableObject {
    static let shared = RioVoice()
    @Published private(set) var isSpeaking = false
    /// 0...1 mouth level while speaking.
    @Published private(set) var level: Double = 0
    func speak(_ text: String) {}
    func stopSpeaking() {}
}
