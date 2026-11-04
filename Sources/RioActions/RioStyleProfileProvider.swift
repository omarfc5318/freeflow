import Foundation

/// Holds the current style profile in memory and applies the Settings off switch and reset.
/// Nothing is persisted except the reset date (so a reset survives a relaunch). The app calls
/// `refresh` with the owner's dictations after each dictation and at launch; the cleanup prompt
/// and write-for-me read from it.
final class RioStyleProfileProvider: @unchecked Sendable {
    static let enabledKey = "rioStyleProfileEnabled"
    static let resetAtKey = "rioStyleProfileResetAt"

    static let shared = RioStyleProfileProvider(
        isEnabled: { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true },
        resetAt: {
            let value = UserDefaults.standard.double(forKey: resetAtKey)
            return value > 0 ? Date(timeIntervalSince1970: value) : nil
        },
        setResetAt: { UserDefaults.standard.set($0?.timeIntervalSince1970 ?? 0, forKey: resetAtKey) }
    )

    private let isEnabledProvider: () -> Bool
    private let resetAtProvider: () -> Date?
    private let setResetAt: (Date?) -> Void
    private let lock = NSLock()
    private var stored: RioStyleProfile?

    init(isEnabled: @escaping () -> Bool, resetAt: @escaping () -> Date?, setResetAt: @escaping (Date?) -> Void) {
        isEnabledProvider = isEnabled
        resetAtProvider = resetAt
        self.setResetAt = setResetAt
    }

    var isEnabled: Bool { isEnabledProvider() }

    /// The usable profile, or nil when it is off or there is too little to go on.
    var current: RioStyleProfile? {
        guard isEnabled else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let stored, stored.isUsable else { return nil }
        return stored
    }

    func cleanupPromptSection() -> String { current?.cleanupPrompt() ?? "" }
    func writingGuidance() -> String { current?.writingGuidance() ?? "" }

    /// Rebuilds the profile from the owner's dictations (newest first up to a cap).
    func refresh(entries: [RioHistoryEntry], now: Date = Date()) {
        guard isEnabled else { return }
        let samples = RioStyleProfile.eligibleSamples(from: entries, after: resetAtProvider())
        let profile = RioStyleProfile.extract(from: samples)
        lock.lock()
        stored = profile
        lock.unlock()
    }

    /// "Reset": forget what was learned and ignore every dictation made so far.
    func reset(now: Date = Date()) {
        setResetAt(now)
        lock.lock()
        stored = nil
        lock.unlock()
    }
}
