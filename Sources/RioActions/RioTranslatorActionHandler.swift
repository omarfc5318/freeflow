import Foundation

/// Runs the translator actions: start, stop and "say it". Everything else returns nil.
@MainActor final class RioTranslatorActionHandler: RioActionHandling {
    static let shared = RioTranslatorActionHandler()

    private let mode: RioTranslatorMode

    init(mode: RioTranslatorMode? = nil) {
        self.mode = mode ?? RioTranslatorMode.shared
    }

    func handle(_ action: RioAction, executor: RioActionExecuting) async -> RioActionResult? {
        switch action {
        case .startTranslation:
            return mode.start()
        case .stopTranslation:
            guard mode.isOn else { return .done(summary: "Translator is already off") }
            mode.stop(.voice)
            return .done(summary: "Stopped translating")
        case .speakLastTranslation:
            return mode.speakLast()
        default:
            return nil
        }
    }
}
