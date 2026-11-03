import AppKit
import Foundation
import os.log

private let enhancementsLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "Enhancements")

// MARK: - Storage

extension AppState {
    static let wordReplacementsStorageKey = "word_replacements"
    static let dictationStylesStorageKey = "dictation_styles"
    static let whisperModeStorageKey = "whisper_mode_enabled"
    static let usageStatsStorageKey = "usage_stats_daily"
    static let usageStatsEnabledStorageKey = "usage_stats_enabled"

    static let handsFreeAutoStopDelayStorageKey = "hands_free_auto_stop_seconds"
    static let screenNamesVocabularyStorageKey = "screen_names_vocabulary_enabled"

    /// Falls back to the default for missing or unknown values from other versions.
    static func loadHandsFreeAutoStopDelay() -> TimeInterval {
        guard let stored = UserDefaults.standard.object(forKey: handsFreeAutoStopDelayStorageKey) as? Double,
              SilenceAutoStop.delayChoices.contains(stored) else { return SilenceAutoStop.defaultDelay }
        return stored
    }

    static func loadUsageStatsEnabled() -> Bool {
        UserDefaults.standard.object(forKey: usageStatsEnabledStorageKey) as? Bool ?? true
    }

    static func loadStoredJSON<Value: Decodable>(forKey key: String) -> Value? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    static func storeJSON<Value: Encodable>(_ value: Value, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Stored as `{"email": "formal"}`; unknown keys or values from other versions are skipped.
    static func loadDictationStyles() -> [DictationStyleCategory: DictationStyle] {
        let stored: [String: String] = loadStoredJSON(forKey: dictationStylesStorageKey) ?? [:]
        var styles: [DictationStyleCategory: DictationStyle] = [:]
        for (category, style) in stored {
            guard let category = DictationStyleCategory(rawValue: category),
                  let style = DictationStyle(rawValue: style) else { continue }
            styles[category] = style
        }
        return styles
    }

    static func storeDictationStyles(_ styles: [DictationStyleCategory: DictationStyle]) {
        let stored = Dictionary(uniqueKeysWithValues: styles.map { ($0.key.rawValue, $0.value.rawValue) })
        storeJSON(stored, forKey: dictationStylesStorageKey)
    }
}

// MARK: - Dictionary, snippets and styles

extension AppState {
    var hasCustomDictationStyles: Bool {
        dictationStyles.values.contains { $0 != .standard }
    }

    func style(for category: DictationStyleCategory) -> DictationStyle {
        dictationStyles[category] ?? .standard
    }

    /// Snapshot of the dictionary, snippets and style for one dictation. Call on the main thread.
    func dictationTextRules(customSystemPrompt: String, category: DictationStyleCategory) -> DictationTextRules {
        DictationTextRules(
            replacements: TextExpansionCore.replacementRules(wordReplacements),
            snippets: voiceMacros
                .filter(\.expandsInline)
                .map { TextExpansionRule(phrase: $0.command, output: $0.payload, adaptsCase: false) },
            systemPrompt: styledSystemPrompt(customSystemPrompt, category: category)
        )
    }

    /// The cleanup prompt for one dictation: the user's prompt (or the default), plus the
    /// app's writing style and a request to leave snippet trigger phrases untouched so they
    /// can be expanded afterwards. Returns the user's prompt unchanged when neither applies.
    func styledSystemPrompt(_ customSystemPrompt: String, category: DictationStyleCategory) -> String {
        let style = style(for: category)
        let triggers = voiceMacros.filter(\.expandsInline).map(\.command)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard style != .standard || !triggers.isEmpty else { return customSystemPrompt }

        var prompt = DictationStyleCore.systemPrompt(base: Self.resolvedSystemPrompt(customSystemPrompt), style: style)
        if !triggers.isEmpty {
            let quoted = triggers.map { "\"\($0)\"" }.joined(separator: ", ")
            prompt += "\n\nKeep these phrases word for word if they are spoken, because they are replaced afterwards: \(quoted)"
        }
        return prompt
    }

    // MARK: Vocabulary import and export

    /// Adds terms from a text or CSV file (one per line, or separated by commas or semicolons).
    func importVocabulary(from url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return addVocabularyTerms(Self.vocabularyEntries(in: text))
    }

    /// Writes one vocabulary term per line.
    func exportVocabulary(to url: URL) throws {
        let text = Self.vocabularyEntries(in: customVocabulary).joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Whisper mode

extension AppState {
    /// A temporary boosted copy of the recording, or nil when it is already loud enough or
    /// cannot be boosted (the original is then transcribed). The original is never changed.
    static func whisperBoostedCopy(of url: URL) -> URL? {
        do {
            return try WhisperModeAudio.boostedCopy(of: url)
        } catch {
            os_log(.error, log: enhancementsLog, "Whisper mode boost skipped: %{public}@", error.localizedDescription)
            return nil
        }
    }

    static func removeTemporaryAudio(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Usage stats

extension AppState {
    var usageSummary: UsageSummary {
        UsageStatsCore.summary(of: usageDays, today: Date(), calendar: .current)
    }

    private static let milestoneDelay: TimeInterval = 1.0

    /// Counts the words spoken and the recording time; the text itself is not kept.
    func recordUsage(spokenText: String, seconds: TimeInterval) {
        guard usageStatsEnabled else { return }
        let before = usageSummary
        usageDays = UsageStatsCore.recording(
            words: UsageStatsCore.wordCount(spokenText), seconds: seconds,
            on: Date(), into: usageDays, calendar: .current
        )
        guard let milestone = TeddyMilestoneCore.crossed(before: before, after: usageSummary) else { return }
        // After the paste, so it does not collide with the closing pill.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.milestoneDelay) { [weak self] in
            self?.showTeddyMoment(.milestone(milestone.label))
        }
    }

    func resetUsageStats() {
        usageDays = [:]
    }
}
