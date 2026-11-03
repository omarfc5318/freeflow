import Combine
import Foundation

// STUB (lead): builder M replaces this file. The corner bear observes it (headphones).
@MainActor final class RioTranslatorMode: ObservableObject {
    static let shared = RioTranslatorMode()
    @Published private(set) var isOn = false
}
