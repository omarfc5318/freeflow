import Foundation
import Combine
import AppKit
import AVFoundation
import ServiceManagement
import ApplicationServices
import ScreenCaptureKit
import Carbon
import os.log
private let recordingLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "Recording")

struct VoiceMacro: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var command: String
    var payload: String
    /// Snippet behavior: also expand the command when it is said inside a longer dictation.
    var expandsInline: Bool = false

    init(id: UUID = UUID(), command: String, payload: String, expandsInline: Bool = false) {
        self.id = id
        self.command = command
        self.payload = payload
        self.expandsInline = expandsInline
    }

    // Macros saved before snippets existed have no `expandsInline` key.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        command = try container.decode(String.self, forKey: .command)
        payload = try container.decode(String.self, forKey: .payload)
        expandsInline = try container.decodeIfPresent(Bool.self, forKey: .expandsInline) ?? false
    }
}

struct PrecomputedMacro {
    let original: VoiceMacro
    let normalizedCommand: String
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case dictionary
    case styles
    case macros
    case scratchpad
    case insights
    case prompts
    case runLog
    case debug

    var id: String { rawValue }

    static var visibleCases: [SettingsTab] {
        allCases.filter { tab in
            tab != .debug || AppBuild.isDevBundle
        }
    }

    var title: String {
        switch self {
        case .general: return "General"
        case .dictionary: return "Dictionary"
        case .styles: return "Styles"
        case .macros: return "Snippets & Macros"
        case .scratchpad: return "Scratchpad"
        case .insights: return "Insights"
        case .prompts: return "Prompts"
        case .runLog: return "Run Log"
        case .debug: return "Debug"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .dictionary: return "text.book.closed"
        case .styles: return "textformat"
        case .scratchpad: return "note.text"
        case .insights: return "chart.bar"
        case .prompts: return "text.bubble"
        case .macros: return "music.mic"
        case .runLog: return "clock.arrow.circlepath"
        case .debug: return "wrench.and.screwdriver"
        }
    }
}

enum AppBuild {
    static var isDevBundle: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) == "FreeFlow Dev"
    }
}

private struct PreservedPasteboardEntry {
    let type: NSPasteboard.PasteboardType
    let value: Value

    enum Value {
        case string(String)
        case propertyList(Any)
        case data(Data)
    }
}

private struct PreservedPasteboardItem {
    let entries: [PreservedPasteboardEntry]

    init(item: NSPasteboardItem) {
        self.entries = item.types.compactMap { type in
            if let string = item.string(forType: type) {
                return PreservedPasteboardEntry(type: type, value: .string(string))
            }
            if let propertyList = item.propertyList(forType: type) {
                return PreservedPasteboardEntry(type: type, value: .propertyList(propertyList))
            }
            if let data = item.data(forType: type) {
                return PreservedPasteboardEntry(type: type, value: .data(data))
            }
            return nil
        }
    }

    func makePasteboardItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        for entry in entries {
            switch entry.value {
            case .string(let string):
                item.setString(string, forType: entry.type)
            case .propertyList(let propertyList):
                item.setPropertyList(propertyList, forType: entry.type)
            case .data(let data):
                item.setData(data, forType: entry.type)
            }
        }
        return item
    }
}

private struct PreservedPasteboardSnapshot {
    let items: [PreservedPasteboardItem]

    init(pasteboard: NSPasteboard) {
        self.items = (pasteboard.pasteboardItems ?? []).map(PreservedPasteboardItem.init)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        _ = pasteboard.writeObjects(items.map { $0.makePasteboardItem() })
    }
}

private struct PendingClipboardRestore {
    let snapshot: PreservedPasteboardSnapshot
    let expectedChangeCount: Int
    let writtenTranscript: String
}

private struct TranscriptCommandParsingResult {
    let transcript: String
    let shouldPressEnterAfterPaste: Bool
}

private enum CommandInvocation: String {
    case automatic
    case manual
}

private enum SessionIntent {
    case dictation
    case command(invocation: CommandInvocation, selectedText: String)

    var isCommandMode: Bool {
        switch self {
        case .dictation:
            return false
        case .command:
            return true
        }
    }

    var persistedIntent: PipelineHistoryItemIntent {
        switch self {
        case .dictation:
            return .dictation
        case .command(let invocation, _):
            switch invocation {
            case .automatic:
                return .commandAutomatic
            case .manual:
                return .commandManual
            }
        }
    }

    var persistedSelectedText: String? {
        switch self {
        case .dictation:
            return nil
        case .command(_, let selectedText):
            return selectedText
        }
    }

    var isManualCommand: Bool {
        switch self {
        case .command(invocation: .manual, _):
            return true
        default:
            return false
        }
    }

    static func fromPersisted(intent: PipelineHistoryItemIntent, selectedText: String?) -> SessionIntent {
        if intent == .commandAutomatic, let selectedText {
            return .command(invocation: .automatic, selectedText: selectedText)
        }
        if intent == .commandManual, let selectedText {
            return .command(invocation: .manual, selectedText: selectedText)
        }
        return .dictation
    }
}

final class AppState: ObservableObject, @unchecked Sendable {
    private enum ActiveAudioInterruption {
        case muted(previouslyMuted: Bool)
    }

    private let apiKeyStorageKey = "groq_api_key"
    private let apiBaseURLStorageKey = "api_base_url"
    private let transcriptionModelStorageKey = "transcription_model"
    private let transcriptionAPIURLStorageKey = "transcription_api_url"
    private let transcriptionAPIKeyStorageKey = "transcription_api_key"
    private let postProcessingModelStorageKey = "post_processing_model"
    private let postProcessingFallbackModelStorageKey = "post_processing_fallback_model"
    private let contextModelStorageKey = "context_model"
    private let holdShortcutStorageKey = "hold_shortcut"
    private let toggleShortcutStorageKey = "toggle_shortcut"
    private let copyAgainShortcutStorageKey = "copy_again_shortcut"
    private let savedHoldCustomShortcutStorageKey = "saved_hold_custom_shortcut"
    private let savedToggleCustomShortcutStorageKey = "saved_toggle_custom_shortcut"
    private let savedCopyAgainCustomShortcutStorageKey = "saved_copy_again_custom_shortcut"
    private let undoLastShortcutStorageKey = "undo_last_shortcut"
    private let savedUndoLastCustomShortcutStorageKey = "saved_undo_last_custom_shortcut"
    private let fixLastShortcutStorageKey = "fix_last_shortcut"
    private let savedFixLastCustomShortcutStorageKey = "saved_fix_last_custom_shortcut"
    private let customVocabularyStorageKey = "custom_vocabulary"
    private let transcriptionLanguageStorageKey = "transcription_language"
    private let selectedMicrophoneStorageKey = "selected_microphone_id"
    private let customSystemPromptStorageKey = "custom_system_prompt"
    private let customContextPromptStorageKey = "custom_context_prompt"
    private let instructionExecutionGuardEnabledStorageKey = "instruction_execution_guard_enabled"
    private let customSystemPromptLastModifiedStorageKey = "custom_system_prompt_last_modified"
    private let customContextPromptLastModifiedStorageKey = "custom_context_prompt_last_modified"
    private let contextCaptureEnabledStorageKey = "context_capture_enabled"
    private let contextScreenshotMaxDimensionStorageKey = "context_screenshot_max_dimension"
    private let shortcutStartDelayStorageKey = "shortcut_start_delay"
    private let preserveClipboardStorageKey = "preserve_clipboard"
    private let rioActionsEnabledStorageKey = "rio_actions_enabled"
    private let preserveExactWordingStorageKey = "preserve_exact_wording"
    private let keepDictationInClipboardHistoryStorageKey = "keep_dictation_in_clipboard_history"
    private let learnFromCorrectionsStorageKey = "learn_from_corrections"
    private let pressEnterVoiceCommandStorageKey = "press_enter_voice_command_enabled"
    private let alertSoundsEnabledStorageKey = "alert_sounds_enabled"
    private let soundVolumeStorageKey = "sound_volume"
    private let voiceMacrosStorageKey = "voice_macros"
    private let commandModeEnabledStorageKey = "command_mode_enabled"
    private let commandModeStyleStorageKey = "command_mode_style"
    private let commandModeManualModifierStorageKey = "command_mode_manual_modifier"
    private let outputLanguageStorageKey = "output_language"
    private let realtimeStreamingEnabledStorageKey = "realtime_streaming_enabled"
    private let realtimeStreamingModelStorageKey = "realtime_streaming_model"
    private let dictationAudioInterruptionEnabledStorageKey = "dictation_audio_interruption_enabled"
    private let pasteAfterShortcutReleaseDelay: TimeInterval = 0.03
    private let pressEnterAfterPasteDelay: TimeInterval = 0.08
    private let clipboardRestoreDelay: TimeInterval = 1.0
    let maxPipelineHistoryCount = 20
    static let defaultContextScreenshotMaxDimension = Int(AppContextService.defaultScreenshotMaxDimension)
    static let contextScreenshotDimensionOptions = [1024, 768, 640, 512]
    static let defaultTranscriptionModel = "whisper-large-v3"
    static let transcriptionLanguageOptions: [(code: String, name: String)] = [
        ("", "Auto-detect"),
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("ru", "Russian"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("zh", "Chinese"),
        ("ar", "Arabic"),
        ("hi", "Hindi"),
        ("tr", "Turkish"),
        ("pl", "Polish"),
        ("uk", "Ukrainian"),
        ("sv", "Swedish"),
        ("no", "Norwegian"),
        ("da", "Danish"),
        ("fi", "Finnish"),
        ("cs", "Czech"),
        ("el", "Greek"),
        ("he", "Hebrew"),
        ("vi", "Vietnamese"),
        ("th", "Thai"),
        ("id", "Indonesian"),
        ("ro", "Romanian"),
        ("hu", "Hungarian"),
        ("ca", "Catalan")
    ]
    static let defaultPostProcessingModel = "openai/gpt-oss-20b"
    static let defaultPostProcessingFallbackModel = "qwen/qwen3.8-27b"
    static let defaultContextModel = "qwen/qwen3.8-27b"
    private static let deprecatedDefaultPostProcessingFallbackModel = "meta-llama/llama-4-scout-17b-16e-instruct"
    private static let deprecatedDefaultContextModel = "meta-llama/llama-4-scout-17b-16e-instruct"
    private static let trailingPressEnterCommandPattern = try! NSRegularExpression(
        pattern: #"(?i)(?:^|[ \t\r\n,;:\-]+)press[ \t\r\n]+enter[\s\p{P}]*$"#
    )

    @Published var hasCompletedSetup: Bool {
        didSet {
            UserDefaults.standard.set(hasCompletedSetup, forKey: "hasCompletedSetup")
        }
    }

    @Published var apiKey: String {
        didSet {
            guard !isApplyingAPIConfiguration else { return }
            persistAPIKey(apiKey)
            rebuildContextService()
        }
    }

    @Published var apiBaseURL: String {
        didSet {
            guard !isApplyingAPIConfiguration else { return }
            persistAPIBaseURL(apiBaseURL)
            rebuildContextService()
        }
    }

    @Published var transcriptionAPIURL: String {
        didSet {
            guard !isApplyingAPIConfiguration else { return }
            persistOptionalAPIValue(transcriptionAPIURL, account: transcriptionAPIURLStorageKey)
        }
    }

    @Published var transcriptionAPIKey: String {
        didSet {
            guard !isApplyingAPIConfiguration else { return }
            persistOptionalAPIValue(transcriptionAPIKey, account: transcriptionAPIKeyStorageKey)
        }
    }

    // Publish only after the complete configuration transaction has persisted.
    @Published private(set) var committedAPIConfiguration: ValidatedAPIConfiguration

    @Published var transcriptionModel: String {
        didSet {
            UserDefaults.standard.set(transcriptionModel, forKey: transcriptionModelStorageKey)
        }
    }

    @Published var postProcessingModel: String {
        didSet {
            UserDefaults.standard.set(postProcessingModel, forKey: postProcessingModelStorageKey)
        }
    }

    @Published var postProcessingFallbackModel: String {
        didSet {
            UserDefaults.standard.set(postProcessingFallbackModel, forKey: postProcessingFallbackModelStorageKey)
        }
    }

    @Published var contextModel: String {
        didSet {
            UserDefaults.standard.set(contextModel, forKey: contextModelStorageKey)
            rebuildContextService()
        }
    }

    @Published var holdShortcut: ShortcutBinding {
        didSet {
            persistShortcut(holdShortcut, key: holdShortcutStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published var toggleShortcut: ShortcutBinding {
        didSet {
            persistShortcut(toggleShortcut, key: toggleShortcutStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published var copyAgainShortcut: ShortcutBinding {
        didSet {
            persistShortcut(copyAgainShortcut, key: copyAgainShortcutStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published private(set) var savedHoldCustomShortcut: ShortcutBinding? {
        didSet {
            persistOptionalShortcut(savedHoldCustomShortcut, key: savedHoldCustomShortcutStorageKey)
        }
    }

    @Published private(set) var savedToggleCustomShortcut: ShortcutBinding? {
        didSet {
            persistOptionalShortcut(savedToggleCustomShortcut, key: savedToggleCustomShortcutStorageKey)
        }
    }

    @Published private(set) var savedCopyAgainCustomShortcut: ShortcutBinding? {
        didSet {
            persistOptionalShortcut(savedCopyAgainCustomShortcut, key: savedCopyAgainCustomShortcutStorageKey)
        }
    }

    @Published var undoLastShortcut: ShortcutBinding {
        didSet {
            persistShortcut(undoLastShortcut, key: undoLastShortcutStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published private(set) var savedUndoLastCustomShortcut: ShortcutBinding? {
        didSet {
            persistOptionalShortcut(savedUndoLastCustomShortcut, key: savedUndoLastCustomShortcutStorageKey)
        }
    }

    @Published var fixLastShortcut: ShortcutBinding {
        didSet {
            persistShortcut(fixLastShortcut, key: fixLastShortcutStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published private(set) var savedFixLastCustomShortcut: ShortcutBinding? {
        didSet {
            persistOptionalShortcut(savedFixLastCustomShortcut, key: savedFixLastCustomShortcutStorageKey)
        }
    }

    @Published var isCommandModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isCommandModeEnabled, forKey: commandModeEnabledStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published var commandModeStyle: CommandModeStyle {
        didSet {
            UserDefaults.standard.set(commandModeStyle.rawValue, forKey: commandModeStyleStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published private(set) var commandModeManualModifier: CommandModeManualModifier {
        didSet {
            UserDefaults.standard.set(commandModeManualModifier.rawValue, forKey: commandModeManualModifierStorageKey)
            restartHotkeyMonitoring()
        }
    }

    @Published var customVocabulary: String {
        didSet {
            UserDefaults.standard.set(customVocabulary, forKey: customVocabularyStorageKey)
        }
    }

    @Published var transcriptionLanguage: String {
        didSet {
            let normalized = Self.normalizeTranscriptionLanguage(transcriptionLanguage)
            if normalized != transcriptionLanguage {
                transcriptionLanguage = normalized
                return
            }
            UserDefaults.standard.set(normalized, forKey: transcriptionLanguageStorageKey)
        }
    }

    @Published var customSystemPrompt: String {
        didSet {
            UserDefaults.standard.set(customSystemPrompt, forKey: customSystemPromptStorageKey)
        }
    }

    @Published var customContextPrompt: String {
        didSet {
            UserDefaults.standard.set(customContextPrompt, forKey: customContextPromptStorageKey)
            rebuildContextService()
        }
    }

    @Published var contextCaptureEnabled: Bool {
        didSet {
            UserDefaults.standard.set(contextCaptureEnabled, forKey: contextCaptureEnabledStorageKey)
            if !contextCaptureEnabled {
                contextCaptureGeneration = UUID()
                contextCaptureTask?.cancel()
                contextCaptureTask = nil
                capturedContext = nil
            }
        }
    }

    @Published var instructionExecutionGuardEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                instructionExecutionGuardEnabled,
                forKey: instructionExecutionGuardEnabledStorageKey
            )
        }
    }

    @Published var desktopScreenshotFallbackEnabled: Bool {
        didSet {
            DesktopScreenshotFallbackPreference.save(desktopScreenshotFallbackEnabled, to: .standard)
            rebuildContextService()
        }
    }

    @Published var contextScreenshotMaxDimension: Int {
        didSet {
            let normalizedDimension = Self.normalizedContextScreenshotMaxDimension(contextScreenshotMaxDimension)
            if normalizedDimension != contextScreenshotMaxDimension {
                contextScreenshotMaxDimension = normalizedDimension
            }
            UserDefaults.standard.set(contextScreenshotMaxDimension, forKey: contextScreenshotMaxDimensionStorageKey)
            rebuildContextService()
        }
    }

    @Published var customSystemPromptLastModified: String {
        didSet {
            UserDefaults.standard.set(customSystemPromptLastModified, forKey: customSystemPromptLastModifiedStorageKey)
        }
    }

    @Published var customContextPromptLastModified: String {
        didSet {
            UserDefaults.standard.set(customContextPromptLastModified, forKey: customContextPromptLastModifiedStorageKey)
        }
    }

    @Published var outputLanguage: String {
        didSet {
            UserDefaults.standard.set(outputLanguage, forKey: outputLanguageStorageKey)
        }
    }

    @Published var shortcutStartDelay: TimeInterval {
        didSet {
            UserDefaults.standard.set(shortcutStartDelay, forKey: shortcutStartDelayStorageKey)
        }
    }

    /// Stream audio to the transcription backend during recording via the
    /// OpenAI Realtime WebSocket. Reduces wall-clock latency between "stop"
    /// and text-ready because most of the transcription work happens while
    /// the user is still speaking.
    @Published var realtimeStreamingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(realtimeStreamingEnabled, forKey: realtimeStreamingEnabledStorageKey)
        }
    }

    /// Model ID the realtime WebSocket should transcribe with. Empty means
    /// "use the server's default".
    @Published var realtimeStreamingModel: String {
        didSet {
            UserDefaults.standard.set(realtimeStreamingModel, forKey: realtimeStreamingModelStorageKey)
        }
    }

    @Published var dictationAudioInterruptionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                dictationAudioInterruptionEnabled,
                forKey: dictationAudioInterruptionEnabledStorageKey
            )
        }
    }

    @Published var originalFieldInsertionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(originalFieldInsertionEnabled, forKey: OriginalFieldInsertionPreference.storageKey)
            updateInsertionAccessibilityPreparation()
        }
    }

    /// Fn + Control runs a spoken command instead of dictating. Fn alone is still dictation.
    @Published var rioActionsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(rioActionsEnabled, forKey: rioActionsEnabledStorageKey)
            guard oldValue != rioActionsEnabled else { return }
            restartHotkeyMonitoring()
        }
    }

    /// "Trust conversation mode" (default ON, owner decision): when OFF, conversation-sourced
    /// commands that inject input or change state need a spoken "yes" or Return first.
    @Published var rioTrustConversationMode: Bool = UserDefaults.standard.object(forKey: RioTrustSetting.key) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(rioTrustConversationMode, forKey: RioTrustSetting.key)
        }
    }

    /// What the corner bear shows for the action key; the overlay only observes it.
    @Published var rioActionPhase: RioActionPhase = .idle
    // Corner bear state, mirrored from RioVoice / RioCompanionCenter by bindRioCompanionState().
    /// Kept for source compatibility but no longer updated: the bear reads RioVoice's 30 Hz level
    /// directly, so AppState observers are not re-rendered 30 times a second while Rio speaks.
    private var rioCompanionStateSubscriptions: Set<AnyCancellable> = []
    private var rioConversationResumeWork: DispatchWorkItem?
    /// Held while it plays: a sound made from data stops if it is freed mid-play.
    private var rioChimeSound: NSSound?

    @Published var preserveClipboard: Bool {
        didSet {
            UserDefaults.standard.set(preserveClipboard, forKey: preserveClipboardStorageKey)
        }
    }

    @Published var preserveExactWording: Bool {
        didSet {
            UserDefaults.standard.set(preserveExactWording, forKey: preserveExactWordingStorageKey)
        }
    }

    @Published var keepDictationInClipboardHistory: Bool {
        didSet {
            UserDefaults.standard.set(keepDictationInClipboardHistory, forKey: keepDictationInClipboardHistoryStorageKey)
        }
    }

    /// Watches dictated text briefly after paste and adds the user's spelling fixes to vocabulary.
    @Published var learnFromCorrectionsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(learnFromCorrectionsEnabled, forKey: learnFromCorrectionsStorageKey)
            if !learnFromCorrectionsEnabled { correctionWatcher.cancel() }
        }
    }

    private(set) lazy var correctionWatcher = CorrectionWatcher(
        onLearned: { [weak self] corrections in self?.learnVocabulary(from: corrections) },
        isVocabularyTerm: { [weak self] term in self?.isCustomVocabularyTerm(term) ?? false },
        onUnwatchable: { [weak self] appName in self?.explainUnwatchableApp(appName) }
    )
    /// Set while a new dictation starts, so the previous edit's sign waits for that dictation to
    /// close instead of being wiped by it.
    var isDeferringLearnFeedback = false
    var deferredLearnMoment = DeferredMoment()
    var unwatchableAppNotices = UnwatchableAppNotices()

    // MARK: Dictionary, styles, whisper mode and stats (logic in AppState+Enhancements.swift)

    /// "When I hear X, write Y" rules applied to every dictation.
    @Published var wordReplacements: [WordReplacement] =
        AppState.loadStoredJSON(forKey: AppState.wordReplacementsStorageKey) ?? [] {
        didSet { Self.storeJSON(wordReplacements, forKey: Self.wordReplacementsStorageKey) }
    }

    /// Tone per app category; categories not listed use `.standard`.
    @Published var dictationStyles: [DictationStyleCategory: DictationStyle] = AppState.loadDictationStyles() {
        didSet { Self.storeDictationStyles(dictationStyles) }
    }

    /// Boosts quiet recordings before transcription.
    @Published var whisperModeEnabled: Bool = UserDefaults.standard.bool(forKey: AppState.whisperModeStorageKey) {
        didSet { UserDefaults.standard.set(whisperModeEnabled, forKey: Self.whisperModeStorageKey) }
    }

    /// Hands-free: seconds of silence that end a tap-to-toggle recording; 0 turns it off.
    @Published var handsFreeAutoStopDelay: TimeInterval = AppState.loadHandsFreeAutoStopDelay() {
        didSet { UserDefaults.standard.set(handsFreeAutoStopDelay, forKey: Self.handsFreeAutoStopDelayStorageKey) }
    }

    /// Adds names from the app-context summary to that dictation's speech-to-text vocabulary.
    @Published var screenNamesVocabularyEnabled: Bool =
        UserDefaults.standard.object(forKey: AppState.screenNamesVocabularyStorageKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(screenNamesVocabularyEnabled, forKey: Self.screenNamesVocabularyStorageKey) }
    }

    /// Where the last dictation landed, for Undo Last Dictation. Memory only.
    var lastDictationInsertion: DictationUndo.Insertion?
    /// Identifies the newest insertion being looked for, so an older lookup can't overwrite it.
    var undoLookupToken = UUID()
    /// Watches the current tap-to-toggle recording for trailing silence.
    var silenceAutoStop: SilenceAutoStop?

    /// Per-day word, time and session counts. Never holds dictated text.
    @Published var usageDays: [String: DailyUsage] =
        AppState.loadStoredJSON(forKey: AppState.usageStatsStorageKey) ?? [:] {
        didSet { Self.storeJSON(usageDays, forKey: Self.usageStatsStorageKey) }
    }

    /// Whether `recordUsage` keeps counting. Existing counts stay until reset.
    @Published var usageStatsEnabled: Bool = AppState.loadUsageStatsEnabled() {
        didSet { UserDefaults.standard.set(usageStatsEnabled, forKey: Self.usageStatsEnabledStorageKey) }
    }

    private var recordingStartedAt: Date?
    private var activeStyleCategory: DictationStyleCategory = .other
    /// What the bear wears for the current dictation, from the app's writing style.
    private var teddyOutfit: TeddyOutfit = .hoodie
    /// Language look of the last dictation, so the next one starts in it (the transcript is
    /// only known after you stop). Main thread only.
    private var lastSpokenLook: SpokenLook = .none

    @Published var isPressEnterVoiceCommandEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isPressEnterVoiceCommandEnabled, forKey: pressEnterVoiceCommandStorageKey)
        }
    }

    @Published var alertSoundsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(alertSoundsEnabled, forKey: alertSoundsEnabledStorageKey)
        }
    }

    @Published var soundVolume: Float {
        didSet {
            UserDefaults.standard.set(soundVolume, forKey: soundVolumeStorageKey)
        }
    }

    private var precomputedMacros: [PrecomputedMacro] = []

    @Published var voiceMacros: [VoiceMacro] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(voiceMacros) {
                UserDefaults.standard.set(data, forKey: voiceMacrosStorageKey)
            }
            precomputeMacros()
        }
    }

    @Published var isRecording = false {
        didSet {
            guard oldValue != isRecording else { return }
            AppState.writeRecordingStateFlag(isRecording)
        }
    }
    @Published var isTranscribing = false
    @Published var retryingItemIDs: Set<UUID> = []
    @Published var lastTranscript: String = ""
    /// The text last pasted by a dictation. Unlike undo state it is never cleared, so Fix Last Dictation can use it.
    @Published var lastDictatedText = ""
    @Published var errorMessage: String?
    @Published var statusText: String = "Ready"
    @Published var hasAccessibility = false
    @Published var hotkeyMonitoringErrorMessage: String?
    @Published var isDebugOverlayActive = false
    @Published var selectedSettingsTab: SettingsTab? = .general
    @Published var pipelineHistory: [PipelineHistoryItem] = []
    @Published var debugStatusMessage = "Idle"
    @Published var lastRawTranscript = ""
    @Published var lastPostProcessedTranscript = ""
    @Published var lastPostProcessingPrompt = ""
    @Published var lastContextSummary = ""
    @Published var lastPostProcessingStatus = ""
    @Published var lastContextScreenshotDataURL: String? = nil
    @Published var lastContextScreenshotStatus = "No screenshot"
    @Published var lastContextAppName: String = ""
    @Published var lastContextBundleIdentifier: String = ""
    @Published var lastContextWindowTitle: String = ""
    @Published var lastContextSelectedText: String = ""
    @Published var lastContextLLMPrompt: String = ""
    @Published var hasScreenRecordingPermission = false
    /// True once when this launch follows a crash (a marker file was left behind). The corner
    /// bear says sorry and Rio says it aloud.
    @Published var rioRecoveredFromCrash = false
    private var isSyncingLaunchAtLogin = false
    @Published var launchAtLogin: Bool {
        didSet { setLaunchAtLogin(launchAtLogin) }
    }

    @Published var selectedMicrophoneID: String {
        didSet {
            UserDefaults.standard.set(selectedMicrophoneID, forKey: selectedMicrophoneStorageKey)
        }
    }
    @Published var availableMicrophones: [AudioDevice] = []

    let audioRecorder = AudioRecorder()
    let hotkeyManager = HotkeyManager()
    let overlayManager = RecordingOverlayManager()
    private let teddyTrip = TeddyTripController()
    private var accessibilityTimer: Timer?
    private var audioLevelCancellable: AnyCancellable?
    private var debugOverlayTimer: Timer?
    private var recordingInitializationTimer: DispatchSourceTimer?
    private var transcriptionTask: Task<Void, Never>?
    private var transcribingAudioFileName: String?
    private var contextService: AppContextService
    private var contextCaptureGeneration = UUID()
    private var contextCaptureTask: Task<AppContext?, Never>?
    private var capturedContext: AppContext?
    private var hasShownScreenshotPermissionAlert = false
    private var audioDeviceObservers: [NSObjectProtocol] = []
    private var needsMicrophoneRefreshAfterRecording = false
    private let pipelineHistoryStore = PipelineHistoryStore()
    private let shortcutSessionController = DictationShortcutSessionController()
    private var activeRecordingTriggerMode: RecordingTriggerMode?
    private var activeTextInsertionTarget: AppTextInsertionTarget?
    private var insertionAccessibilityCancellable: AnyCancellable?
    private let insertionAccessibilityQueue = DispatchQueue(label: "FreeFlow.insertion-accessibility", qos: .utility)
    private var activeOriginalFieldInsertionEnabled = false
    private var textInsertionTargetID: UUID?
    private var currentSessionIntent: SessionIntent = .dictation
    private var pendingSelectionSnapshot: AppSelectionSnapshot?
    private var pendingManualCommandInvocation = false
    /// Control was pressed during the current Fn hold: this session is a Rio action, not dictation.
    private var rioActionSessionRequested = false
    private var rioActionPhaseToken = UUID()
    private var rioActionCoordinator: RioActionCoordinator?
    /// One Rio command at a time, whichever way it was started (action key or conversation).
    private var isRioCommandRunning = false
    /// Automation and phone commands that arrived while Rio was busy; they run, in order, once idle.
    private var rioWaitingCommands = RioWaitingCommands<RioWaitingCommand>()
    private var rioWaitingCommandsDrain: DispatchWorkItem?
    /// A waiting command was taken off the line and is about to start.
    private var isStartingWaitingRioCommand = false
    /// The action key stops a running multi-step task, but only once the hold is known not to be
    /// the start of the conversation chord.
    private var rioPendingTaskStop: DispatchWorkItem?
    private var pendingShortcutStartTask: Task<Void, Never>?
    private var pendingShortcutStartMode: RecordingTriggerMode?
    private var realtimeService: RealtimeTranscriptionService?
    /// Live language check for the current dictation (Rio's outfit), nil when off.
    private var languageProbe: LanguageProbeService?
    private var automaticTerminationDisabled = false
    private var activeAudioInterruption: ActiveAudioInterruption?
    private var pendingOverlayDismissToken: UUID?
    private var shouldMonitorHotkeys = false
    private var isCapturingShortcut = false
    private var isAwaitingMicrophonePermission = false
    private var pendingMicrophonePermissionTriggerMode: RecordingTriggerMode?
    private var pendingMicrophonePermissionSelectionSnapshot: AppSelectionSnapshot?
    private var pendingMicrophonePermissionManualCommandRequested: Bool?
    private var isApplyingAPIConfiguration = false

    init() {
        UserDefaults.standard.removeObject(forKey: "force_http2_transcription")
        let hasCompletedSetup = UserDefaults.standard.bool(forKey: "hasCompletedSetup")
        let apiKey = Self.loadStoredAPIKey(account: apiKeyStorageKey)
        let apiBaseURL = Self.loadStoredAPIBaseURL(account: "api_base_url")
        for key in [contextModelStorageKey, postProcessingModelStorageKey, postProcessingFallbackModelStorageKey] {
            ModelConfiguration.migrateGroqSelection(key: key, baseURL: apiBaseURL, defaults: .standard)
        }
        let transcriptionModel = UserDefaults.standard.string(forKey: transcriptionModelStorageKey) ?? Self.defaultTranscriptionModel
        let transcriptionAPIURL = Self.loadOptionalStoredAPIValue(account: transcriptionAPIURLStorageKey)
        let transcriptionAPIKey = Self.loadStoredAPIKey(account: transcriptionAPIKeyStorageKey)
        let postProcessingModel = UserDefaults.standard.string(forKey: postProcessingModelStorageKey) ?? Self.defaultPostProcessingModel
        let postProcessingFallbackModel = Self.loadStoredPostProcessingFallbackModel(
            key: postProcessingFallbackModelStorageKey
        )
        let contextModel = Self.loadStoredContextModel(key: contextModelStorageKey)
        let shortcuts = Self.loadShortcutConfiguration(
            holdKey: holdShortcutStorageKey,
            toggleKey: toggleShortcutStorageKey,
            copyAgainKey: copyAgainShortcutStorageKey
        )
        let savedHoldCustomShortcut = Self.loadSavedCustomShortcut(
            forKey: savedHoldCustomShortcutStorageKey,
            fallback: shortcuts.hold.isCustom ? shortcuts.hold : nil
        )
        let savedToggleCustomShortcut = Self.loadSavedCustomShortcut(
            forKey: savedToggleCustomShortcutStorageKey,
            fallback: shortcuts.toggle.isCustom ? shortcuts.toggle : nil
        )
        let savedCopyAgainCustomShortcut = Self.loadSavedCustomShortcut(
            forKey: savedCopyAgainCustomShortcutStorageKey,
            fallback: shortcuts.copyAgain.isCustom ? shortcuts.copyAgain : nil
        )
        let storedUndoLast = Self.loadShortcut(forKey: undoLastShortcutStorageKey)
        let undoLastShortcut = storedUndoLast.binding ?? .disabled
        let savedUndoLastCustomShortcut = Self.loadSavedCustomShortcut(
            forKey: savedUndoLastCustomShortcutStorageKey,
            fallback: undoLastShortcut.isCustom ? undoLastShortcut : nil
        )
        let fixLastShortcut = Self.loadShortcut(forKey: fixLastShortcutStorageKey).binding ?? .defaultFixLast
        let savedFixLastCustomShortcut = Self.loadSavedCustomShortcut(
            forKey: savedFixLastCustomShortcutStorageKey,
            fallback: fixLastShortcut.isCustom ? fixLastShortcut : nil
        )
        let customVocabulary = UserDefaults.standard.string(forKey: customVocabularyStorageKey) ?? ""
        let transcriptionLanguage = Self.normalizeTranscriptionLanguage(
            UserDefaults.standard.string(forKey: transcriptionLanguageStorageKey) ?? ""
        )
        let customSystemPrompt = UserDefaults.standard.string(forKey: customSystemPromptStorageKey) ?? ""
        let customContextPrompt = UserDefaults.standard.string(forKey: customContextPromptStorageKey) ?? ""
        let contextCaptureEnabled = UserDefaults.standard.object(forKey: contextCaptureEnabledStorageKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: contextCaptureEnabledStorageKey)
        let instructionExecutionGuardEnabled = UserDefaults.standard.object(
            forKey: instructionExecutionGuardEnabledStorageKey
        ) == nil
            ? true
            : UserDefaults.standard.bool(forKey: instructionExecutionGuardEnabledStorageKey)
        let customSystemPromptLastModified = UserDefaults.standard.string(forKey: customSystemPromptLastModifiedStorageKey) ?? ""
        let customContextPromptLastModified = UserDefaults.standard.string(forKey: customContextPromptLastModifiedStorageKey) ?? ""
        let outputLanguage = UserDefaults.standard.string(forKey: outputLanguageStorageKey) ?? ""
        let storedContextScreenshotMaxDimension = UserDefaults.standard.object(forKey: contextScreenshotMaxDimensionStorageKey) != nil
            ? UserDefaults.standard.integer(forKey: contextScreenshotMaxDimensionStorageKey)
            : Self.defaultContextScreenshotMaxDimension
        let desktopScreenshotFallbackEnabled = DesktopScreenshotFallbackPreference.load(from: .standard)
        let contextScreenshotMaxDimension = Self.normalizedContextScreenshotMaxDimension(storedContextScreenshotMaxDimension)
        let shortcutStartDelay = max(0, UserDefaults.standard.double(forKey: shortcutStartDelayStorageKey))
        let isCommandModeEnabled = UserDefaults.standard.object(forKey: commandModeEnabledStorageKey) == nil
            ? false
            : UserDefaults.standard.bool(forKey: commandModeEnabledStorageKey)
        let commandModeStyle = CommandModeStyle(
            rawValue: UserDefaults.standard.string(forKey: commandModeStyleStorageKey) ?? ""
        ) ?? .automatic
        let commandModeManualModifier = CommandModeManualModifier(
            rawValue: UserDefaults.standard.string(forKey: commandModeManualModifierStorageKey) ?? ""
        ) ?? .option
        let rioActionsEnabled = UserDefaults.standard.object(forKey: rioActionsEnabledStorageKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: rioActionsEnabledStorageKey)
        let preserveClipboard = UserDefaults.standard.object(forKey: preserveClipboardStorageKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: preserveClipboardStorageKey)
        let preserveExactWording = UserDefaults.standard.bool(forKey: preserveExactWordingStorageKey)
        let keepDictationInClipboardHistory = UserDefaults.standard.bool(forKey: keepDictationInClipboardHistoryStorageKey)
        let learnFromCorrectionsEnabled = UserDefaults.standard.object(forKey: learnFromCorrectionsStorageKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: learnFromCorrectionsStorageKey)
        let realtimeStreamingEnabled = UserDefaults.standard.bool(forKey: realtimeStreamingEnabledStorageKey)
        let realtimeStreamingModel = UserDefaults.standard.string(forKey: realtimeStreamingModelStorageKey) ?? ""
        let dictationAudioInterruptionEnabled = UserDefaults.standard.bool(
            forKey: dictationAudioInterruptionEnabledStorageKey
        )
        let isPressEnterVoiceCommandEnabled = UserDefaults.standard.object(forKey: pressEnterVoiceCommandStorageKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: pressEnterVoiceCommandStorageKey)
        let soundVolume: Float = UserDefaults.standard.object(forKey: soundVolumeStorageKey) != nil
            ? UserDefaults.standard.float(forKey: soundVolumeStorageKey) : 1.0
        let alertSoundsEnabled = UserDefaults.standard.object(forKey: alertSoundsEnabledStorageKey) != nil
            ? UserDefaults.standard.bool(forKey: alertSoundsEnabledStorageKey)
            : soundVolume > 0
        
        let initialMacros: [VoiceMacro]
        if let data = UserDefaults.standard.data(forKey: "voice_macros"),
           let decoded = try? JSONDecoder().decode([VoiceMacro].self, from: data) {
            initialMacros = decoded
        } else {
            initialMacros = []
        }

        let initialAccessibility = AXIsProcessTrusted()
        let initialScreenCapturePermission = CGPreflightScreenCaptureAccess()
        var removedAudioFileNames: [String] = []
        do {
            removedAudioFileNames = try pipelineHistoryStore.trim(to: maxPipelineHistoryCount)
        } catch {
            print("Failed to trim pipeline history during init: \(error)")
        }
        for audioFileName in removedAudioFileNames {
            Self.deleteAudioFile(audioFileName)
        }
        let savedHistory = pipelineHistoryStore.loadAllHistory()

        let selectedMicrophoneID = UserDefaults.standard.string(forKey: selectedMicrophoneStorageKey) ?? "default"

        self.contextService = Self.makeAppContextService(
            apiKey: apiKey,
            baseURL: apiBaseURL,
            customContextPrompt: customContextPrompt,
            contextModel: contextModel,
            contextScreenshotMaxDimension: contextScreenshotMaxDimension,
            desktopScreenshotFallbackEnabled: desktopScreenshotFallbackEnabled
        )
        self.hasCompletedSetup = hasCompletedSetup
        self.apiKey = apiKey
        self.apiBaseURL = apiBaseURL
        self.transcriptionAPIURL = transcriptionAPIURL
        self.transcriptionAPIKey = transcriptionAPIKey
        self.committedAPIConfiguration = ValidatedAPIConfiguration(
            apiKey: apiKey,
            baseURL: apiBaseURL,
            transcriptionAPIURL: transcriptionAPIURL,
            transcriptionAPIKey: transcriptionAPIKey
        )
        self.transcriptionModel = transcriptionModel
        self.postProcessingModel = postProcessingModel
        self.postProcessingFallbackModel = postProcessingFallbackModel
        self.contextModel = contextModel
        self.holdShortcut = shortcuts.hold
        self.toggleShortcut = shortcuts.toggle
        self.copyAgainShortcut = shortcuts.copyAgain
        self.savedHoldCustomShortcut = savedHoldCustomShortcut.binding
        self.savedToggleCustomShortcut = savedToggleCustomShortcut.binding
        self.savedCopyAgainCustomShortcut = savedCopyAgainCustomShortcut.binding
        self.undoLastShortcut = undoLastShortcut
        self.savedUndoLastCustomShortcut = savedUndoLastCustomShortcut.binding
        self.fixLastShortcut = fixLastShortcut
        self.savedFixLastCustomShortcut = savedFixLastCustomShortcut.binding
        self.isCommandModeEnabled = isCommandModeEnabled
        self.commandModeStyle = commandModeStyle
        self.commandModeManualModifier = commandModeManualModifier
        self.customVocabulary = customVocabulary
        self.transcriptionLanguage = transcriptionLanguage
        self.customSystemPrompt = customSystemPrompt
        self.customContextPrompt = customContextPrompt
        self.contextCaptureEnabled = contextCaptureEnabled
        self.instructionExecutionGuardEnabled = instructionExecutionGuardEnabled
        self.desktopScreenshotFallbackEnabled = desktopScreenshotFallbackEnabled
        self.contextScreenshotMaxDimension = contextScreenshotMaxDimension
        self.customSystemPromptLastModified = customSystemPromptLastModified
        self.customContextPromptLastModified = customContextPromptLastModified
        self.outputLanguage = outputLanguage
        self.shortcutStartDelay = shortcutStartDelay
        self.originalFieldInsertionEnabled = OriginalFieldInsertionPreference.load(from: .standard)
        self.rioActionsEnabled = rioActionsEnabled
        self.preserveClipboard = preserveClipboard
        self.preserveExactWording = preserveExactWording
        self.keepDictationInClipboardHistory = keepDictationInClipboardHistory
        self.learnFromCorrectionsEnabled = learnFromCorrectionsEnabled
        self.realtimeStreamingEnabled = realtimeStreamingEnabled
        self.realtimeStreamingModel = realtimeStreamingModel
        self.dictationAudioInterruptionEnabled = dictationAudioInterruptionEnabled
        self.isPressEnterVoiceCommandEnabled = isPressEnterVoiceCommandEnabled
        self.alertSoundsEnabled = alertSoundsEnabled
        self.soundVolume = soundVolume
        self.voiceMacros = initialMacros
        self.pipelineHistory = savedHistory
        self.hasAccessibility = initialAccessibility
        self.hasScreenRecordingPermission = initialScreenCapturePermission
        self.launchAtLogin = RioLaunchAtLogin.isEnabled
        self.selectedMicrophoneID = selectedMicrophoneID
        self.precomputeMacros()

        refreshAvailableMicrophones()
        installAudioDeviceObservers()

        if shortcuts.didUpdateHoldStoredValue {
            persistShortcut(shortcuts.hold, key: holdShortcutStorageKey)
        }
        if shortcuts.didUpdateToggleStoredValue {
            persistShortcut(shortcuts.toggle, key: toggleShortcutStorageKey)
        }
        if shortcuts.didUpdateCopyAgainStoredValue {
            persistShortcut(shortcuts.copyAgain, key: copyAgainShortcutStorageKey)
        }
        if savedHoldCustomShortcut.didUpdateStoredValue {
            persistOptionalShortcut(savedHoldCustomShortcut.binding, key: savedHoldCustomShortcutStorageKey)
        }
        if savedToggleCustomShortcut.didUpdateStoredValue {
            persistOptionalShortcut(savedToggleCustomShortcut.binding, key: savedToggleCustomShortcutStorageKey)
        }
        if savedCopyAgainCustomShortcut.didUpdateStoredValue {
            persistOptionalShortcut(savedCopyAgainCustomShortcut.binding, key: savedCopyAgainCustomShortcutStorageKey)
        }
        if storedUndoLast.didNormalize {
            persistShortcut(undoLastShortcut, key: undoLastShortcutStorageKey)
        }
        if savedUndoLastCustomShortcut.didUpdateStoredValue {
            persistOptionalShortcut(savedUndoLastCustomShortcut.binding, key: savedUndoLastCustomShortcutStorageKey)
        }

        overlayManager.onStopButtonPressed = { [weak self] in
            DispatchQueue.main.async {
                self?.handleOverlayStopButtonPressed()
            }
        }

        // Clear any stale recording flag left over from an unclean exit.
        AppState.writeRecordingStateFlag(false)
    }

    deinit {
        removeAudioDeviceObservers()
        AppState.writeRecordingStateFlag(false)
    }

    private func removeAudioDeviceObservers() {
        let notificationCenter = NotificationCenter.default
        for observer in audioDeviceObservers {
            notificationCenter.removeObserver(observer)
        }
        audioDeviceObservers.removeAll()
    }

    private static func loadStoredAPIKey(account: String) -> String {
        if let storedKey = AppSettingsStorage.load(account: account), !storedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return storedKey
        }
        return ""
    }

    private func persistAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            AppSettingsStorage.delete(account: apiKeyStorageKey)
        } else {
            AppSettingsStorage.save(trimmed, account: apiKeyStorageKey)
        }
    }

    static let defaultAPIBaseURL = APIConfigurationSaveFlow.defaultBaseURL

    private struct StoredShortcutConfiguration {
        let hold: ShortcutBinding
        let toggle: ShortcutBinding
        let copyAgain: ShortcutBinding
        let didUpdateHoldStoredValue: Bool
        let didUpdateToggleStoredValue: Bool
        let didUpdateCopyAgainStoredValue: Bool
    }

    private struct StoredOptionalShortcut {
        let binding: ShortcutBinding?
        let didUpdateStoredValue: Bool
    }

    private struct StoredShortcutLoadResult {
        let binding: ShortcutBinding?
        let hadStoredValue: Bool
        let didNormalize: Bool
    }

    private static func loadStoredAPIBaseURL(account: String) -> String {
        if let stored = AppSettingsStorage.load(account: account), !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stored
        }
        return defaultAPIBaseURL
    }

    private static func loadStoredContextModel(key: String) -> String {
        guard let stored = UserDefaults.standard.string(forKey: key) else {
            return defaultContextModel
        }

        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == deprecatedDefaultContextModel {
            UserDefaults.standard.set(defaultContextModel, forKey: key)
            return defaultContextModel
        }

        return trimmed.isEmpty ? defaultContextModel : trimmed
    }

    private static func loadStoredPostProcessingFallbackModel(key: String) -> String {
        guard let stored = UserDefaults.standard.string(forKey: key) else {
            return defaultPostProcessingFallbackModel
        }

        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == deprecatedDefaultPostProcessingFallbackModel {
            UserDefaults.standard.set(defaultPostProcessingFallbackModel, forKey: key)
            return defaultPostProcessingFallbackModel
        }

        return trimmed.isEmpty ? defaultPostProcessingFallbackModel : trimmed
    }

    private static func loadShortcutConfiguration(
        holdKey: String,
        toggleKey: String,
        copyAgainKey: String
    ) -> StoredShortcutConfiguration {
        let legacyPreset = ShortcutPreset(
            rawValue: UserDefaults.standard.string(forKey: "hotkey_option") ?? ShortcutPreset.fnKey.rawValue
        ) ?? .fnKey
        let hold = legacyPreset.binding
        // Hands-free dictation is an Fn double-tap now (Right Option and Fn + Command are retired
        // as defaults); a saved bare Right Option is migrated below.
        let toggle = ShortcutBinding.defaultToggle
        let storedHold = loadShortcut(forKey: holdKey)
        var storedToggle = loadShortcut(forKey: toggleKey)
        if let saved = storedToggle.binding {
            let migrated = saved.migratedToggleShortcut()
            if migrated != saved {
                storedToggle = StoredShortcutLoadResult(binding: migrated, hadStoredValue: true, didNormalize: true)
            }
        }
        let storedCopyAgain = loadShortcut(forKey: copyAgainKey)
        return StoredShortcutConfiguration(
            hold: storedHold.binding ?? hold,
            toggle: storedToggle.binding ?? toggle,
            copyAgain: storedCopyAgain.binding ?? .disabled,
            didUpdateHoldStoredValue: storedHold.binding == nil || storedHold.didNormalize,
            didUpdateToggleStoredValue: storedToggle.binding == nil || storedToggle.didNormalize,
            didUpdateCopyAgainStoredValue: storedCopyAgain.didNormalize
        )
    }

    private static func loadShortcut(forKey key: String) -> StoredShortcutLoadResult {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return StoredShortcutLoadResult(binding: nil, hadStoredValue: false, didNormalize: false)
        }
        guard let decoded = try? JSONDecoder().decode(ShortcutBinding.self, from: data) else {
            return StoredShortcutLoadResult(binding: nil, hadStoredValue: true, didNormalize: false)
        }
        let normalized = decoded.normalizedForStorageMigration()
        return StoredShortcutLoadResult(
            binding: normalized,
            hadStoredValue: true,
            didNormalize: normalized != decoded
        )
    }

    private static func loadSavedCustomShortcut(
        forKey key: String,
        fallback: ShortcutBinding?
    ) -> StoredOptionalShortcut {
        let stored = loadShortcut(forKey: key)
        if let binding = stored.binding {
            return StoredOptionalShortcut(binding: binding, didUpdateStoredValue: stored.didNormalize)
        }

        return StoredOptionalShortcut(
            binding: fallback,
            didUpdateStoredValue: stored.hadStoredValue || fallback != nil
        )
    }

    static func normalizedContextScreenshotMaxDimension(_ value: Int) -> Int {
        contextScreenshotDimensionOptions.contains(value)
            ? value
            : defaultContextScreenshotMaxDimension
    }

    static func makeAppContextService(
        apiKey: String,
        baseURL: String,
        customContextPrompt: String,
        contextModel: String,
        contextScreenshotMaxDimension: Int,
        desktopScreenshotFallbackEnabled: Bool
    ) -> AppContextService {
        AppContextService(
            apiKey: apiKey,
            baseURL: baseURL,
            customContextPrompt: customContextPrompt,
            contextModel: contextModel,
            screenshotMaxDimension: CGFloat(normalizedContextScreenshotMaxDimension(contextScreenshotMaxDimension)),
            desktopScreenshotFallbackEnabled: desktopScreenshotFallbackEnabled
        )
    }

    func makeAppContextService() -> AppContextService {
        Self.makeAppContextService(
            apiKey: apiKey,
            baseURL: apiBaseURL,
            customContextPrompt: customContextPrompt,
            contextModel: contextModel,
            contextScreenshotMaxDimension: contextScreenshotMaxDimension,
            desktopScreenshotFallbackEnabled: desktopScreenshotFallbackEnabled
        )
    }

    func updateAPIConfiguration(
        apiKey: String,
        baseURL: String,
        transcriptionAPIURL: String,
        transcriptionAPIKey: String
    ) {
        isApplyingAPIConfiguration = true
        self.apiKey = apiKey
        self.apiBaseURL = baseURL
        self.transcriptionAPIURL = transcriptionAPIURL
        self.transcriptionAPIKey = transcriptionAPIKey
        isApplyingAPIConfiguration = false
        persistAPIKey(apiKey)
        persistAPIBaseURL(baseURL)
        persistOptionalAPIValue(transcriptionAPIURL, account: transcriptionAPIURLStorageKey)
        persistOptionalAPIValue(transcriptionAPIKey, account: transcriptionAPIKeyStorageKey)
        rebuildContextService()
        committedAPIConfiguration = ValidatedAPIConfiguration(
            apiKey: apiKey,
            baseURL: baseURL,
            transcriptionAPIURL: transcriptionAPIURL,
            transcriptionAPIKey: transcriptionAPIKey
        )
    }

    private func rebuildContextService() {
        contextService = makeAppContextService()
    }

    private func persistAPIBaseURL(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == Self.defaultAPIBaseURL {
            AppSettingsStorage.delete(account: apiBaseURLStorageKey)
        } else {
            AppSettingsStorage.save(trimmed, account: apiBaseURLStorageKey)
        }
    }

    private func persistOptionalAPIValue(_ value: String, account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            AppSettingsStorage.delete(account: account)
        } else {
            AppSettingsStorage.save(trimmed, account: account)
        }
    }

    private static func loadOptionalStoredAPIValue(account: String) -> String {
        let stored = AppSettingsStorage.load(account: account) ?? ""
        return stored.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// English name of the language selected in Transcription Language, which
    /// cleanup is asked to keep. Empty on Auto-detect: nothing is detected from
    /// the transcript.
    private static func dictationLanguageName(for language: String) -> String {
        let normalized = normalizeTranscriptionLanguage(language)
        guard !normalized.isEmpty else { return "" }
        return transcriptionLanguageOptions.first { $0.code == normalized }?.name ?? ""
    }

    private static func normalizeTranscriptionLanguage(_ language: String) -> String {
        let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard transcriptionLanguageOptions.contains(where: { $0.code == normalized }) else {
            return ""
        }
        return normalized
    }

    private var resolvedTranscriptionBaseURL: String {
        let trimmed = transcriptionAPIURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? apiBaseURL : trimmed
    }

    private var resolvedTranscriptionAPIKey: String {
        let trimmed = transcriptionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? apiKey : trimmed
    }

    /// `contextTerms` are names from the current window, used for this dictation only. Over
    /// budget they win first, then the Dictionary newest-first, so learned words survive.
    func makeTranscriptionService(contextTerms: [String] = []) throws -> TranscriptionService {
        try TranscriptionService(
            apiKey: resolvedTranscriptionAPIKey,
            baseURL: resolvedTranscriptionBaseURL,
            transcriptionModel: transcriptionModel,
            language: resolvedTranscriptionLanguage,
            vocabularyPrompt: TranscriptionRequestCore.vocabularyPrompt(
                vocabulary: Self.vocabularyEntries(in: customVocabulary),
                contextTerms: contextTerms
            )
        )
    }

    private var resolvedTranscriptionLanguage: String? {
        let normalized = Self.normalizeTranscriptionLanguage(transcriptionLanguage)
        return normalized.isEmpty ? nil : normalized
    }

    private func persistShortcut(_ binding: ShortcutBinding, key: String) {
        let normalizedBinding = binding.normalizedForStorageMigration()
        guard let data = try? JSONEncoder().encode(normalizedBinding) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func persistOptionalShortcut(_ binding: ShortcutBinding?, key: String) {
        guard let binding else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        persistShortcut(binding, key: key)
    }

    struct SavedAudioFile {
        let fileName: String
        let fileURL: URL
    }

    static func audioStorageDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appName = AppName.displayName
        let audioDir = appSupport.appendingPathComponent("\(appName)/audio", isDirectory: true)
        if !FileManager.default.fileExists(atPath: audioDir.path) {
            try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        }
        return audioDir
    }

    /// URL of the flag file written while FreeFlow is actively recording.
    ///
    /// External tools (voice assistants, TTS barge-in pipelines, conversation
    /// apps) can poll this file to know when the user is dictating. The file
    /// exists while `isRecording` is true and is removed when it flips false.
    /// Contents are the UNIX timestamp (seconds, float) of when recording
    /// started — useful for stale-flag detection after an unclean exit.
    ///
    /// Path: `~/Library/Application Support/FreeFlow/is-recording`
    /// (or `FreeFlow Dev/is-recording` when running the dev bundle).
    static func recordingStateFlagURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "FreeFlow"
        return appSupport.appendingPathComponent("\(appName)/is-recording")
    }

    /// Serial queue that owns every flag-file I/O so the recording
    /// start/stop hot path never blocks on disk.
    private static let recordingStateFlagQueue = DispatchQueue(
        label: "com.zachlatta.freeflow.recording-state-flag"
    )

    /// Write or clear the `is-recording` flag file. Called from the
    /// `isRecording` didSet. Dispatches to a background queue so disk
    /// I/O never adds latency to recording start/stop. Failures are
    /// swallowed — this is advisory IPC and must never interrupt the
    /// recording pipeline.
    static func writeRecordingStateFlag(_ recording: Bool) {
        let timestamp = recording ? String(Date().timeIntervalSince1970) : nil
        recordingStateFlagQueue.async {
            let url = recordingStateFlagURL()
            if let timestamp {
                let dir = url.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? timestamp.write(to: url, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    static func saveAudioFile(from tempURL: URL) -> SavedAudioFile? {
        let fileName = UUID().uuidString + ".wav"
        let destURL = audioStorageDirectory().appendingPathComponent(fileName)
        do {
            try FileManager.default.copyItem(at: tempURL, to: destURL)
            return SavedAudioFile(fileName: fileName, fileURL: destURL)
        } catch {
            os_log(
                .error,
                log: recordingLog,
                "failed to persist audio file %{public}@ from %{public}@ to %{public}@ : %{public}@",
                fileName,
                tempURL.path,
                destURL.path,
                error.localizedDescription
            )
            return nil
        }
    }

    private static func deleteAudioFile(_ fileName: String) {
        let fileURL = audioStorageDirectory().appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
    }

    func clearPipelineHistory() {
        do {
            let removedAudioFileNames = try pipelineHistoryStore.clearAll()
            for audioFileName in removedAudioFileNames {
                Self.deleteAudioFile(audioFileName)
            }
            pipelineHistory = []
        } catch {
            errorMessage = "Unable to clear run history: \(error.localizedDescription)"
        }
    }

    func deleteHistoryEntry(id: UUID) {
        guard let index = pipelineHistory.firstIndex(where: { $0.id == id }) else { return }
        do {
            if let audioFileName = try pipelineHistoryStore.delete(id: id) {
                Self.deleteAudioFile(audioFileName)
            }
            pipelineHistory.remove(at: index)
        } catch {
            errorMessage = "Unable to delete run history entry: \(error.localizedDescription)"
        }
    }

    func retryTranscription(item: PipelineHistoryItem) {
        guard let audioFileName = item.audioFileName else { return }
        guard !retryingItemIDs.contains(item.id) else { return }

        retryingItemIDs.insert(item.id)

        let audioURL = Self.audioStorageDirectory().appendingPathComponent(audioFileName)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            retryingItemIDs.remove(item.id)
            errorMessage = "Audio file not found for retry."
            return
        }

        let restoredContext = AppContext(
            appName: nil,
            bundleIdentifier: nil,
            windowTitle: nil,
            selectedText: nil,
            currentActivity: item.contextSummary,
            contextSystemPrompt: item.contextSystemPrompt,
            contextPrompt: item.contextPrompt,
            screenshotDataURL: item.contextScreenshotDataURL,
            screenshotMimeType: item.contextScreenshotDataURL != nil ? "image/jpeg" : nil,
            screenshotError: nil
        )

        let postProcessingService = PostProcessingService(
            apiKey: apiKey,
            baseURL: apiBaseURL,
            preferredModel: postProcessingModel,
            preferredFallbackModel: postProcessingFallbackModel,
            instructionExecutionGuardEnabled: instructionExecutionGuardEnabled
        )
        let capturedCustomVocabulary = customVocabulary
        let textRules = dictationTextRules(
            customSystemPrompt: customSystemPrompt,
            category: DictationStyleCore.category(
                bundleIdentifier: item.contextBundleIdentifier, windowTitle: item.contextWindowTitle
            )
        )
        let boostsQuietSpeech = whisperModeEnabled

        Task {
            do {
                let boostedFileURL = boostsQuietSpeech ? Self.whisperBoostedCopy(of: audioURL) : nil
                defer { Self.removeTemporaryAudio(boostedFileURL) }
                let transcriptionService = try makeTranscriptionService()
                let rawTranscript = try await transcriptionService.transcribe(fileURL: boostedFileURL ?? audioURL)
                let vocabularyStatus = transcriptionService.vocabularyReport?.statusSuffix ?? ""
                let parsedTranscript = Self.parseTranscriptCommands(
                    from: rawTranscript,
                    pressEnterCommandEnabled: self.isPressEnterVoiceCommandEnabled
                )

                let finalTranscript: String
                let processingStatus: String
                let postProcessingPrompt: String
                let restoredIntent = SessionIntent.fromPersisted(
                    intent: item.intent,
                    selectedText: item.selectedText
                )
                let result = await self.processTranscript(
                    parsedTranscript.transcript,
                    intent: restoredIntent,
                    context: restoredContext,
                    postProcessingService: postProcessingService,
                    customVocabulary: capturedCustomVocabulary,
                    customSystemPrompt: textRules.systemPrompt,
                    outputLanguage: self.outputLanguage,
                    dictationLanguage: Self.dictationLanguageName(for: self.transcriptionLanguage),
                    preserveExactWording: self.preserveExactWording,
                    textRules: textRules
                )
                finalTranscript = result.finalTranscript
                processingStatus = Self.statusMessage(
                    for: result.outcome,
                    parsedTranscript: parsedTranscript,
                    isRetry: true
                )
                postProcessingPrompt = result.prompt

                await MainActor.run {
                    let updatedItem = PipelineHistoryItem(
                        intent: item.intent,
                        selectedText: item.selectedText,
                        capturedSelection: item.capturedSelection,
                        id: item.id,
                        timestamp: item.timestamp,
                        rawTranscript: parsedTranscript.transcript,
                        postProcessedTranscript: finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines),
                        postProcessingPrompt: postProcessingPrompt,
                        systemPrompt: item.systemPrompt,
                        contextSummary: item.contextSummary,
                        contextSystemPrompt: item.contextSystemPrompt,
                        contextPrompt: item.contextPrompt,
                        contextScreenshotDataURL: item.contextScreenshotDataURL,
                        contextScreenshotStatus: item.contextScreenshotStatus,
                        postProcessingStatus: processingStatus,
                        debugStatus: "Retried" + vocabularyStatus,
                        customVocabulary: item.customVocabulary,
                        audioFileName: item.audioFileName,
                        contextAppName: item.contextAppName,
                        contextBundleIdentifier: item.contextBundleIdentifier,
                        contextWindowTitle: item.contextWindowTitle
                    )
                    do {
                        try pipelineHistoryStore.update(updatedItem)
                        pipelineHistory = pipelineHistoryStore.loadAllHistory()
                        let trimmedRetryTranscript = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedRetryTranscript.isEmpty {
                            lastTranscript = trimmedRetryTranscript
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(trimmedRetryTranscript, forType: .string)
                        }
                    } catch {
                        errorMessage = "Failed to save retry result: \(error.localizedDescription)"
                    }
                    retryingItemIDs.remove(item.id)
                }
            } catch {
                await MainActor.run {
                    let updatedItem = PipelineHistoryItem(
                        intent: item.intent,
                        selectedText: item.selectedText,
                        capturedSelection: item.capturedSelection,
                        id: item.id,
                        timestamp: item.timestamp,
                        rawTranscript: item.rawTranscript,
                        postProcessedTranscript: item.postProcessedTranscript,
                        postProcessingPrompt: item.postProcessingPrompt,
                        systemPrompt: item.systemPrompt,
                        contextSummary: item.contextSummary,
                        contextSystemPrompt: item.contextSystemPrompt,
                        contextPrompt: item.contextPrompt,
                        contextScreenshotDataURL: item.contextScreenshotDataURL,
                        contextScreenshotStatus: item.contextScreenshotStatus,
                        postProcessingStatus: "Error: \(error.localizedDescription)",
                        debugStatus: "Retry failed",
                        customVocabulary: item.customVocabulary,
                        audioFileName: item.audioFileName,
                        contextAppName: item.contextAppName,
                        contextBundleIdentifier: item.contextBundleIdentifier,
                        contextWindowTitle: item.contextWindowTitle
                    )
                    do {
                        try pipelineHistoryStore.update(updatedItem)
                        pipelineHistory = pipelineHistoryStore.loadAllHistory()
                    } catch {}
                    retryingItemIDs.remove(item.id)
                }
            }
        }
    }

    func startAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        hasAccessibility = AXIsProcessTrusted()
        hasScreenRecordingPermission = hasScreenCapturePermission()
        if hasAccessibility && hasScreenRecordingPermission {
            return
        }
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.hasAccessibility = AXIsProcessTrusted()
                self.hasScreenRecordingPermission = self.hasScreenCapturePermission()
                if self.hasAccessibility && self.hasScreenRecordingPermission {
                    self.accessibilityTimer?.invalidate()
                    self.accessibilityTimer = nil
                }
            }
        }
    }

    func stopAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
    }

    func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            openPrivacySettingsPane("Privacy_Accessibility")
        }
    }

    func openMicrophoneSettings() {
        openPrivacySettingsPane("Privacy_Microphone")
    }

    func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            refreshAvailableMicrophones()
            DispatchQueue.main.async {
                completion(true)
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.refreshAvailableMicrophones()
                    }
                    completion(granted)
                }
            }
        case .denied, .restricted:
            openMicrophoneSettings()
            DispatchQueue.main.async {
                completion(false)
            }
        @unknown default:
            openMicrophoneSettings()
            DispatchQueue.main.async {
                completion(false)
            }
        }
    }

    func hasScreenCapturePermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestScreenCapturePermission() {
        // ScreenCaptureKit triggers the "Screen & System Audio Recording"
        // permission dialog on macOS Sequoia+, correctly identifying the
        // running app (unlike the legacy CGWindowListCreateImage path).
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] _, _ in
            DispatchQueue.main.async {
                let granted = CGPreflightScreenCaptureAccess()
                self?.hasScreenRecordingPermission = granted
                if !granted {
                    self?.openScreenCaptureSettings()
                }
            }
        }

        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    }

    func openScreenCaptureSettings() {
        openPrivacySettingsPane("Privacy_ScreenCapture")
    }

    private func openPrivacySettingsPane(_ pane: String) {
        let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
        if let url = settingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        // Mirroring the system's state back into the toggle must not register or unregister again.
        guard !isSyncingLaunchAtLogin else { return }
        do {
            try RioLaunchAtLogin.set(enabled)
        } catch {
            syncLaunchAtLoginToggle()
        }
    }

    func refreshLaunchAtLoginStatus() {
        syncLaunchAtLoginToggle()
    }

    private func syncLaunchAtLoginToggle() {
        let current = RioLaunchAtLogin.isEnabled
        guard current != launchAtLogin else { return }
        isSyncingLaunchAtLogin = true
        launchAtLogin = current
        isSyncingLaunchAtLogin = false
    }

    func refreshAvailableMicrophones() {
        guard !isRecording, !audioRecorder.isRecording else {
            needsMicrophoneRefreshAfterRecording = true
            return
        }

        needsMicrophoneRefreshAfterRecording = false
        availableMicrophones = AudioDevice.availableInputDevices()
    }

    private func refreshAvailableMicrophonesIfNeeded() {
        guard needsMicrophoneRefreshAfterRecording else { return }
        refreshAvailableMicrophones()
    }

    private func installAudioDeviceObservers() {
        removeAudioDeviceObservers()

        let notificationCenter = NotificationCenter.default
        let refreshOnAudioDeviceChange: (Notification) -> Void = { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice,
                  device.hasMediaType(.audio) else {
                return
            }
            self?.refreshAvailableMicrophones()
        }

        audioDeviceObservers.append(
            notificationCenter.addObserver(
                forName: .AVCaptureDeviceWasConnected,
                object: nil,
                queue: .main,
                using: refreshOnAudioDeviceChange
            )
        )
        audioDeviceObservers.append(
            notificationCenter.addObserver(
                forName: .AVCaptureDeviceWasDisconnected,
                object: nil,
                queue: .main,
                using: refreshOnAudioDeviceChange
            )
        )
    }

    var usesFnShortcut: Bool {
        holdShortcut.usesFnKey || toggleShortcut.usesFnKey || copyAgainShortcut.usesFnKey || undoLastShortcut.usesFnKey
            || fixLastShortcut.usesFnKey
    }

    var hasEnabledHoldShortcut: Bool {
        !holdShortcut.isDisabled
    }

    var hasEnabledToggleShortcut: Bool {
        !toggleShortcut.isDisabled
    }

    var shortcutStatusText: String {
        if hotkeyMonitoringErrorMessage != nil {
            return "Global shortcuts unavailable"
        }

        switch (hasEnabledHoldShortcut, hasEnabledToggleShortcut) {
        case (true, true):
            return "Hold \(holdShortcut.displayName) or \(toggleShortcut.tapPhrase) to dictate"
        case (true, false):
            return "Hold \(holdShortcut.displayName) to dictate"
        case (false, true):
            return "\(toggleShortcut.tapPhrase.prefix(1).uppercased() + toggleShortcut.tapPhrase.dropFirst()) to dictate"
        case (false, false):
            return "No dictation shortcut enabled"
        }
    }

    /// True when Fn + Control can run Rio Actions (the hold shortcut itself doesn't use Control).
    var rioActionKeyIsAvailable: Bool {
        !ShortcutConfiguration.rioActionModifiers(enabled: true, hold: holdShortcut).isEmpty
    }

    /// Shown in Settings when Edit Mode would also claim Control; the action key wins.
    var rioActionsEditModeCollisionMessage: String? {
        guard rioActionsEnabled, isCommandModeEnabled, commandModeStyle == .manual,
              commandModeManualModifier == .control else { return nil }
        return "Edit Mode's extra modifier is Ctrl. Fn + Ctrl now runs Rio Actions; pick another Edit Mode modifier to transform selected text with your hold shortcut."
    }

    var shortcutStartDelayMilliseconds: Int {
        Int((shortcutStartDelay * 1000).rounded())
    }

    func savedCustomShortcut(for role: ShortcutRole) -> ShortcutBinding? {
        switch role {
        case .hold:
            return savedHoldCustomShortcut
        case .toggle:
            return savedToggleCustomShortcut
        case .copyAgain:
            return savedCopyAgainCustomShortcut
        case .undoLast:
            return savedUndoLastCustomShortcut
        case .fixLast:
            return savedFixLastCustomShortcut
        }
    }

    var commandModeManualModifierValidationMessage: String? {
        guard isCommandModeEnabled, commandModeStyle == .manual else { return nil }
        return commandModeManualModifierCollisionMessage(for: commandModeManualModifier)
    }

    @discardableResult
    func setCommandModeEnabled(_ enabled: Bool) -> String? {
        isCommandModeEnabled = enabled
        if enabled, commandModeStyle == .manual {
            return commandModeManualModifierCollisionMessage(for: commandModeManualModifier)
        }
        return nil
    }

    @discardableResult
    func setCommandModeStyle(_ style: CommandModeStyle) -> String? {
        commandModeStyle = style
        if isCommandModeEnabled, style == .manual {
            return commandModeManualModifierCollisionMessage(for: commandModeManualModifier)
        }
        return nil
    }

    @discardableResult
    func setCommandModeManualModifier(_ modifier: CommandModeManualModifier) -> String? {
        // Match sibling setters: always commit, then validate.
        commandModeManualModifier = modifier
        if isCommandModeEnabled, commandModeStyle == .manual {
            return commandModeManualModifierCollisionMessage(for: modifier)
        }
        return nil
    }

    @discardableResult
    func setShortcut(_ binding: ShortcutBinding, for role: ShortcutRole) -> String? {
        let binding = binding.normalizedForStorageMigration()

        if role == .hold || role == .toggle {
            let otherDictationBinding = role == .hold ? toggleShortcut : holdShortcut
            guard !binding.conflicts(with: otherDictationBinding) else {
                return "Hold and tap shortcuts must be distinct."
            }
        }

        if role != .copyAgain, binding.conflicts(with: copyAgainShortcut) {
            return "This shortcut is already used by Paste Again."
        }
        if role != .undoLast, binding.conflicts(with: undoLastShortcut) {
            return "This shortcut is already used by Undo Last Dictation."
        }
        if role != .fixLast, binding.conflicts(with: fixLastShortcut) {
            return "This shortcut is already used by Fix Last Dictation."
        }
        if role == .copyAgain || role == .undoLast || role == .fixLast {
            if binding.conflicts(with: holdShortcut) {
                return "\(role.title) cannot share a shortcut with Hold to Talk."
            }
            if binding.conflicts(with: toggleShortcut) {
                return "\(role.title) cannot share a shortcut with Tap to Toggle."
            }
            if isCommandModeEnabled, commandModeStyle == .manual,
               bindingCollides(binding, with: commandModeManualModifier) {
                return "\(role.title) cannot share the Edit Mode modifier."
            }
        }

        switch role {
        case .hold:
            if binding.isCustom {
                savedHoldCustomShortcut = binding
            }
            holdShortcut = binding
        case .toggle:
            if binding.isCustom {
                savedToggleCustomShortcut = binding
            }
            toggleShortcut = binding
        case .copyAgain:
            if binding.isCustom {
                savedCopyAgainCustomShortcut = binding
            }
            copyAgainShortcut = binding
        case .undoLast:
            if binding.isCustom {
                savedUndoLastCustomShortcut = binding
            }
            undoLastShortcut = binding
        case .fixLast:
            if binding.isCustom {
                savedFixLastCustomShortcut = binding
            }
            fixLastShortcut = binding
        }

        return nil
    }

    private func commandModeManualModifierCollisionMessage(
        for modifier: CommandModeManualModifier,
        holdBinding: ShortcutBinding? = nil,
        toggleBinding: ShortcutBinding? = nil,
        copyAgainBinding: ShortcutBinding? = nil
    ) -> String? {
        let holdBinding = holdBinding ?? holdShortcut
        let toggleBinding = toggleBinding ?? toggleShortcut
        let copyAgainBinding = copyAgainBinding ?? copyAgainShortcut
        let manualModifier = modifier.shortcutModifier

        if !holdBinding.isDisabled && holdBinding.modifiers.contains(manualModifier) {
            return "That modifier is already part of the hold shortcut."
        }
        if !toggleBinding.isDisabled && toggleBinding.modifiers.contains(manualModifier) {
            return "That modifier is already part of the tap shortcut."
        }
        if !copyAgainBinding.isDisabled && copyAgainBinding.modifiers.contains(manualModifier) {
            return "That modifier is already part of the Paste Again shortcut."
        }
        if !undoLastShortcut.isDisabled && undoLastShortcut.modifiers.contains(manualModifier) {
            return "That modifier is already part of the Undo Last Dictation shortcut."
        }
        if !fixLastShortcut.isDisabled && fixLastShortcut.modifiers.contains(manualModifier) {
            return "That modifier is already part of the Fix Last Dictation shortcut."
        }
        // Modifier-only bindings carry identity in keyCode, not modifiers.
        if !holdBinding.isDisabled,
           holdBinding.kind == .modifierKey,
           let bindingModifier = ShortcutBinding.modifier(forKeyCode: holdBinding.keyCode),
           bindingModifier == manualModifier {
            return "That modifier is already the hold shortcut."
        }
        if !toggleBinding.isDisabled,
           toggleBinding.kind == .modifierKey,
           let bindingModifier = ShortcutBinding.modifier(forKeyCode: toggleBinding.keyCode),
           bindingModifier == manualModifier {
            return "That modifier is already the tap shortcut."
        }
        if !copyAgainBinding.isDisabled,
           copyAgainBinding.kind == .modifierKey,
           let bindingModifier = ShortcutBinding.modifier(forKeyCode: copyAgainBinding.keyCode),
           bindingModifier == manualModifier {
            return "That modifier is already the Paste Again shortcut."
        }
        if !undoLastShortcut.isDisabled,
           undoLastShortcut.kind == .modifierKey,
           let bindingModifier = ShortcutBinding.modifier(forKeyCode: undoLastShortcut.keyCode),
           bindingModifier == manualModifier {
            return "That modifier is already the Undo Last Dictation shortcut."
        }

        return nil
    }

    private func bindingCollides(_ binding: ShortcutBinding, with modifier: CommandModeManualModifier) -> Bool {
        guard !binding.isDisabled else { return false }
        let manualModifier = modifier.shortcutModifier
        if binding.modifiers.contains(manualModifier) { return true }
        if binding.kind == .modifierKey,
           let bindingModifier = ShortcutBinding.modifier(forKeyCode: binding.keyCode),
           bindingModifier == manualModifier {
            return true
        }
        return false
    }

    func startHotkeyMonitoring() {
        shouldMonitorHotkeys = true
        updateInsertionAccessibilityPreparation()
        hotkeyManager.onShortcutEvent = { [weak self] event in
            DispatchQueue.main.async {
                self?.handleShortcutEvent(event)
            }
        }
        hotkeyManager.onEscapeKeyPressed = { [weak self] in
            self?.handleEscapeKeyPress() ?? false
        }
        hotkeyManager.onReturnKeyPressed = { [weak self] in
            self?.correctionWatcher.returnKeyPressed()
        }
        restartHotkeyMonitoring()
    }

    private func updateInsertionAccessibilityPreparation() {
        insertionAccessibilityCancellable = nil
        guard shouldMonitorHotkeys, originalFieldInsertionEnabled else { return }
        insertionAccessibilityCancellable = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.prepareForegroundApplicationForInsertion() }
        prepareForegroundApplicationForInsertion()
    }

    /// A role query lets Electron expose its editor before the start-time snapshot, without reading text.
    private func prepareForegroundApplicationForInsertion() {
        guard shouldMonitorHotkeys, originalFieldInsertionEnabled, AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication else { return }
        let processIdentifier = app.processIdentifier
        insertionAccessibilityQueue.async {
            AppTextInsertionTarget.prepareAccessibility(processIdentifier: processIdentifier)
        }
    }

    func stopHotkeyMonitoring() {
        shouldMonitorHotkeys = false
        insertionAccessibilityCancellable = nil
        hotkeyMonitoringErrorMessage = nil
        hotkeyManager.onShortcutEvent = nil
        hotkeyManager.onEscapeKeyPressed = nil
        hotkeyManager.onReturnKeyPressed = nil
        hotkeyManager.stop()
    }

    func suspendHotkeyMonitoringForShortcutCapture() {
        isCapturingShortcut = true
        restartHotkeyMonitoring()
    }

    func resumeHotkeyMonitoringAfterShortcutCapture() {
        isCapturingShortcut = false
        restartHotkeyMonitoring()
    }

    private var activeShortcutConfiguration: ShortcutConfiguration {
        let permittedAdditionalExactMatchModifiers: ShortcutModifiers
        if isCommandModeEnabled, commandModeStyle == .manual {
            permittedAdditionalExactMatchModifiers = commandModeManualModifier.shortcutModifier
        } else {
            permittedAdditionalExactMatchModifiers = []
        }

        return ShortcutConfiguration(
            hold: holdShortcut,
            toggle: toggleShortcut,
            copyAgain: copyAgainShortcut,
            undoLast: undoLastShortcut,
            fixLast: fixLastShortcut,
            permittedAdditionalExactMatchModifiers: permittedAdditionalExactMatchModifiers,
            holdActionModifiers: ShortcutConfiguration.rioActionModifiers(enabled: rioActionsEnabled, hold: holdShortcut),
            conversationChordEnabled: rioActionsEnabled
        )
    }

    private func restartHotkeyMonitoring() {
        guard shouldMonitorHotkeys, !isCapturingShortcut, !isAwaitingMicrophonePermission else {
            hotkeyManager.stop()
            return
        }

        do {
            try hotkeyManager.start(configuration: activeShortcutConfiguration)
            hotkeyMonitoringErrorMessage = nil
        } catch {
            hotkeyMonitoringErrorMessage = error.localizedDescription
            os_log(.error, log: recordingLog, "Hotkey monitoring failed to start: %{public}@", error.localizedDescription)
        }
    }

    private func handleShortcutEvent(_ event: ShortcutEvent) {
        if event == .copyAgainTriggered {
            copyLastTranscriptToPasteboard()
            return
        }
        if event == .undoLastTriggered {
            undoLastDictation()
            return
        }
        if event == .fixLastTriggered {
            fixLastDictation()
            return
        }

        if event == .holdActionModifierEngaged {
            beginRioActionSessionIfHolding()
            return
        }

        if event == .conversationChord {
            handleConversationChord()
            return
        }

        let configuration = activeShortcutConfiguration
        shortcutSessionController.discardsShortHoldTaps = DictationShortcutSessionController.shortHoldTapsMayStartDoubleTap(
            hold: configuration.hold, toggle: configuration.toggle
        )
        guard let action = shortcutSessionController.handle(event: event, isTranscribing: isTranscribing) else {
            return
        }

        switch action {
        case .start(let mode):
            os_log(.info, log: recordingLog, "Shortcut start fired for mode %{public}@", mode.rawValue)
            // A new session starts as dictation; the action key's own event (which follows
            // this one when Control was already down) turns it into a Rio action.
            rioActionSessionRequested = false
            scheduleShortcutStart(mode: mode)
        case .stop:
            cancelPendingShortcutStart()
            guard isRecording else {
                clearRioActionSession()
                shortcutSessionController.reset()
                activeRecordingTriggerMode = nil
                activeTextInsertionTarget = nil
                return
            }
            stopAndTranscribe()
        case .cancelSilently:
            cancelShortcutSessionSilently(announceCancelled: false)
        case .switchedToToggle:
            clearRioActionSession()
            if isRecording {
                activeRecordingTriggerMode = .toggle
                overlayManager.setRecordingTriggerMode(.toggle, animated: true)
                silenceAutoStop?.restartCountdown()
            } else if pendingShortcutStartMode != nil {
                pendingShortcutStartMode = .toggle
            }
        }
    }

    private func handleEscapeKeyPress() -> Bool {
        if isTranscribing {
            cancelTranscription()
            return true
        }

        if pendingShortcutStartMode == .toggle || activeRecordingTriggerMode == .toggle {
            cancelToggleShortcutSession()
            return true
        }

        return false
    }

    /// Copies the last transcript to the pasteboard and pastes it into the
    /// focused app — Wispr Flow style. Reuses the dictation paste pipeline so
    /// preserveClipboard is honored and the synthetic Cmd+V waits for the
    /// trigger shortcut to be fully released.
    func copyLastTranscriptToPasteboard() {
        guard !lastTranscript.isEmpty else { return }
        let pendingClipboardRestore = writeTranscriptToPasteboard(lastTranscript)
        recordInsertionForUndo(lastTranscript, processIdentifier: nil)
        pasteAtCursorWhenShortcutReleased { [weak self] in
            self?.restoreClipboardIfNeeded(pendingClipboardRestore)
        }
    }

    /// Removes the last dictation from the field it went into; see DictationUndo.
    func undoLastDictation() {
        guard !isRecording, !isTranscribing else { return }
        guard let insertion = lastDictationInsertion else {
            let status = "Nothing to undo"
            statusText = status
            scheduleReadyStatusReset(after: 3, matching: [status])
            return
        }
        // The removal must not be learned as a correction.
        correctionWatcher.cancel()
        performAfterShortcutReleased { [weak self] in
            guard let self, self.lastDictationInsertion?.id == insertion.id else { return }
            let outcome = DictationUndo.undo(insertion)
            if outcome == .removed {
                self.lastDictationInsertion = nil
                self.showTeddyMoment(.undone)
            }
            let status = outcome.statusText
            self.statusText = status
            self.scheduleReadyStatusReset(after: 3, matching: [status])
        }
    }

    /// Forgets the previous dictation, then watches for this one to land in the focused field.
    /// Undo only ever acts on an insertion seen there, so a failed or blocked paste leaves
    /// nothing to undo. Pass nil to just forget.
    private func recordInsertionForUndo(_ transcript: String?, processIdentifier: pid_t?) {
        lastDictationInsertion = nil
        let token = UUID()
        undoLookupToken = token
        guard let transcript,
              let pid = processIdentifier ?? NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let text = transcriptTextForInsertion(transcript)
        lookUpInsertion(text: text, processIdentifier: pid, token: token, attempt: 0)
    }

    /// The paste waits for the shortcut to be released, so look a few times.
    private func lookUpInsertion(text: String, processIdentifier: pid_t, token: UUID, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.undoLookupInterval) { [weak self] in
            guard let self, self.undoLookupToken == token else { return }
            if let insertion = DictationUndo.locate(text: text, processIdentifier: processIdentifier) {
                self.lastDictationInsertion = insertion
            } else if attempt + 1 < Self.undoLookupAttempts {
                self.lookUpInsertion(text: text, processIdentifier: processIdentifier, token: token, attempt: attempt + 1)
            }
        }
    }

    private static let undoLookupInterval: TimeInterval = 0.25
    private static let undoLookupAttempts = 12

    /// Hands-free: ends a tap-to-toggle recording after the chosen stretch of silence.
    /// Levels are watched from the start so the noise floor is known and speech can be told from a tap; only a recording in
    /// tap mode is stopped, so holding the shortcut always keeps recording.
    private func startSilenceAutoStop() {
        // Always tracked, even with auto-stop off: the level is what tells a tap from speech.
        silenceAutoStop = SilenceAutoStop(delay: handsFreeAutoStopDelay)
        audioRecorder.onLevelSample = { [weak self] rms, duration in
            DispatchQueue.main.async {
                guard let self, self.isRecording, var detector = self.silenceAutoStop else { return }
                let shouldStop = detector.shouldStop(afterBufferWithRMS: rms, duration: duration)
                self.silenceAutoStop = detector
                guard shouldStop, self.handsFreeAutoStopDelay > 0, self.activeRecordingTriggerMode == .toggle else { return }
                os_log(.info, log: recordingLog, "Hands-free: stopping after silence")
                self.cancelPendingShortcutStart()
                self.stopAndTranscribe()
            }
        }
    }

    private func stopSilenceAutoStop() {
        audioRecorder.onLevelSample = nil
        silenceAutoStop = nil
    }

    func toggleRecording() {
        os_log(.info, log: recordingLog, "toggleRecording() called, isRecording=%{public}d", isRecording)
        cancelPendingShortcutStart()
        if isRecording {
            stopAndTranscribe()
        } else {
            // A manual start is plain dictation, never a leftover action-key request.
            rioActionSessionRequested = false
            shortcutSessionController.beginManual(mode: .toggle)
            startRecording(triggerMode: .toggle)
        }
    }

    private func handleOverlayStopButtonPressed() {
        guard isRecording, activeRecordingTriggerMode == .toggle else { return }
        stopAndTranscribe()
    }

    private func cancelToggleShortcutSession() {
        guard pendingShortcutStartMode == .toggle || activeRecordingTriggerMode == .toggle else { return }
        cancelShortcutSessionSilently()
    }

    /// Left Fn + Control + Option: toggle conversation mode (or stop the translator). Whatever the
    /// Fn hold or Fn + Control had started is thrown away first: no paste, no action, no error.
    /// A hands-free (toggle) session is the exception: it keeps recording, so a long dictation is
    /// never lost to the chord.
    private func handleConversationChord() {
        let handsFree = activeRecordingTriggerMode == .toggle || pendingShortcutStartMode == .toggle
        if shortcutSessionController.handle(event: .conversationChord, isTranscribing: isTranscribing) == .cancelSilently
            || (!handsFree && (pendingShortcutStartMode != nil || isRecording)) {
            cancelShortcutSessionSilently(announceCancelled: false)
        }
        clearRioActionSession()
        guard rioActionsEnabled else { return }
        MainActor.assumeIsolated { RioConversationMode.shared.toggleFromChord() }
    }

    /// Drops a recording that has not been transcribed yet, silently (the audio is discarded).
    private func cancelShortcutSessionSilently(announceCancelled: Bool = true) {
        clearRioActionSession()
        textInsertionTargetID = nil
        cancelPendingShortcutStart()
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
        activeTextInsertionTarget = nil
        audioRecorder.onRecordingReady = nil
        audioRecorder.onRecordingFailure = nil
        stopSilenceAutoStop()
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        cancelRecordingInitializationTimer()
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
        capturedContext = nil
        currentSessionIntent = .dictation
        isRecording = false
        errorMessage = nil
        debugStatusMessage = announceCancelled ? "Cancelled" : "Ready"
        statusText = announceCancelled ? "Cancelled" : "Ready"
        overlayManager.dismiss()
        tearDownRealtimeService()
        audioRecorder.cancelRecording()
        restoreAudioInterruptionIfNeeded()
        endCriticalDictationActivity()
        refreshAvailableMicrophonesIfNeeded()
        if !isRecording && !isTranscribing && statusText == "Cancelled" {
            scheduleReadyStatusReset(after: 2, matching: ["Cancelled"])
        }
    }

    private func cancelTranscription() {
        guard isTranscribing else { return }

        textInsertionTargetID = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
        capturedContext = nil
        shortcutSessionController.reset()
        clearRioActionSession()
        activeRecordingTriggerMode = nil
        activeTextInsertionTarget = nil
        currentSessionIntent = .dictation
        isRecording = false
        isTranscribing = false
        errorMessage = nil
        debugStatusMessage = "Cancelled"
        statusText = "Cancelled"
        overlayManager.dismiss()
        audioRecorder.cleanup()
        if let transcribingAudioFileName {
            Self.deleteAudioFile(transcribingAudioFileName)
            self.transcribingAudioFileName = nil
        }
        endCriticalDictationActivity()
        refreshAvailableMicrophonesIfNeeded()
        if !isRecording && !isTranscribing && statusText == "Cancelled" {
            scheduleReadyStatusReset(after: 2, matching: ["Cancelled"])
        }
    }

    /// Invalidates prior insertion actions before taking the new start-time snapshot, including during delays.
    private func scheduleShortcutStart(mode: RecordingTriggerMode) {
        textInsertionTargetID = nil
        cancelPendingShortcutStart(resetMode: false)
        pendingSelectionSnapshot = contextService.collectSelectionSnapshot(captureInsertionTarget: originalFieldInsertionEnabled)
        pendingManualCommandInvocation = hotkeyManager.currentPressedModifiers.contains(
            commandModeManualModifier.shortcutModifier
        )
        pendingShortcutStartMode = mode
        let delay = shortcutStartDelay

        guard delay > 0 else {
            pendingShortcutStartMode = nil
            startRecording(triggerMode: mode)
            return
        }

        pendingShortcutStartTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }

            await MainActor.run { [weak self] in
                guard let self, let pendingMode = self.pendingShortcutStartMode else { return }
                self.pendingShortcutStartTask = nil
                self.pendingShortcutStartMode = nil
                self.startRecording(triggerMode: pendingMode)
            }
        }
    }

    private func cancelPendingShortcutStart(resetMode: Bool = true) {
        pendingShortcutStartTask?.cancel()
        pendingShortcutStartTask = nil
        pendingSelectionSnapshot = nil
        pendingManualCommandInvocation = false
        if resetMode {
            pendingShortcutStartMode = nil
        }
    }

    private func resolveSessionIntent(
        triggerMode: RecordingTriggerMode,
        selectionSnapshot: AppSelectionSnapshot,
        manualCommandRequested: Bool
    ) -> SessionIntent? {
        // The action key wins over Edit Mode, even if Edit Mode's modifier is also Control.
        if isRioActionKeyHeld(triggerMode: triggerMode) {
            return .dictation
        }
        guard isCommandModeEnabled else {
            return .dictation
        }

        let rawSelectedText = selectionSnapshot.selectedText ?? ""
        let trimmedSelectedText = rawSelectedText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch commandModeStyle {
        case .automatic:
            if !trimmedSelectedText.isEmpty {
                return .command(invocation: .automatic, selectedText: rawSelectedText)
            }
            return .dictation
        case .manual:
            // If the binding IS the manual modifier, the "modifier pressed"
            // signal is the binding's own press. Fall back to plain dictation.
            let activeBinding: ShortcutBinding = (triggerMode == .toggle) ? toggleShortcut : holdShortcut
            if activeBinding.kind == .modifierKey,
               let bindingModifier = ShortcutBinding.modifier(forKeyCode: activeBinding.keyCode),
               bindingModifier == commandModeManualModifier.shortcutModifier {
                return .dictation
            }
            if let message = commandModeManualModifierCollisionMessage(for: commandModeManualModifier) {
                rejectInvalidCommandModeModifier(triggerMode: triggerMode, message: message)
                return nil
            }
            guard manualCommandRequested else {
                return .dictation
            }
            guard !trimmedSelectedText.isEmpty else {
                rejectCommandModeSelectionRequirement(triggerMode: triggerMode)
                return nil
            }
            return .command(invocation: .manual, selectedText: rawSelectedText)
        }
    }

    private func rejectCommandModeSelectionRequirement(triggerMode: RecordingTriggerMode) {
        currentSessionIntent = .dictation
        activeRecordingTriggerMode = nil
        activeTextInsertionTarget = nil
        pendingSelectionSnapshot = nil
        pendingManualCommandInvocation = false
        errorMessage = "Select text to transform first."
        statusText = "Select text to transform first"
        debugStatusMessage = "Edit mode requires selected text"
        shortcutSessionController.reset()
        if triggerMode == .toggle {
            cancelPendingShortcutStart()
        }
        playAlertSound(named: "Basso")
        scheduleReadyStatusReset(after: 2, matching: ["Select text to transform first"])
    }

    private func rejectInvalidCommandModeModifier(triggerMode: RecordingTriggerMode, message: String) {
        currentSessionIntent = .dictation
        activeRecordingTriggerMode = nil
        activeTextInsertionTarget = nil
        pendingSelectionSnapshot = nil
        pendingManualCommandInvocation = false
        errorMessage = message
        statusText = "Fix Edit Mode modifier"
        debugStatusMessage = "Edit mode modifier conflicts with dictation shortcuts"
        shortcutSessionController.reset()
        if triggerMode == .toggle {
            cancelPendingShortcutStart()
        }
        playAlertSound(named: "Basso")
        scheduleReadyStatusReset(after: 2, matching: ["Fix Edit Mode modifier"])
    }

    private func startRecording(triggerMode: RecordingTriggerMode) {
        let t0 = CFAbsoluteTimeGetCurrent()
        os_log(.info, log: recordingLog, "startRecording() entered")
        guard !isRecording && !isTranscribing else { return }
        isDeferringLearnFeedback = true
        correctionWatcher.stop()
        isDeferringLearnFeedback = false
        let scheduledSelectionSnapshot = pendingSelectionSnapshot
        let selectionSnapshot = scheduledSelectionSnapshot
            ?? contextService.collectSelectionSnapshot(captureInsertionTarget: originalFieldInsertionEnabled)
        let scheduledManualCommandInvocation = pendingManualCommandInvocation
        cancelPendingShortcutStart()
        guard prepareRecordingStart(
            triggerMode: triggerMode,
            selectionSnapshot: selectionSnapshot,
            manualCommandRequested: scheduledSelectionSnapshot == nil
                ? hotkeyManager.currentPressedModifiers.contains(commandModeManualModifier.shortcutModifier)
                : scheduledManualCommandInvocation,
            startedAt: t0
        ) else { return }
        guard ensureMicrophoneAccess(selectionSnapshot: selectionSnapshot) else { return }
        os_log(.info, log: recordingLog, "mic access check passed: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        applyAudioInterruptionIfNeeded()
        beginRecording(triggerMode: triggerMode)
        os_log(.info, log: recordingLog, "startRecording() finished: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }

    /// Latches the supplied snapshot into the recording so later preference changes cannot redirect it.
    private func prepareRecordingStart(
        triggerMode: RecordingTriggerMode,
        selectionSnapshot: AppSelectionSnapshot? = nil,
        manualCommandRequested: Bool? = nil,
        startedAt: CFAbsoluteTime? = nil
    ) -> Bool {
        textInsertionTargetID = nil
        activeRecordingTriggerMode = triggerMode
        let isAccessibilityTrusted = AXIsProcessTrusted()
        hasAccessibility = isAccessibilityTrusted
        guard isAccessibilityTrusted else {
            errorMessage = "Accessibility permission required. Grant access in System Settings > Privacy & Security > Accessibility."
            statusText = "No Accessibility"
            activeRecordingTriggerMode = nil
            activeTextInsertionTarget = nil
            currentSessionIntent = .dictation
            shortcutSessionController.reset()
            showAccessibilityAlert()
            return false
        }
        if let startedAt {
            os_log(.info, log: recordingLog, "accessibility check passed: %.3fms", (CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        }

        let selectionSnapshot = selectionSnapshot ?? contextService.collectSelectionSnapshot(captureInsertionTarget: originalFieldInsertionEnabled)
        activeOriginalFieldInsertionEnabled = selectionSnapshot.usesOriginalFieldInsertion
        activeTextInsertionTarget = activeOriginalFieldInsertionEnabled ? selectionSnapshot.textInsertionTarget : nil
        textInsertionTargetID = activeTextInsertionTarget?.identifier
        let manualCommandRequested = manualCommandRequested
            ?? hotkeyManager.currentPressedModifiers.contains(commandModeManualModifier.shortcutModifier)
        guard let resolvedIntent = resolveSessionIntent(
            triggerMode: triggerMode,
            selectionSnapshot: selectionSnapshot,
            manualCommandRequested: manualCommandRequested
        ) else { return false }

        if resolvedIntent.isCommandMode && contextCaptureEnabled {
            guard ensureScreenCaptureAccess() else { return false }
            if let startedAt {
                os_log(.info, log: recordingLog, "screen capture check passed: %.3fms", (CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            }
        } else {
            hasScreenRecordingPermission = hasScreenCapturePermission()
        }

        currentSessionIntent = resolvedIntent
        activeStyleCategory = frontmostStyleCategory()
        teddyOutfit = TeddyOutfit.forStyle(style(for: activeStyleCategory))
        overlayManager.setOutfit(teddyOutfit)
        overlayManager.setSpokenLook(
            SpokenLook.atRecordingStart(selectedLanguage: transcriptionLanguage, lastDetected: lastSpokenLook)
        )
        overlayManager.setRecordingTriggerMode(triggerMode, animated: false)
        return true
    }

    /// Only looks up the window title (an Accessibility call) when a style is set and the app is a browser.
    private func frontmostStyleCategory() -> DictationStyleCategory {
        guard hasCustomDictationStyles else { return .other }
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let bundleIdentifier = frontmostApp?.bundleIdentifier
        let windowTitle = bundleIdentifier.map { DictationStyleCore.browsers.contains($0) } == true
            ? focusedWindowTitle(for: frontmostApp)
            : nil
        return DictationStyleCore.category(bundleIdentifier: bundleIdentifier, windowTitle: windowTitle)
    }

    private func ensureScreenCaptureAccess() -> Bool {
        let granted = hasScreenCapturePermission()
        hasScreenRecordingPermission = granted
        guard granted else {
            let message = "Screen recording permission not granted. Enable in System Settings > Privacy & Security > Screen Recording."
            errorMessage = message
            statusText = "Screenshot Required"
            activeRecordingTriggerMode = nil
            activeTextInsertionTarget = nil
            currentSessionIntent = .dictation
            shortcutSessionController.reset()
            playAlertSound(named: "Basso")
            showScreenshotPermissionAlert(message: message)
            return false
        }

        return true
    }

    private func ensureMicrophoneAccess(selectionSnapshot: AppSelectionSnapshot) -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            guard let triggerMode = activeRecordingTriggerMode else {
                return false
            }

            prepareForMicrophonePermissionPrompt(
                triggerMode: triggerMode,
                selectionSnapshot: selectionSnapshot,
                manualCommandRequested: currentSessionIntent.isManualCommand
            )
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let strongSelf = self else { return }
                    let pendingTriggerMode = strongSelf.pendingMicrophonePermissionTriggerMode
                    let pendingSelectionSnapshot = strongSelf.pendingMicrophonePermissionSelectionSnapshot
                    let pendingManualCommandRequested = strongSelf.pendingMicrophonePermissionManualCommandRequested
                    strongSelf.pendingMicrophonePermissionTriggerMode = nil
                    strongSelf.pendingMicrophonePermissionSelectionSnapshot = nil
                    strongSelf.pendingMicrophonePermissionManualCommandRequested = nil
                    strongSelf.isAwaitingMicrophonePermission = false
                    strongSelf.restartHotkeyMonitoring()

                    guard let triggerMode = pendingTriggerMode else { return }
                    if granted {
                        strongSelf.errorMessage = nil
                        if triggerMode == .toggle {
                            guard strongSelf.prepareRecordingStart(
                                triggerMode: .toggle,
                                selectionSnapshot: pendingSelectionSnapshot,
                                manualCommandRequested: pendingManualCommandRequested
                            ) else { return }
                            strongSelf.shortcutSessionController.beginManual(mode: .toggle)
                            strongSelf.applyAudioInterruptionIfNeeded()
                            strongSelf.beginRecording(triggerMode: .toggle)
                        } else {
                            strongSelf.currentSessionIntent = .dictation
                            strongSelf.statusText = "Microphone access granted. Press and hold again to record."
                            strongSelf.scheduleReadyStatusReset(
                                after: 2,
                                matching: ["Microphone access granted. Press and hold again to record."]
                            )
                        }
                    } else {
                        strongSelf.errorMessage = "Microphone permission denied. Grant access in System Settings > Privacy & Security > Microphone."
                        strongSelf.statusText = "No Microphone"
                        strongSelf.activeRecordingTriggerMode = nil
                        strongSelf.activeTextInsertionTarget = nil
                        strongSelf.currentSessionIntent = .dictation
                        strongSelf.shortcutSessionController.reset()
                        strongSelf.showMicrophonePermissionAlert()
                    }
                }
            }
            return false
        default:
            errorMessage = "Microphone permission denied. Grant access in System Settings > Privacy & Security > Microphone."
            statusText = "No Microphone"
            activeRecordingTriggerMode = nil
            activeTextInsertionTarget = nil
            currentSessionIntent = .dictation
            shortcutSessionController.reset()
            showMicrophonePermissionAlert()
            return false
        }
    }

    private func prepareForMicrophonePermissionPrompt(
        triggerMode: RecordingTriggerMode,
        selectionSnapshot: AppSelectionSnapshot?,
        manualCommandRequested: Bool?
    ) {
        isAwaitingMicrophonePermission = true
        pendingMicrophonePermissionTriggerMode = triggerMode
        pendingMicrophonePermissionSelectionSnapshot = selectionSnapshot
        pendingMicrophonePermissionManualCommandRequested = manualCommandRequested
        hotkeyManager.stop()
        shortcutSessionController.reset()
        activeRecordingTriggerMode = nil
        activeTextInsertionTarget = nil
        cancelRecordingInitializationTimer()
        audioRecorder.onRecordingReady = nil
        audioRecorder.onRecordingFailure = nil
        stopSilenceAutoStop()
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        overlayManager.dismiss()
    }

    private func applyAudioInterruptionIfNeeded() {
        guard dictationAudioInterruptionEnabled, activeAudioInterruption == nil else { return }

        let wasMuted = SystemAudioStatus.isDefaultOutputMuted()
        if wasMuted {
            activeAudioInterruption = .muted(previouslyMuted: true)
        } else if SystemAudioStatus.setDefaultOutputMuted(true) {
            activeAudioInterruption = .muted(previouslyMuted: false)
        }
    }

    private func restoreAudioInterruptionIfNeeded() {
        guard let activeAudioInterruption else { return }
        self.activeAudioInterruption = nil

        switch activeAudioInterruption {
        case .muted(let previouslyMuted):
            if !previouslyMuted {
                _ = SystemAudioStatus.setDefaultOutputMuted(false)
            }
        }
    }

    private func beginCriticalDictationActivity() {
        guard !automaticTerminationDisabled else { return }
        ProcessInfo.processInfo.disableAutomaticTermination("FreeFlow dictation in progress")
        automaticTerminationDisabled = true
    }

    private func endCriticalDictationActivity() {
        guard automaticTerminationDisabled else { return }
        ProcessInfo.processInfo.enableAutomaticTermination("FreeFlow dictation in progress")
        automaticTerminationDisabled = false
    }

    private func beginRecording(triggerMode: RecordingTriggerMode) {
        os_log(.info, log: recordingLog, "beginRecording() entered")
        // A new dictation ends the bear's lap at once.
        teddyTrip.stop()
        beginCriticalDictationActivity()
        clearPendingOverlayDismissToken()
        errorMessage = nil

        isRecording = true
        // Rio stops talking the moment you start talking to him.
        MainActor.assumeIsolated { RioVoice.shared.stopSpeaking() }
        recordingStartedAt = Date()
        statusText = "Starting..."
        hasShownScreenshotPermissionAlert = false
        // Keep this recording's display preference fixed, including during startup silence.
        let showsRecordingTimer =
            RecordingTimerPreference.load(from: .standard)

        let timingGeneration = audioRecorder.prepareRecordingTiming()

        // Show initializing dots only if engine takes longer than 0.2s to start
        var overlayShown = false
        cancelRecordingInitializationTimer()
        let initTimer = DispatchSource.makeTimerSource(queue: .main)
        recordingInitializationTimer = initTimer
        initTimer.schedule(deadline: .now() + 0.2)
        initTimer.setEventHandler { [weak self] in
            guard let self, !overlayShown else { return }
            overlayShown = true
            os_log(.info, log: recordingLog, "engine slow — showing initializing overlay")
            self.clearPendingOverlayDismissToken()
            self.overlayManager.showInitializing(
                mode: self.activeRecordingTriggerMode ?? triggerMode,
                isCommandMode: self.currentSessionIntent.isCommandMode
            )
        }
        initTimer.resume()

        // Transition to waveform when first real audio arrives (any non-zero RMS)
        let deviceUID = selectedMicrophoneID
        audioRecorder.onRecordingReady = { [weak self] captureStartedAt in
            // The recorder already delivers on main after validating the generation.
            // Do not enqueue again: cancellation could invalidate it between main-queue blocks.
            guard let self, self.isRecording, self.activeRecordingTriggerMode != nil else { return }
            self.cancelRecordingInitializationTimer()
            os_log(.info, log: recordingLog, "first real audio — transitioning to waveform")
            self.statusText = "Recording..."
            self.clearPendingOverlayDismissToken()
            if overlayShown {
                self.overlayManager.transitionToRecording(
                    mode: self.activeRecordingTriggerMode ?? triggerMode,
                    isCommandMode: self.currentSessionIntent.isCommandMode,
                    startedAt: captureStartedAt,
                    showsRecordingTimer: showsRecordingTimer
                )
            } else {
                self.overlayManager.showRecording(
                    mode: self.activeRecordingTriggerMode ?? triggerMode,
                    isCommandMode: self.currentSessionIntent.isCommandMode,
                    startedAt: captureStartedAt,
                    showsRecordingTimer: showsRecordingTimer
                )
            }
            overlayShown = true
            self.playAlertSound(named: "Tink")
        }
        audioRecorder.onRecordingFailure = { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.cancelRecordingInitializationTimer()
                self.handleRecordingFailure(error)
            }
        }

        startRealtimeStreamingIfEnabled()
        startLanguageProbeIfNeeded()

        // Open the TCP+TLS connections to the configured hosts while the user speaks, so the
        // upload and cleanup requests after release skip DNS and the handshake. Credential-free
        // and carries no user data.
        // Only hosts this dictation will actually call: each one needs its own key to be used.
        let prewarmHosts = (resolvedTranscriptionAPIKey.isEmpty ? [] : [resolvedTranscriptionBaseURL])
            + (apiKey.isEmpty ? [] : [apiBaseURL])
        if !prewarmHosts.isEmpty {
            LLMAPITransport.prewarm(baseURLs: prewarmHosts)
        }

        // Start engine on background thread so UI isn't blocked
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            do {
                try self.audioRecorder.startRecording(deviceUID: deviceUID, timingGeneration: timingGeneration)
                os_log(.info, log: recordingLog, "audioRecorder.startRecording() done: %.3fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
                DispatchQueue.main.async { [self] in
                    guard self.isRecording, self.activeRecordingTriggerMode != nil else { return }
                    if self.contextCaptureEnabled {
                        self.startContextCapture()
                    }
                    self.audioLevelCancellable = self.audioRecorder.$audioLevel
                        .receive(on: DispatchQueue.main)
                        .sink { [weak self] level in
                            self?.overlayManager.updateAudioLevel(level)
                        }
                    self.startSilenceAutoStop()
                }
            } catch {
                DispatchQueue.main.async {
                    self.cancelRecordingInitializationTimer()
                    guard self.isRecording || self.activeRecordingTriggerMode != nil else { return }
                    self.handleRecordingFailure(error)
                }
            }
        }
    }

    private func handleRecordingFailure(_ error: Error) {
        cancelRecordingInitializationTimer()
        audioRecorder.onRecordingReady = nil
        audioRecorder.onRecordingFailure = nil
        stopSilenceAutoStop()
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        contextCaptureTask?.cancel()
        contextCaptureTask = nil
        capturedContext = nil
        tearDownRealtimeService()
        audioRecorder.cleanup()
        restoreAudioInterruptionIfNeeded()
        isRecording = false
        isTranscribing = false
        transcriptionTask?.cancel()
        transcriptionTask = nil
        if let transcribingAudioFileName {
            Self.deleteAudioFile(transcribingAudioFileName)
            self.transcribingAudioFileName = nil
        }
        activeRecordingTriggerMode = nil
        activeTextInsertionTarget = nil
        currentSessionIntent = .dictation
        shortcutSessionController.reset()
        clearRioActionSession()
        endCriticalDictationActivity()
        errorMessage = formattedRecordingStartError(error)
        statusText = "Error"
        overlayManager.dismiss()
        refreshAvailableMicrophonesIfNeeded()
    }

    private func formattedRecordingStartError(_ error: Error) -> String {
        if let recorderError = error as? AudioRecorderError {
            return "Failed to start recording: \(recorderError.localizedDescription)"
        }

        let lower = error.localizedDescription.lowercased()
        if lower.contains("operation couldn't be completed") || lower.contains("operation could not be completed") {
            return "Failed to start recording: Audio input error. Verify microphone access is granted and a working mic is selected in System Settings > Sound > Input."
        }

        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain {
            return "Failed to start recording (audio subsystem error \(nsError.code)). Check microphone permissions and selected input device."
        }

        return "Failed to start recording: \(error.localizedDescription)"
    }

    private func formattedTranscriptionError(_ error: Error) -> String {
        TranscriptionErrorPresentationCore.message(
            for: error,
            isOnline: NetworkMonitor.shared.isOnline
        )
    }

    func showMicrophonePermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Permission Required"
        alert.informativeText = "\(AppName.displayName) cannot record audio without Microphone access.\n\nGo to System Settings > Privacy & Security > Microphone and enable \(AppName.displayName)."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")
        alert.icon = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openMicrophoneSettings()
        }
    }

    func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "\(AppName.displayName) cannot type transcriptions without Accessibility access.\n\nGo to System Settings > Privacy & Security > Accessibility and enable \(AppName.displayName)."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")
        alert.icon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    private func precomputeMacros() {
        precomputedMacros = voiceMacros.map { macro in
            PrecomputedMacro(
                original: macro,
                normalizedCommand: normalize(macro.command)
            )
        }
    }

    private func normalize(_ text: String) -> String {
        let lowercased = text.lowercased()
        let strippedPunctuation = lowercased.components(separatedBy: CharacterSet.punctuationCharacters).joined()
        return strippedPunctuation.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseTranscriptCommands(
        from transcript: String,
        pressEnterCommandEnabled: Bool
    ) -> TranscriptCommandParsingResult {
        guard pressEnterCommandEnabled else {
            return TranscriptCommandParsingResult(
                transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                shouldPressEnterAfterPaste: false
            )
        }

        let fullRange = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
        guard
            let match = trailingPressEnterCommandPattern.firstMatch(in: transcript, range: fullRange),
            let commandRange = Range(match.range, in: transcript)
        else {
            return TranscriptCommandParsingResult(
                transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                shouldPressEnterAfterPaste: false
            )
        }

        var strippedTranscript = transcript
        strippedTranscript.removeSubrange(commandRange)

        return TranscriptCommandParsingResult(
            transcript: strippedTranscript.trimmingCharacters(in: .whitespacesAndNewlines),
            shouldPressEnterAfterPaste: true
        )
    }

    private static func statusMessage(
        for outcome: TranscriptProcessingOutcome,
        parsedTranscript: TranscriptCommandParsingResult,
        isRetry: Bool = false
    ) -> String {
        let status = outcome.statusMessage(isRetry: isRetry)
        guard parsedTranscript.shouldPressEnterAfterPaste else { return status }
        return "\(status); detected press enter command"
    }

    func playAlertSound(named name: String) {
        guard alertSoundsEnabled else { return }

        let sound = NSSound(named: name)
        sound?.volume = soundVolume
        sound?.play()
    }

    /// A sound Rio makes himself (conversation mode's chime), under the same settings.
    func playAlertSound(data: Data) {
        guard alertSoundsEnabled, let sound = NSSound(data: data) else { return }
        sound.volume = soundVolume
        rioChimeSound?.stop()
        rioChimeSound = sound
        sound.play()
    }

    private func findMatchingMacro(for transcript: String) -> VoiceMacro? {
        let normalizedTranscript = normalize(transcript)
        guard !normalizedTranscript.isEmpty else { return nil }

        return precomputedMacros.first {
            normalizedTranscript == $0.normalizedCommand
        }?.original
    }

    private enum TranscriptProcessingOutcome {
        case skippedEmptyRawTranscript
        case voiceMacro(command: String)
        case postProcessingSucceeded
        case postProcessingFailedFallback
        case preservedExactWording
        case preservedExactWordingTranslated
        case preservedExactWordingTranslationFailedFallback
        case commandModeSucceeded(invocation: CommandInvocation)
        case commandModeFailedFallback(invocation: CommandInvocation)

        func statusMessage(isRetry: Bool = false) -> String {
            switch self {
            case .skippedEmptyRawTranscript:
                return "Skipped macros and post-processing for empty raw transcript"
            case .voiceMacro(let command):
                return "Voice macro used: \(command)"
            case .postProcessingSucceeded:
                return isRetry ? "Post-processing succeeded (retried)" : "Post-processing succeeded"
            case .postProcessingFailedFallback:
                return isRetry
                    ? "Post-processing failed on retry, using raw transcript"
                    : "Post-processing failed, using raw transcript"
            case .preservedExactWording:
                return "Preserved exact wording, skipped post-processing"
            case .preservedExactWordingTranslated:
                return "Preserved exact wording, translated to output language"
            case .preservedExactWordingTranslationFailedFallback:
                return "Verbatim translation failed, using untranslated raw transcript"
            case .commandModeSucceeded(let invocation):
                return "Edit mode succeeded (\(invocation.rawValue))"
            case .commandModeFailedFallback(let invocation):
                return "Edit mode failed, using selected text (\(invocation.rawValue))"
            }
        }
    }

    private func processTranscript(
        _ rawTranscript: String,
        intent: SessionIntent,
        context: AppContext,
        postProcessingService: PostProcessingService,
        customVocabulary: String,
        customSystemPrompt: String,
        outputLanguage: String = "",
        dictationLanguage: String = "",
        preserveExactWording: Bool,
        contextGeneration: UUID? = nil,
        textRules: DictationTextRules = .none
    ) async -> (finalTranscript: String, outcome: TranscriptProcessingOutcome, prompt: String) {
        let trimmedRawTranscript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedRawTranscript.isEmpty else {
            return ("", .skippedEmptyRawTranscript, "")
        }

        let contextSummaryProvider: (@Sendable () async -> String)?
        if let contextGeneration {
            contextSummaryProvider = { [weak self] in
                await self?.contextSummaryForRequest(context, generation: contextGeneration) ?? ""
            }
        } else {
            // History retries intentionally reuse their saved context.
            contextSummaryProvider = nil
        }

        if case .command(let invocation, let selectedText) = intent {
            do {
                let result = try await postProcessingService.commandTransform(
                    selectedText: selectedText,
                    voiceCommand: rawTranscript,
                    context: context,
                    customVocabulary: customVocabulary,
                    outputLanguage: outputLanguage,
                    contextSummaryProvider: contextSummaryProvider
                )
                return (result.transcript, .commandModeSucceeded(invocation: invocation), result.prompt)
            } catch {
                os_log(.error, log: recordingLog, "Edit mode failed: %{public}@", error.localizedDescription)
                return (selectedText, .commandModeFailedFallback(invocation: invocation), "")
            }
        }

        if let macro = findMatchingMacro(for: trimmedRawTranscript) {
            os_log(.info, log: recordingLog, "Voice macro triggered: %{public}@", macro.command)
            return (macro.payload, .voiceMacro(command: macro.command), "")
        }

        // Dictionary replacements run before cleanup, so the model sees the intended words, and
        // again after it, in case cleanup reintroduced a misheard form. Snippets expand last.
        let processed = await processDictation(
            dictationTranscript: textRules.beforeCleanup(trimmedRawTranscript),
            context: context,
            postProcessingService: postProcessingService,
            customVocabulary: customVocabulary,
            customSystemPrompt: customSystemPrompt,
            outputLanguage: outputLanguage,
            dictationLanguage: dictationLanguage,
            preserveExactWording: preserveExactWording,
            contextSummaryProvider: contextSummaryProvider
        )
        let cleanupRan: Bool
        switch processed.outcome {
        case .postProcessingSucceeded, .preservedExactWordingTranslated: cleanupRan = true
        default: cleanupRan = false
        }
        let finished = textRules.afterCleanup(processed.finalTranscript, cleanupRan: cleanupRan)
        return (finished, processed.outcome, processed.prompt)
    }

    private func processDictation(
        dictationTranscript trimmedRawTranscript: String,
        context: AppContext,
        postProcessingService: PostProcessingService,
        customVocabulary: String,
        customSystemPrompt: String,
        outputLanguage: String,
        dictationLanguage: String,
        preserveExactWording: Bool,
        contextSummaryProvider: (@Sendable () async -> String)?
    ) async -> (finalTranscript: String, outcome: TranscriptProcessingOutcome, prompt: String) {
        // Preserve-exact-wording mode. Two sub-cases so translation
        // stays honored:
        //
        //   1. No Output Language set — skip the LLM entirely and
        //      return the raw transcript verbatim.
        //   2. Output Language IS set — route through a stripped-down
        //      translate-only prompt. The user asked for another
        //      language; silently dropping translation defeats their
        //      settings. The translate-only path preserves filler,
        //      informal wording, and profanity 1:1 while still hitting
        //      the target language.
        if preserveExactWording {
            let targetLanguage = outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            if targetLanguage.isEmpty {
                return (trimmedRawTranscript, .preservedExactWording, "")
            }
            do {
                let result = try await postProcessingService.translateVerbatim(
                    transcript: trimmedRawTranscript,
                    targetLanguage: targetLanguage
                )
                return (result.transcript, .preservedExactWordingTranslated, result.prompt)
            } catch {
                os_log(.error, log: recordingLog,
                       "Verbatim translation failed: %{public}@",
                       error.localizedDescription)
                return (trimmedRawTranscript, .preservedExactWordingTranslationFailedFallback, "")
            }
        }

        do {
            let result = try await postProcessingService.postProcess(
                transcript: trimmedRawTranscript,
                context: context,
                customVocabulary: customVocabulary,
                customSystemPrompt: customSystemPrompt,
                outputLanguage: outputLanguage,
                dictationLanguage: dictationLanguage,
                contextSummaryProvider: contextSummaryProvider
            )
            return (result.transcript, .postProcessingSucceeded, result.prompt)
        } catch {
            os_log(.error, log: recordingLog, "Post-processing failed: %{public}@", error.localizedDescription)
            return (trimmedRawTranscript, .postProcessingFailedFallback, "")
        }
    }

    /// Await the realtime WebSocket's final transcript. If it errors out (or
    /// was never started) fall back to the file-based POST so the user still
    /// gets a transcript. Runs the realtime commit and file upload in that
    /// strict order to avoid paying for both when realtime succeeds.
    private static func resolveRawTranscript(
        realtimeService: RealtimeTranscriptionService?,
        fileService: TranscriptionService,
        fileURL: URL
    ) async throws -> String {
        if let realtimeService {
            do {
                try Task.checkCancellation()
                return try await withTaskCancellationHandler {
                    try await realtimeService.commitAndAwaitFinal()
                } onCancel: {
                    realtimeService.cancel()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                return try await fileService.transcribe(fileURL: fileURL)
            }
        }
        return try await fileService.transcribe(fileURL: fileURL)
    }

    private func stopAndTranscribe() {
        cancelPendingShortcutStart()
        cancelRecordingInitializationTimer()
        shortcutSessionController.reset()
        let textInsertionTarget = activeTextInsertionTarget
        let useOriginalFieldInsertion = activeOriginalFieldInsertionEnabled
        activeOriginalFieldInsertionEnabled = false
        activeRecordingTriggerMode = nil
        activeTextInsertionTarget = nil
        // An action session that ends before the chord wait is over still stops the task.
        if rioPendingTaskStop != nil { stopRunningTaskForActionKey() }
        let isRioActionSession = rioActionSessionRequested
        rioActionSessionRequested = false
        // An action session is never a command-mode or dictation run: nothing is typed or pasted.
        let sessionIntent = isRioActionSession ? SessionIntent.dictation : currentSessionIntent
        currentSessionIntent = .dictation
        let textRules = dictationTextRules(customSystemPrompt: customSystemPrompt, category: activeStyleCategory)
        activeStyleCategory = .other
        let recordedSeconds = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil
        let boostsQuietSpeech = whisperModeEnabled
        audioRecorder.onRecordingReady = nil
        audioRecorder.onRecordingFailure = nil
        // Read before the detector is cleared: a tap or a silent recording is never sent, and the
        // hallucination guard only judges recordings that held little speech.
        let speechEvidence = silenceAutoStop.map {
            WhisperHallucinationGuard.SpeechEvidence(recordedSeconds: recordedSeconds, heardSpeechSeconds: $0.heardSpeechSeconds)
        }
        let skipsTranscription = TeddyShrug.shouldSkipTranscription(
            isCommandMode: sessionIntent.isCommandMode,
            recordedSeconds: recordedSeconds,
            heardSpeechSeconds: silenceAutoStop?.heardSpeechSeconds ?? 0,
            peakDB: silenceAutoStop?.peakDB ?? 0,
            whisperMode: whisperModeEnabled
        )
        stopSilenceAutoStop()
        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        debugStatusMessage = "Preparing audio"
        let contextGeneration = contextCaptureGeneration
        let sessionContext = capturedContext
        // Names on screen, only when the context summary is already in: never waits for it.
        let screenNameTerms = contextCaptureEnabled && screenNamesVocabularyEnabled
            ? ContextVocabularyCore.terms(fromSummary: sessionContext?.contextSummary ?? "")
            : []
        let inFlightContextTask = contextCaptureTask
        capturedContext = nil
        // Keep the handle so disabling context or cancelling transcription can cancel it.
        lastRawTranscript = ""
        lastPostProcessedTranscript = ""
        lastContextSummary = ""
        lastPostProcessingStatus = ""
        lastPostProcessingPrompt = ""
        lastContextScreenshotDataURL = nil
        lastContextScreenshotStatus = "No screenshot"
        isRecording = false
        restoreAudioInterruptionIfNeeded()
        isTranscribing = true
        statusText = "Preparing audio..."
        errorMessage = nil
        playAlertSound(named: "Pop")
        if skipsTranscription {
            if isRioActionSession { setRioActionPhase(.idle) }
            tearDownRealtimeService()
            inFlightContextTask?.cancel()
            contextCaptureTask = nil
            audioRecorder.stopRecording { [weak self] _ in self?.finishWithoutTranscribing() }
            return
        }
        overlayManager.showTranscribing()
        audioRecorder.stopRecording { [weak self] fileURL in
            guard let self else { return }
            guard let fileURL else {
                self.isTranscribing = false
                self.audioRecorder.cleanupWithoutWaiting()
                self.endCriticalDictationActivity()
                self.errorMessage = "No audio recorded"
                self.statusText = "Error"
                self.overlayManager.dismiss()
                self.refreshAvailableMicrophonesIfNeeded()
                return
            }

            guard self.isTranscribing else {
                self.tearDownRealtimeService()
                self.audioRecorder.cleanup()
                self.refreshAvailableMicrophonesIfNeeded()
                return
            }

            let savedAudioFile = Self.saveAudioFile(from: fileURL)
            let transcriptionFileURL = savedAudioFile?.fileURL ?? fileURL
            self.transcribingAudioFileName = savedAudioFile?.fileName
            self.statusText = "Transcribing..."
            self.debugStatusMessage = "Transcribing audio"

        let postProcessingService = PostProcessingService(
            apiKey: apiKey,
            baseURL: apiBaseURL,
            preferredModel: postProcessingModel,
            preferredFallbackModel: postProcessingFallbackModel,
            instructionExecutionGuardEnabled: instructionExecutionGuardEnabled
        )

            let activeRealtime = self.realtimeService
            self.realtimeService = nil
            self.audioRecorder.onPCM16Samples = nil
            self.stopLanguageProbe()
            self.transcriptionTask?.cancel()
            // An action session biases Whisper toward commands and the apps on this Mac.
            let promptContextTerms = isRioActionSession ? self.rioCommandPromptTerms() : screenNameTerms
            guard self.isTranscribing else {
                if let savedAudioFile {
                    Self.deleteAudioFile(savedAudioFile.fileName)
                }
                self.transcribingAudioFileName = nil
                activeRealtime?.cancel()
                self.audioRecorder.cleanup()
                self.endCriticalDictationActivity()
                self.refreshAvailableMicrophonesIfNeeded()
                return
            }
            self.transcriptionTask = Task {
                defer {
                    activeRealtime?.cancel()
                }
                do {
                    // Offline, an action key session is transcribed on this Mac so the built-in
                    // commands keep working. Fn dictation is unchanged.
                    if isRioActionSession, !NetworkMonitor.shared.isOnline {
                        try await self.finishRioActionSessionOffline(
                            fileURL: transcriptionFileURL, savedAudioFileName: savedAudioFile?.fileName
                        )
                        return
                    }
                    // The saved recording stays untouched; only a temporary boosted copy is transcribed.
                    let boostedFileURL = boostsQuietSpeech ? Self.whisperBoostedCopy(of: transcriptionFileURL) : nil
                    defer { Self.removeTemporaryAudio(boostedFileURL) }
                    let transcriptionService = try self.makeTranscriptionService(contextTerms: promptContextTerms)
                    async let transcript = Self.resolveRawTranscript(
                        realtimeService: activeRealtime,
                        fileService: transcriptionService,
                        fileURL: boostedFileURL ?? transcriptionFileURL
                    )
                    let rawTranscript = try await transcript
                    // Nil when the realtime stream supplied the transcript (no prompt involved).
                    let vocabularyStatus = transcriptionService.vocabularyReport?.statusSuffix ?? ""
                    // Whisper's inventions for quiet audio ("Thanks for watching", subtitle credits,
                    // "We are hoping for a win") are never typed and never run as a command.
                    if WhisperHallucinationGuard.isHallucination(rawTranscript, evidence: speechEvidence) {
                        try Task.checkCancellation()
                        await MainActor.run { [weak self] in
                            self?.finishHallucinatedTranscript(
                                rawTranscript,
                                isRioActionSession: isRioActionSession,
                                savedAudioFileName: savedAudioFile?.fileName,
                                vocabularyStatus: vocabularyStatus
                            )
                        }
                        return
                    }
                    if isRioActionSession {
                        try Task.checkCancellation()
                        await MainActor.run { [weak self] in
                            self?.finishRioActionSession(
                                transcript: rawTranscript, savedAudioFileName: savedAudioFile?.fileName
                            )
                        }
                        return
                    }
                    let parsedTranscript = Self.parseTranscriptCommands(
                        from: rawTranscript,
                        pressEnterCommandEnabled: self.isPressEnterVoiceCommandEnabled
                    )
                    try Task.checkCancellation()
                    if let look = SpokenLook.detect(in: parsedTranscript.transcript) {
                        await MainActor.run { [weak self] in self?.applySpokenLook(look) }
                    }
                    if !sessionIntent.isCommandMode, let trick = TeddyCommand.trick(in: parsedTranscript.transcript) {
                        await MainActor.run { [weak self] in
                            self?.finishWithTeddyTrick(trick, savedAudioFileName: savedAudioFile?.fileName)
                        }
                        return
                    }
                    // Capture the parsed raw transcript as lastTranscript before
                    // post-processing runs. If anything after this throws or focus
                    // shifts mid-paste, the Paste Again shortcut still has the raw
                    // text instead of the previous dictation's stale value.
                    let bootstrapTranscript = parsedTranscript.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !bootstrapTranscript.isEmpty {
                        await MainActor.run { [weak self] in
                            self?.lastTranscript = bootstrapTranscript
                        }
                    }
                    let appContext = await self.contextForTranscription(sessionContext, task: inFlightContextTask)
                    try Task.checkCancellation()
                    await MainActor.run { [weak self] in
                        self?.debugStatusMessage = "Running post-processing"
                    }
                    let result = await self.processTranscript(
                        parsedTranscript.transcript,
                        intent: sessionIntent,
                        context: appContext,
                        postProcessingService: postProcessingService,
                        customVocabulary: self.customVocabulary,
                        customSystemPrompt: textRules.systemPrompt,
                        outputLanguage: self.outputLanguage,
                        dictationLanguage: Self.dictationLanguageName(for: self.transcriptionLanguage),
                        preserveExactWording: self.preserveExactWording,
                        contextGeneration: contextGeneration,
                        textRules: textRules
                    )
                    try Task.checkCancellation()

                    await MainActor.run {
                        guard self.isTranscribing else { return }
                        let publication = self.contextForPublication(
                            appContext, prompt: result.prompt, generation: contextGeneration
                        )
                        let appContext = publication.context
                        self.lastContextSummary = appContext.contextSummary
                        self.lastContextScreenshotDataURL = appContext.screenshotDataURL
                        self.lastContextScreenshotStatus = appContext.screenshotError
                            ?? "available (\(appContext.screenshotMimeType ?? "image"))"
                        self.lastContextAppName = appContext.appName ?? ""
                        self.lastContextBundleIdentifier = appContext.bundleIdentifier ?? ""
                        self.lastContextWindowTitle = appContext.windowTitle ?? ""
                        self.lastContextSelectedText = appContext.selectedText ?? ""
                        self.lastContextLLMPrompt = appContext.contextPrompt ?? ""
                        let trimmedRawTranscript = parsedTranscript.transcript
                        let trimmedFinalTranscript = result.finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                        let processingStatus = Self.statusMessage(
                            for: result.outcome,
                            parsedTranscript: parsedTranscript
                        )
                        self.lastPostProcessingPrompt = publication.prompt
                        self.lastRawTranscript = trimmedRawTranscript
                        self.lastPostProcessedTranscript = trimmedFinalTranscript
                        self.lastPostProcessingStatus = processingStatus
                        self.recordPipelineHistoryEntry(
                            rawTranscript: trimmedRawTranscript,
                            postProcessedTranscript: trimmedFinalTranscript,
                            postProcessingPrompt: publication.prompt,
                            systemPrompt: Self.resolvedSystemPrompt(textRules.systemPrompt),
                            context: appContext,
                            processingStatus: processingStatus,
                            intent: sessionIntent,
                            audioFileName: savedAudioFile?.fileName,
                            debugStatusSuffix: vocabularyStatus
                        )
                        self.transcriptionTask = nil
                        self.transcribingAudioFileName = nil
                        self.lastTranscript = trimmedFinalTranscript
                        self.isTranscribing = false
                        self.endCriticalDictationActivity()
                        self.debugStatusMessage = "Done"
                        let completionStatusText = self.preserveClipboard ? "Pasted at cursor!" : "Copied to clipboard!"
                        let enterOnlyStatusText = "Pressed Enter"
                        let shouldPressEnterAfterPaste = parsedTranscript.shouldPressEnterAfterPaste

                        let shouldPersistRawDictationFallback: Bool
                        switch result.outcome {
                        case .postProcessingFailedFallback,
                             .preservedExactWordingTranslationFailedFallback:
                            shouldPersistRawDictationFallback = !trimmedFinalTranscript.isEmpty
                        default:
                            shouldPersistRawDictationFallback = false
                        }

                        if trimmedFinalTranscript.isEmpty {
                            self.statusText = shouldPressEnterAfterPaste ? enterOnlyStatusText : "Nothing to transcribe"
                            self.clearPendingOverlayDismissToken()
                            self.showClosingMoment(shouldPressEnterAfterPaste ? .sent : .didntCatchThat)
                            if shouldPressEnterAfterPaste {
                                if useOriginalFieldInsertion {
                                    if let textInsertionTarget {
                                        self.pressEnterWhenShortcutReleased(target: textInsertionTarget)
                                    } else {
                                        let status = "Original field unavailable — Enter skipped"
                                        self.statusText = status
                                        self.scheduleReadyStatusReset(after: 3, matching: [status])
                                    }
                                } else {
                                    self.pressEnterWhenShortcutReleased()
                                }
                            }
                        } else {
                            self.statusText = completionStatusText
                            if shouldPersistRawDictationFallback {
                                self.scheduleOverlayDismissAfterFailureIndicator(after: 2.5)
                            } else {
                                self.clearPendingOverlayDismissToken()
                                if shouldPressEnterAfterPaste {
                                    self.showClosingMoment(.sent)
                                } else {
                                    self.overlayManager.dismiss()
                                    // The previous edit's sign, held back while this dictation ran.
                                    if let moment = self.deferredLearnMoment.take() { self.showTeddyMoment(moment) }
                                }
                            }

                            if !sessionIntent.isCommandMode { self.lastDictatedText = trimmedFinalTranscript }
                            // Edit Mode replaces a selection and Enter sends the text: neither can be undone here.
                            self.recordInsertionForUndo(
                                sessionIntent.isCommandMode || shouldPressEnterAfterPaste ? nil : trimmedFinalTranscript,
                                processIdentifier: useOriginalFieldInsertion ? textInsertionTarget?.processIdentifier : nil
                            )
                            self.insertTranscriptWhenShortcutReleased(
                                trimmedFinalTranscript, target: textInsertionTarget,
                                shouldPressEnter: shouldPressEnterAfterPaste,
                                useOriginalField: useOriginalFieldInsertion
                            )
                            // A message sent with Enter leaves nothing to correct, and Edit Mode
                            // output is a rewrite of the user's own text, not a dictation to learn from.
                            if self.learnFromCorrectionsEnabled && !shouldPressEnterAfterPaste && !sessionIntent.isCommandMode {
                                self.correctionWatcher.start(transcript: trimmedFinalTranscript)
                            }
                            self.recordUsage(spokenText: trimmedRawTranscript, seconds: recordedSeconds)
                        }

                        self.audioRecorder.cleanup()
                        self.refreshAvailableMicrophonesIfNeeded()

                        self.scheduleReadyStatusReset(after: 3, matching: [completionStatusText, "Nothing to transcribe", enterOnlyStatusText, "Didn't catch that"])
                    }
                } catch is CancellationError {
                    await MainActor.run {
                        self.transcriptionTask = nil
                        self.endCriticalDictationActivity()
                    }
                } catch {
                    let resolvedContext = await self.contextForTranscription(sessionContext, task: inFlightContextTask)
                    await MainActor.run {
                        guard self.isTranscribing else { return }
                        let resolvedContext = self.contextForPublication(
                            resolvedContext, prompt: "", generation: contextGeneration
                        ).context
                        self.transcriptionTask = nil
                        self.transcribingAudioFileName = nil
                        let userFacingErrorMessage = self.formattedTranscriptionError(error)
                        let shrugs = TeddyShrug.shouldShrugOnError(
                            recordedSeconds: recordedSeconds, errorDescription: error.localizedDescription
                        )
                        self.errorMessage = shrugs ? nil : userFacingErrorMessage
                        self.isTranscribing = false
                        self.endCriticalDictationActivity()
                        if shrugs {
                            // A tap or very short recording the provider rejected: no red error.
                            self.statusText = "Didn't catch that"
                            self.showClosingMoment(.didntCatchThat)
                        } else {
                            self.statusText = "Error"
                            self.overlayManager.showError(userFacingErrorMessage)
                        }
                        self.lastPostProcessedTranscript = ""
                        self.lastRawTranscript = ""
                        self.lastContextSummary = ""
                        self.lastPostProcessingStatus = "Error: \(error.localizedDescription)"
                        self.lastPostProcessingPrompt = ""
                        self.lastContextScreenshotDataURL = resolvedContext.screenshotDataURL
                        self.lastContextScreenshotStatus = resolvedContext.screenshotError
                            ?? "available (\(resolvedContext.screenshotMimeType ?? "image"))"
                        self.recordPipelineHistoryEntry(
                            rawTranscript: "",
                            postProcessedTranscript: "",
                            postProcessingPrompt: "",
                            systemPrompt: Self.resolvedSystemPrompt(self.customSystemPrompt),
                            context: resolvedContext,
                            processingStatus: "Error: \(error.localizedDescription)",
                            intent: sessionIntent,
                            audioFileName: savedAudioFile?.fileName
                        )
                        self.audioRecorder.cleanup()
                        self.refreshAvailableMicrophonesIfNeeded()
                    }
                }
            }
        }
    }

    static func resolvedSystemPrompt(_ customSystemPrompt: String) -> String {
        customSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? PostProcessingService.defaultSystemPrompt
            : customSystemPrompt
    }

    private func recordPipelineHistoryEntry(
        rawTranscript: String,
        postProcessedTranscript: String,
        postProcessingPrompt: String,
        systemPrompt: String,
        context: AppContext,
        processingStatus: String,
        intent: SessionIntent,
        audioFileName: String? = nil,
        debugStatusSuffix: String = ""
    ) {
        let newEntry = PipelineHistoryItem(
            intent: intent.persistedIntent,
            selectedText: intent.persistedSelectedText,
            capturedSelection: context.selectedText,
            timestamp: Date(),
            rawTranscript: rawTranscript,
            postProcessedTranscript: postProcessedTranscript,
            postProcessingPrompt: postProcessingPrompt,
            systemPrompt: systemPrompt,
            contextSummary: context.contextSummary,
            contextSystemPrompt: context.contextSystemPrompt,
            contextPrompt: context.contextPrompt,
            contextScreenshotDataURL: context.screenshotDataURL,
            contextScreenshotStatus: context.screenshotError
                ?? "available (\(context.screenshotMimeType ?? "image"))",
            postProcessingStatus: processingStatus,
            debugStatus: debugStatusMessage + debugStatusSuffix,
            customVocabulary: customVocabulary,
            audioFileName: audioFileName,
            contextAppName: context.appName,
            contextBundleIdentifier: context.bundleIdentifier,
            contextWindowTitle: context.windowTitle
        )
        do {
            let removedAudioFileNames = try pipelineHistoryStore.append(newEntry, maxCount: maxPipelineHistoryCount)
            for audioFileName in removedAudioFileNames {
                Self.deleteAudioFile(audioFileName)
            }
            pipelineHistory = pipelineHistoryStore.loadAllHistory()
        } catch {
            errorMessage = "Unable to save run history entry: \(error.localizedDescription)"
        }
    }

    private func startRealtimeStreamingIfEnabled() {
        // Whisper mode boosts the finished file, so it must be transcribed from that file.
        guard realtimeStreamingEnabled, !whisperModeEnabled else { return }
        let trimmedBase = resolvedTranscriptionBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty else {
            os_log(.info, log: recordingLog, "realtime streaming requested but base URL is empty — skipping")
            return
        }
        let model = realtimeStreamingModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = RealtimeTranscriptionService.Configuration(
            baseURL: trimmedBase,
            apiKey: resolvedTranscriptionAPIKey,
            model: model,
            language: resolvedTranscriptionLanguage
        )
        let service = RealtimeTranscriptionService(config: config)
        do {
            try service.start()
        } catch {
            os_log(.error, log: recordingLog, "failed to start realtime service: %{public}@", error.localizedDescription)
            return
        }
        realtimeService = service
        audioRecorder.onPCM16Samples = { [weak service] data in
            service?.appendPCM16(data)
        }
    }

    private func tearDownRealtimeService() {
        audioRecorder.onPCM16Samples = nil
        realtimeService?.cancel()
        realtimeService = nil
        stopLanguageProbe()
    }

    /// While you speak, checks the language of short clips so Rio's pill outfit can change
    /// mid-dictation. Only with Auto-detect: a language picked in Settings already decides.
    private func startLanguageProbeIfNeeded() {
        stopLanguageProbe()
        let baseURL = resolvedTranscriptionBaseURL
        let key = resolvedTranscriptionAPIKey
        guard resolvedTranscriptionLanguage == nil, !key.isEmpty,
              !LanguageProbeService.isPausedForRateLimit,
              let endpoint = LanguageProbeCore.endpoint(baseURL: baseURL) else { return }
        let config = LanguageProbeService.Configuration(
            endpoint: endpoint,
            apiKey: key,
            model: LanguageProbeCore.probeModel(baseURL: baseURL, configuredModel: transcriptionModel)
        )
        let probe = LanguageProbeService(config: config) { [weak self] look in
            guard let self, self.isRecording else { return }
            self.lastSpokenLook = look
            self.overlayManager.setSpokenLook(look)
        }
        languageProbe = probe
        // Shares the tap with realtime streaming when that is on.
        let previous = audioRecorder.onPCM16Samples
        audioRecorder.onPCM16Samples = { [weak probe] data in
            previous?(data)
            probe?.append(data)
        }
    }

    private func stopLanguageProbe() {
        languageProbe?.stop()
        languageProbe = nil
    }

    private func startContextCapture() {
        guard contextCaptureEnabled else { return }
        contextCaptureTask?.cancel()
        capturedContext = nil
        lastContextSummary = "Collecting app context..."
        lastPostProcessingStatus = ""
        lastContextScreenshotDataURL = nil
        lastContextScreenshotStatus = "Collecting screenshot..."

        contextCaptureTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return nil }
            let context = await self.contextService.collectContext()
            guard !Task.isCancelled else { return nil }
            return await MainActor.run {
                guard !Task.isCancelled, self.contextCaptureEnabled else { return nil }
                self.capturedContext = context
                self.lastContextSummary = context.contextSummary
                self.lastContextScreenshotDataURL = context.screenshotDataURL
                self.lastContextScreenshotStatus = context.screenshotError
                    ?? "available (\(context.screenshotMimeType ?? "image"))"
                self.lastContextAppName = context.appName ?? ""
                self.lastContextBundleIdentifier = context.bundleIdentifier ?? ""
                self.lastContextWindowTitle = context.windowTitle ?? ""
                self.lastContextSelectedText = context.selectedText ?? ""
                self.lastContextLLMPrompt = context.contextPrompt ?? ""
                self.lastPostProcessingStatus = "App context captured"
                self.handleScreenshotCaptureIssue(context.screenshotError)
                return context
            }
        }
    }

    private func contextForTranscription(
        _ snapshot: AppContext?, task: Task<AppContext?, Never>?
    ) async -> AppContext {
        guard contextCaptureEnabled, task?.isCancelled != true else { return Self.disabledContext() }
        let context: AppContext?
        if let snapshot {
            context = snapshot
        } else {
            context = await task?.value
        }
        // The preference can change while waiting, including off and back on.
        guard contextCaptureEnabled, task?.isCancelled != true else { return Self.disabledContext() }
        return context ?? fallbackContextAtStop()
    }

    // Recheck each cleanup/Edit Mode request, including fallback attempts.
    @MainActor
    private func contextSummaryForRequest(_ context: AppContext, generation: UUID) -> String {
        guard contextCaptureEnabled, generation == contextCaptureGeneration else { return "" }
        return context.summaryForPostProcessing
    }

    /// Rechecks invalidation after processing, before context or derived prompts enter UI/history.
    private func contextForPublication(
        _ context: AppContext, prompt: String, generation: UUID
    ) -> (context: AppContext, prompt: String) {
        guard contextCaptureEnabled, generation == contextCaptureGeneration else {
            return (Self.disabledContext(), "")
        }
        return (context, prompt)
    }

    private static func disabledContext() -> AppContext {
        AppContext(
            appName: nil,
            bundleIdentifier: nil,
            windowTitle: nil,
            selectedText: nil,
            currentActivity: "Active window context disabled.",
            contextSystemPrompt: nil,
            contextPrompt: nil,
            screenshotDataURL: nil,
            screenshotMimeType: nil,
            screenshotError: "Disabled in Settings"
        )
    }

    private func fallbackContextAtStop() -> AppContext {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let windowTitle = focusedWindowTitle(for: frontmostApp)
        return AppContext(
            appName: frontmostApp?.localizedName,
            bundleIdentifier: frontmostApp?.bundleIdentifier,
            windowTitle: windowTitle,
            selectedText: nil,
            currentActivity: "Could not refresh app context at stop time; using text-only post-processing.",
            contextSystemPrompt: resolvedContextSystemPrompt(),
            contextPrompt: nil,
            screenshotDataURL: nil,
            screenshotMimeType: nil,
            screenshotError: "No app context captured before stop"
        )
    }

    private func resolvedContextSystemPrompt() -> String {
        let trimmedPrompt = customContextPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPrompt.isEmpty ? AppContextService.defaultContextPrompt : trimmedPrompt
    }

    private func focusedWindowTitle(for app: NSRunningApplication?) -> String? {
        guard let app else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        return focusedWindowTitle(from: appElement)
    }

    private func focusedWindowTitle(from appElement: AXUIElement) -> String? {
        guard let focusedWindow = accessibilityElement(from: appElement, attribute: kAXFocusedWindowAttribute as CFString) else {
            return nil
        }

        guard let windowTitle = accessibilityString(from: focusedWindow, attribute: kAXTitleAttribute as CFString) else {
            return nil
        }

        return trimmedText(windowTitle)
    }

    private func accessibilityElement(from element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(rawValue, to: AXUIElement.self)
    }

    private func accessibilityString(from element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let stringValue = value as? String else { return nil }
        return stringValue
    }

    private func trimmedText(_ value: String) -> String? {
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return trimmed.isEmpty ? nil : trimmed
    }

    private func handleScreenshotCaptureIssue(_ message: String?) {
        guard let message, !message.isEmpty else {
            hasShownScreenshotPermissionAlert = false
            return
        }

        os_log(.error, "Screenshot capture issue: %{public}@", message)

        if isScreenCapturePermissionError(message) && !hasShownScreenshotPermissionAlert {
            hasScreenRecordingPermission = false
            guard currentSessionIntent.isCommandMode else { return }
            errorMessage = message
            hasShownScreenshotPermissionAlert = true

            // Permission errors are fatal — stop recording
            tearDownRealtimeService()
            audioRecorder.cancelRecording()
            stopSilenceAutoStop()
            audioLevelCancellable?.cancel()
            audioLevelCancellable = nil
            contextCaptureTask?.cancel()
            contextCaptureTask = nil
            capturedContext = nil
            isRecording = false
            restoreAudioInterruptionIfNeeded()
            shortcutSessionController.reset()
            clearRioActionSession()
            activeRecordingTriggerMode = nil
            activeTextInsertionTarget = nil
            endCriticalDictationActivity()
            statusText = "Screenshot Required"
            overlayManager.dismiss()

            playAlertSound(named: "Basso")
            showScreenshotPermissionAlert(message: message)
        }
        // Non-permission errors (transient failures) — continue recording without context
    }

    private func isScreenCapturePermissionError(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("screen recording permission not granted")
            || lowered.contains("requires screen recording permission")
    }

    private func showScreenshotPermissionAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "\(message)\n\n\(AppName.displayName) requires Screen Recording permission to capture screenshots for context-aware transcription.\n\nGo to System Settings > Privacy & Security > Screen Recording and enable \(AppName.displayName)."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")
        alert.icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openScreenCaptureSettings()
        }
    }

    private func showScreenshotCaptureErrorAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Screenshot Capture Failed"
        alert.informativeText = "\(message)\n\nA screenshot is required for context-aware transcription. Recording has been stopped."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Dismiss")
        alert.icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
        _ = alert.runModal()
    }

    func toggleDebugOverlay() {
        if isDebugOverlayActive {
            stopDebugOverlay()
        } else {
            startDebugOverlay()
        }
    }

    private func startDebugOverlay() {
        isDebugOverlayActive = true
        clearPendingOverlayDismissToken()
        overlayManager.showRecording(
            showsRecordingTimer:
                RecordingTimerPreference.load(from: .standard)
        )

        // Simulate audio levels with a timer
        var phase: Double = 0.0
        debugOverlayTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            phase += 0.15
            // Generate a fake audio level that oscillates like speech
            let base = 0.3 + 0.2 * sin(phase)
            let noise = Float.random(in: -0.15...0.15)
            let level = min(max(Float(base) + noise, 0.0), 1.0)
            self.overlayManager.updateAudioLevel(level)
        }
    }

    private func stopDebugOverlay() {
        debugOverlayTimer?.invalidate()
        debugOverlayTimer = nil
        isDebugOverlayActive = false
        clearPendingOverlayDismissToken()
        overlayManager.dismiss()
    }

    private func clearPendingOverlayDismissToken() {
        pendingOverlayDismissToken = nil
    }

    /// Shows a bear moment (learned words, milestone, undone) unless a dictation or one of
    /// the bear's tricks is using the pill.
    func showTeddyMoment(_ moment: TeddyMoment) {
        guard !isRecording, !isTranscribing, !teddyTrip.isRunning, pendingOverlayDismissToken == nil else { return }
        overlayManager.showMoment(moment)
    }

    /// A moment that closes a dictation (didn't catch that, sent). It replaces the
    /// transcribing pill right away; a newly started recording is never interrupted.
    private func showClosingMoment(_ moment: TeddyMoment) {
        guard !isRecording, !teddyTrip.isRunning else { return overlayManager.dismiss() }
        overlayManager.showMoment(moment, interruptsTranscribing: true)
    }

    /// A recording with nothing in it (a tap of the shortcut, or silence): nothing is sent
    /// or saved, and the bear shrugs instead of the provider's error showing.
    /// The transcript looked like one of Whisper's stock inventions for audio with no speech: say
    /// "I didn't catch that" and type or run nothing. A dictation keeps its recording and goes to
    /// history (marked as not typed), so a wrong call can still be recovered from there. An action
    /// session stores no audio, as always.
    @MainActor private func finishHallucinatedTranscript(
        _ rawTranscript: String, isRioActionSession: Bool, savedAudioFileName: String?, vocabularyStatus: String
    ) {
        guard isTranscribing else { return }
        if isRioActionSession {
            failRioActionSession(RioActionText.didntCatchMessage, savedAudioFileName: savedAudioFileName)
            return
        }
        recordPipelineHistoryEntry(
            rawTranscript: rawTranscript,
            postProcessedTranscript: "",
            postProcessingPrompt: "",
            systemPrompt: "",
            context: AppContext(
                appName: nil, bundleIdentifier: nil, windowTitle: nil, selectedText: nil,
                currentActivity: "", contextSystemPrompt: nil, contextPrompt: nil,
                screenshotDataURL: nil, screenshotMimeType: nil, screenshotError: "not captured"
            ),
            processingStatus: "Not typed: it looked like Whisper inventing words for quiet audio",
            intent: .dictation,
            audioFileName: savedAudioFileName,
            debugStatusSuffix: vocabularyStatus
        )
        finishWithoutTranscribing()
    }

    /// Command verbs plus the apps running now and installed, for the action key's Whisper prompt.
    private func rioCommandPromptTerms() -> [String] {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
        let installed = RioInstalledApps.shared.cachedApps?.map(\.name) ?? []
        return RioCommandPrompt.terms(runningAppNames: running, installedAppNames: installed)
    }

    private func finishWithoutTranscribing() {
        guard isTranscribing else { return }
        transcriptionTask = nil
        transcribingAudioFileName = nil
        isTranscribing = false
        endCriticalDictationActivity()
        // The microphone may still be shutting down; don't block the main thread on it.
        audioRecorder.cleanupWithoutWaiting()
        refreshAvailableMicrophonesIfNeeded()
        debugStatusMessage = "Done"
        let status = "Didn't catch that"
        statusText = status
        scheduleReadyStatusReset(after: 3, matching: [status])
        clearPendingOverlayDismissToken()
        showClosingMoment(.didntCatchThat)
    }

    private static let teddyRestSeconds: TimeInterval = 0.8

    private static func teddyStatusText(for trick: TeddyTrick) -> String {
        switch trick {
        case .goCrazy: return "Rio went crazy"
        case .wiggle: return "Rio did a wiggle"
        case .dougie: return "Rio hit the Dougie"
        }
    }

    /// Puts the detected language's look on the pill (still showing while the text is
    /// processed) and remembers it for the next dictation.
    private func applySpokenLook(_ look: SpokenLook) {
        lastSpokenLook = look
        overlayManager.setSpokenLook(SpokenLook.forLanguage(transcriptionLanguage) ?? look)
    }

    // MARK: Rio actions (Fn + Control)

    /// True while the action key is (or was just) held for a hold session.
    private func isRioActionKeyHeld(triggerMode: RecordingTriggerMode) -> Bool {
        guard triggerMode == .hold else { return false }
        let actionModifiers = activeShortcutConfiguration.holdActionModifiers
        guard !actionModifiers.isEmpty else { return false }
        return rioActionSessionRequested
            || !hotkeyManager.currentPressedModifiers.isDisjoint(with: actionModifiers)
    }

    private func beginRioActionSessionIfHolding() {
        guard rioActionsEnabled, shortcutSessionController.activeMode == .hold else { return }
        rioActionSessionRequested = true
        // The action key also stops a running multi-step task, after a moment: Fn, Control, Option
        // in that order is the conversation chord, which must leave the task running.
        rioPendingTaskStop?.cancel()
        let stop = DispatchWorkItem { [weak self] in self?.stopRunningTaskForActionKey() }
        rioPendingTaskStop = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rioTaskStopChordWait, execute: stop)
        setRioActionPhase(.listening)
    }

    /// Longer than the gap between the chord's keys, shorter than saying a command.
    private static let rioTaskStopChordWait: TimeInterval = 0.35

    private func stopRunningTaskForActionKey() {
        rioPendingTaskStop?.cancel()
        rioPendingTaskStop = nil
        guard rioActionSessionRequested else { return }
        MainActor.assumeIsolated { if RioTaskProgress.shared.isRunning { RioTaskActionHandler.shared.stop() } }
    }

    /// Drops a pending action request (session cancelled or never started).
    private func clearRioActionSession() {
        rioPendingTaskStop?.cancel()
        rioPendingTaskStop = nil
        rioActionSessionRequested = false
        if rioActionPhase == .listening { setRioActionPhase(.idle) }
    }

    /// Publishes the phase; results fall back to `.idle` after a moment, and `.listening` can
    /// never stay stuck if the session ended without a transcription.
    private func setRioActionPhase(_ phase: RioActionPhase) {
        let token = UUID()
        rioActionPhaseToken = token
        rioActionPhase = phase
        let delay: TimeInterval
        switch phase {
        case .idle, .working: return
        case .listening: delay = Self.rioActionListeningSafetySeconds
        case .succeeded, .failed: delay = Self.rioActionResultSeconds
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.rioActionPhaseToken == token else { return }
            if phase == .listening, self.isRecording || self.isTranscribing { return }
            self.rioActionPhase = .idle
        }
    }

    private static let rioActionResultSeconds: TimeInterval = 2.5
    private static let rioActionListeningSafetySeconds: TimeInterval = 30

    /// The transcript of an action session: a Teddy trick (name optional) or a command.
    /// Nothing is typed, pasted, saved as the last transcript or fed to the correction learner.
    private func finishRioActionSession(transcript: String, savedAudioFileName: String?) {
        guard isTranscribing else { return }
        let spokenCommand = RioActionTranscript.stripName(from: transcript)
        if !spokenCommand.isEmpty, let trick = TeddyCommand.trick(in: "Rio \(spokenCommand)") {
            setRioActionPhase(.idle)
            finishWithTeddyTrick(trick, savedAudioFileName: savedAudioFileName)
            return
        }

        transcriptionTask = nil
        transcribingAudioFileName = nil
        isTranscribing = false
        endCriticalDictationActivity()
        if let savedAudioFileName {
            Self.deleteAudioFile(savedAudioFileName)
        }
        audioRecorder.cleanup()
        refreshAvailableMicrophonesIfNeeded()
        debugStatusMessage = "Done"
        guard !spokenCommand.isEmpty else {
            setRioActionPhase(.idle)
            statusText = "Ready"
            clearPendingOverlayDismissToken()
            overlayManager.dismiss()
            return
        }
        statusText = "Working..."
        setRioActionPhase(.working("Working on it"))
        clearPendingOverlayDismissToken()
        overlayManager.dismiss()

        Task { @MainActor [weak self] in
            await self?.runRioCommand(transcript, source: .actionKey)
        }
    }

    /// Entry point for commands that don't come from the keyboard or the mic: scheduled commands,
    /// triggers and macros (`.automation`) and texts from the owner's iPhone (`.phone`). They wait
    /// their turn while Rio is busy (see `RioWaitingCommands`) instead of being refused.
    @MainActor func runRioCommandText(_ text: String, source: RioCommandSource) {
        enqueueRioCommand(text, source: source, reply: nil)
    }

    /// Like `runRioCommandText`, and returns this command's own result (never another command's):
    /// the phone texts it back. Nil when the command was dropped without running.
    @MainActor func runRioCommandForReply(_ text: String, source: RioCommandSource) async -> (message: String, succeeded: Bool)? {
        await withCheckedContinuation { continuation in
            enqueueRioCommand(text, source: source) { continuation.resume(returning: $0) }
        }
    }

    @MainActor private func enqueueRioCommand(
        _ text: String, source: RioCommandSource, reply: (@MainActor ((message: String, succeeded: Bool)?) -> Void)?
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            reply?(nil)
            return
        }
        let now = Date()
        let command = RioWaitingCommand(text: trimmed, source: source, since: now, reply: reply)
        guard rioWaitingCommands.add(command, at: now) else {
            noteDroppedRioCommand(command, reason: "Rio was busy and too many commands were waiting")
            return
        }
        drainRioWaitingCommands()
    }

    /// True while a waiting command must not start: something else has the pipeline, the
    /// microphone or the screen.
    @MainActor private var isRioBusyForWaitingCommands: Bool {
        isRioCommandRunning || isStartingWaitingRioCommand || isRecording || isTranscribing
            || pendingShortcutStartMode != nil
            || RioConfirmationCenter.shared.isShowing || RioTaskProgress.shared.isRunning
    }

    /// Runs the next waiting command once Rio is free, and checks again every second while any wait.
    @MainActor private func drainRioWaitingCommands() {
        rioWaitingCommandsDrain?.cancel()
        rioWaitingCommandsDrain = nil
        while true {
            switch rioWaitingCommands.next(now: Date(), isBusy: isRioBusyForWaitingCommands) {
            case .wait:
                guard !rioWaitingCommands.isEmpty else { return }
                let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.drainRioWaitingCommands() } }
                rioWaitingCommandsDrain = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
                return
            case .expired(let command):
                noteDroppedRioCommand(command, reason: "Rio was busy for too long")
            case .run(let command):
                isStartingWaitingRioCommand = true
                Task { @MainActor [weak self] in
                    guard let self else {
                        command.reply?(nil)
                        return
                    }
                    self.isStartingWaitingRioCommand = false
                    // Something else started in the meantime (the action key): back to the front.
                    guard !self.isRioBusyForWaitingCommands else {
                        self.rioWaitingCommands.putBack(command, since: command.since)
                        self.drainRioWaitingCommands()
                        return
                    }
                    let result = await self.runRioCommand(command.text, source: command.source)
                    command.reply?(result.map { RioPhoneReply.message(for: $0.outcome, summary: $0.summary) })
                    self.drainRioWaitingCommands()
                }
                return
            }
        }
    }

    /// A waiting command that never ran: automations leave a note (no command text, which can be
    /// private) and the phone is told.
    @MainActor private func noteDroppedRioCommand(_ command: RioWaitingCommand, reason: String) {
        if command.source == .automation {
            let note = "\(reason), so a scheduled or triggered command was skipped."
            RioAutomationCenter.shared.store.addNote(note)
            RioAutomationCenter.shared.onNote?(note)
        }
        command.reply?((message: "\(reason), so I skipped that one. Try again?", succeeded: false))
    }

    /// Runs a spoken command (action key or conversation mode) and shows the result.
    /// "Stop listening" ends conversation mode directly. Only one command runs at a time.
    /// Returns how it ended and the line shown for it; nil when it was refused (another command
    /// was running).
    @discardableResult
    @MainActor private func runRioCommand(
        _ spokenTranscript: String, source: RioCommandSource
    ) async -> (outcome: RioActionOutcome, summary: String)? {
        guard !isRioCommandRunning else {
            finishRioAction(.failed("I'm still working on the last one"), transcript: "", actions: [])
            return nil
        }
        isRioCommandRunning = true
        defer {
            isRioCommandRunning = false
            if !rioWaitingCommands.isEmpty { DispatchQueue.main.async { [weak self] in self?.drainRioWaitingCommands() } }
        }
        // "Thanks", or a yes or no with nothing to confirm: answered here, with no model call.
        if let line = RioConversationCommands.quickReply(
            spokenTranscript, isConfirmationShowing: RioConfirmationCenter.shared.isShowing
        ) {
            RioPersonality.registerVerbatim(line)
            return finishRioAction(.succeeded(line), transcript: spokenTranscript)
        }
        // Arabic (or any non-English) commands become English before parsing: "ريو افتح كروم".
        // An Arabic stop ("ريو بس") is already understood here; the translator would lose it.
        let transcript = RioConversationCommands.bareStop(spokenTranscript) == .stop
            && RioConversationCommands.commandWords(spokenTranscript).contains(where: { !$0.allSatisfy(\.isASCII) })
            ? "stop"
            : await RioCommandTranslator.shared.englishCommand(from: spokenTranscript)
        if RioConversationCommands.isStopListening(transcript) {
            finishStopListening(transcript: transcript)
            return (.succeeded("Stopped listening"), "Stopped listening")
        }
        // "Rio, stop" while translating stops the translator (not a timer that isn't there).
        if RioConversationCommands.isBareStop(transcript), RioTranslatorMode.shared.isOn {
            RioTranslatorMode.shared.stop(.voice)
            return finishRioAction(.succeeded("Stopped translating"), transcript: transcript, actions: [.stopTranslation])
        }
        let coordinator = rioActionCoordinator ?? RioActionsWiring.makeCoordinator(
            companion: RioCompanionHub.shared,
            typeText: { [weak self] text in await self?.typeTextForRioAction(text) ?? false }
        )
        rioActionCoordinator = coordinator
        let outcome = await coordinator.run(transcript, source: source) { [weak self] line in
            self?.statusText = line
            self?.rioActionPhase = .working(line)
        }
        return finishRioAction(
            outcome, transcript: transcript, actions: coordinator.lastActions, unrecognized: coordinator.lastUnrecognized
        )
    }

    /// "Rio, stop listening", from either the action key or conversation mode: one history row.
    @MainActor private func finishStopListening(transcript: String) {
        RioConversationMode.shared.stop(.stopListening)
        statusText = "Stopped listening"
        setRioActionPhase(.succeeded("Stopped listening"))
        scheduleReadyStatusReset(after: 3, matching: ["Stopped listening"])
        recordRioActionHistory(transcript: transcript, actions: [], outcomeText: "Stopped listening", didSucceed: true)
    }

    /// A command heard by conversation mode. Answers to a pending confirmation and the stop
    /// commands are handled first, even while a command is running; anything else said while a
    /// command, a question or a recording is in progress is dropped.
    @MainActor private func handleConversationCommand(_ transcript: String) {
        if RioConfirmationCenter.shared.answerSpoken(transcript) { return }
        if RioConversationCommands.isStopListening(transcript) {
            finishStopListening(transcript: transcript)
            return
        }
        if let stop = RioConversationCommands.bareStop(transcript) {
            stopEverythingRioIsDoing(stop)
            return
        }
        guard !isRioCommandRunning, !RioConfirmationCenter.shared.isShowing,
              !RioTaskProgress.shared.isRunning, !isRecording, !isTranscribing else { return }
        statusText = "Working..."
        setRioActionPhase(.working("Working on it"))
        Task { @MainActor [weak self] in
            await self?.runRioCommand(transcript, source: .conversation)
        }
    }

    /// "Rio, stop": silences a ringing timer and ends a running task, the live translator and
    /// Rio's own voice. When none of those was going, a plain stop goes on to the parser's own
    /// stop handler (it pauses playing media and never cancels a running countdown); "wait" or
    /// "forget it" with nothing running does nothing.
    @MainActor private func stopEverythingRioIsDoing(_ kind: RioConversationCommands.BareStop) {
        var stoppedSomething = false
        if RioTimerCenter.shared.isRinging {
            RioTimerCenter.shared.stopRinging()
            stoppedSomething = true
        }
        if RioTaskProgress.shared.isRunning {
            RioTaskActionHandler.shared.stop()
            stoppedSomething = true
        }
        if RioTranslatorMode.shared.isOn {
            RioTranslatorMode.shared.stop(.voice)
            stoppedSomething = true
        }
        if RioVoice.shared.isSpeaking { stoppedSomething = true }
        RioVoice.shared.stopSpeaking()
        if !stoppedSomething, kind == .stop, !isRioCommandRunning, !RioConfirmationCenter.shared.isShowing,
           !isRecording, !isTranscribing {
            statusText = "Working..."
            setRioActionPhase(.working("Working on it"))
            Task { @MainActor [weak self] in await self?.runRioCommand("stop", source: .conversation) }
            return
        }
        let status = stoppedSomething ? "Stopped" : "Okay"
        statusText = status
        scheduleReadyStatusReset(after: 2, matching: [status])
    }

    /// Fn + Control while offline: transcribe the recording on-device, then run it as usual.
    @MainActor private func finishRioActionSessionOffline(fileURL: URL, savedAudioFileName: String?) async throws {
        do {
            let transcript = try await RioOfflineTranscriber.transcribe(fileURL: fileURL)
            try Task.checkCancellation()
            finishRioActionSession(transcript: transcript, savedAudioFileName: savedAudioFileName)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failure = (error as? RioOfflineTranscriber.Failure) ?? .failed
            try Task.checkCancellation()
            failRioActionSession(failure.message, savedAudioFileName: savedAudioFileName)
        }
    }

    /// Ends an action session that produced no usable transcript, with a short spoken reason.
    @MainActor private func failRioActionSession(_ message: String, savedAudioFileName: String?) {
        guard isTranscribing else { return }
        transcriptionTask = nil
        transcribingAudioFileName = nil
        isTranscribing = false
        endCriticalDictationActivity()
        if let savedAudioFileName { Self.deleteAudioFile(savedAudioFileName) }
        audioRecorder.cleanup()
        refreshAvailableMicrophonesIfNeeded()
        debugStatusMessage = "Done"
        clearPendingOverlayDismissToken()
        overlayManager.dismiss()
        finishRioAction(.failed(message), transcript: "", actions: [])
    }

    /// "Rio, type …": pastes into the frontmost app's focused field, restoring the clipboard after.
    private func typeTextForRioAction(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let pendingRestore = writeTranscriptToPasteboard(trimmed)
        pasteAtCursor(processIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        // The dictation path's timing: restoreClipboardIfNeeded waits clipboardRestoreDelay itself.
        restoreClipboardIfNeeded(pendingRestore)
        return true
    }

    /// Wires Rio's voice, conversation mode and task progress to AppState.
    @MainActor func bindRioCompanionState() {
        guard rioCompanionStateSubscriptions.isEmpty else { return }
        RioVoice.shared.isRioRecordingProvider = { [weak self] in self?.isRecording ?? false }
        // The corner bear observes RioVoice and RioCompanionCenter directly (no AppState mirrors,
        // which re-rendered every AppState view on each timer tick and voice frame).
        bindRioConversationMode()
        // Multi-step tasks narrate each step on the bear's card.
        let task = RioTaskProgress.shared
        task.$stepText.combineLatest(task.$stepNumber, task.$isRunning)
            .sink { [weak self] _, _, running in
                guard let self, running, let card = RioTaskProgress.shared.cardText else { return }
                self.rioActionPhase = .working(card)
            }
            .store(in: &rioCompanionStateSubscriptions)
    }

    /// Conversation mode hands commands to the action pipeline and steps aside while dictating.
    @MainActor private func bindRioConversationMode() {
        let mode = RioConversationMode.shared
        mode.onCommand = { [weak self] command in self?.handleConversationCommand(command) }
        mode.playSound = { [weak self] name in self?.playAlertSound(named: name) }
        mode.playChime = { [weak self] chime in self?.playAlertSound(data: chime.wavData()) }
        // While Rio himself is talking it keeps listening, but takes only a bare stop ("Rio,
        // stop", "Rio, shut up"), so he can be interrupted and his own voice runs nothing
        // (`RioConversationBargeIn`). With speakers rather than headphones his voice can keep the
        // listener from hearing the end of the stop until he pauses.
        Publishers.CombineLatest(RioVoice.shared.$isSpeaking, RioTranslatorMode.shared.speakerIsSpeaking)
            .map { $0 || $1 }
            .removeDuplicates()
            .sink { speaking in RioConversationMode.shared.setRioSpeaking(speaking) }
            .store(in: &rioCompanionStateSubscriptions)
        // Dictation has the microphone: conversation mode steps aside and resumes half a second
        // after it ends.
        Publishers.CombineLatest($isRecording, $isTranscribing)
            .map { $0 || $1 }
            .removeDuplicates()
            .sink { [weak self] dictating in
                guard let self else { return }
                // The live translator also stays out of the first moments of a dictation.
                RioTranslatorMode.shared.setBusy(.dictation, dictating)
                self.rioConversationResumeWork?.cancel()
                guard !dictating else {
                    RioConversationMode.shared.setDictationActive(true)
                    return
                }
                let work = DispatchWorkItem { RioConversationMode.shared.setDictationActive(false) }
                self.rioConversationResumeWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            }
            .store(in: &rioCompanionStateSubscriptions)
    }

    @discardableResult
    @MainActor private func finishRioAction(
        _ outcome: RioActionOutcome,
        transcript: String,
        actions: [RioAction] = [],
        unrecognized: String? = nil
    ) -> (outcome: RioActionOutcome, summary: String) {
        if let line = RioPersonality.spokenLine(for: outcome, hour: Calendar.current.component(.hour, from: Date())) {
            RioVoice.shared.speak(line)
        }
        let summary: String
        var didSucceed = false
        switch outcome {
        case .nothing, .cancelled:
            setRioActionPhase(.idle)
            statusText = "Ready"
            let outcomeText = outcome == .cancelled ? "Cancelled" : "Nothing to do"
            recordRioActionHistory(transcript: transcript, actions: actions, outcomeText: outcomeText, didSucceed: false)
            return (outcome, outcomeText)
        case .succeeded(let text):
            summary = text
            didSucceed = true
            setRioActionPhase(.succeeded(text))
        case .failed(let message):
            summary = message
            setRioActionPhase(.failed(message))
            playAlertSound(named: "Basso")
        case .unknown:
            // Say what was heard, so a mishearing ("We are hoping for a win") is obvious.
            summary = RioActionText.unknownMessage(heard: unrecognized ?? transcript)
            setRioActionPhase(.failed(summary))
            showClosingMoment(.didntCatchThat)
        }
        statusText = summary
        scheduleReadyStatusReset(after: 3, matching: [summary])
        recordRioActionHistory(transcript: transcript, actions: actions, outcomeText: summary, didSucceed: didSucceed)
        return (outcome, summary)
    }

    /// History keeps the run log's transcript plus an outcome line, with one exception: anything
    /// private (reading, memory, the clipboard, the screen, translation, tasks) is stored as a
    /// fixed label only, and memory and clipboard transcripts are redacted. No audio, context or
    /// screenshot is stored for an action. See `RioHistoryPolicy`.
    private func recordRioActionHistory(transcript: String, actions: [RioAction], outcomeText: String, didSucceed: Bool) {
        let stored = RioHistoryPolicy.entry(
            transcript: transcript, actions: actions, outcomeText: outcomeText, didSucceed: didSucceed
        )
        let entry = PipelineHistoryItem(
            intent: .rioAction,
            timestamp: Date(),
            rawTranscript: stored.transcript,
            postProcessedTranscript: stored.outcome,
            postProcessingPrompt: nil,
            contextSummary: "",
            contextScreenshotDataURL: nil,
            contextScreenshotStatus: "not captured",
            postProcessingStatus: "Rio action",
            debugStatus: "Rio action",
            customVocabulary: customVocabulary
        )
        do {
            let removed = try pipelineHistoryStore.append(entry, maxCount: maxPipelineHistoryCount)
            for name in removed { Self.deleteAudioFile(name) }
            pipelineHistory = pipelineHistoryStore.loadAllHistory()
        } catch {
            errorMessage = "Unable to save run history entry: \(error.localizedDescription)"
        }
    }

    /// "Rio go crazy" / "Rio show me ur shi jelly" / "Rio hit the Dougie": nothing is typed or saved. The bear jumps
    /// out of the pill, does its trick and jumps back in; a new dictation stops it at once.
    private func finishWithTeddyTrick(_ trick: TeddyTrick, savedAudioFileName: String?) {
        guard isTranscribing else { return }
        transcriptionTask = nil
        transcribingAudioFileName = nil
        isTranscribing = false
        endCriticalDictationActivity()
        if let savedAudioFileName {
            Self.deleteAudioFile(savedAudioFileName)
        }
        audioRecorder.cleanup()
        refreshAvailableMicrophonesIfNeeded()
        debugStatusMessage = "Done"
        let status = Self.teddyStatusText(for: trick)
        statusText = status
        scheduleReadyStatusReset(after: 3, matching: [status])

        let dismissToken = UUID()
        pendingOverlayDismissToken = dismissToken
        guard let home = overlayManager.teddyHome() else {
            overlayManager.dismiss()
            return
        }
        overlayManager.setTeddyTrip(.away)
        teddyTrip.start(trick, on: home.screen, home: home.point, outfit: teddyOutfit) { [weak self] in
            guard let self, self.pendingOverlayDismissToken == dismissToken else { return }
            self.overlayManager.setTeddyTrip(.back)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.teddyRestSeconds) { [weak self] in
                guard let self, self.pendingOverlayDismissToken == dismissToken else { return }
                self.pendingOverlayDismissToken = nil
                self.overlayManager.dismiss()
            }
        }
    }

    private func scheduleOverlayDismissAfterFailureIndicator(after delay: TimeInterval) {
        let dismissToken = UUID()
        pendingOverlayDismissToken = dismissToken
        overlayManager.showFailureIndicator()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.pendingOverlayDismissToken == dismissToken else { return }
            self.pendingOverlayDismissToken = nil
            self.overlayManager.dismiss()
        }
    }

    func toggleDebugPanel() {
        selectedSettingsTab = .runLog
        NotificationCenter.default.post(name: .showSettings, object: nil)
    }

    /// Delivers using the start-time mode and target; only definite non-insertion permits fallback paste.
    /// Unconfirmed writes leave recovery to Paste Again instead of risking a duplicate.
    private func insertTranscriptWhenShortcutReleased(
        _ transcript: String, target: AppTextInsertionTarget?, shouldPressEnter: Bool, useOriginalField: Bool
    ) {
        guard useOriginalField else {
            let pendingRestore = writeTranscriptToPasteboard(transcript)
            pasteAtCursorWhenShortcutReleased {
                if shouldPressEnter {
                    self.pressEnterAfterPaste { self.restoreClipboardIfNeeded(pendingRestore) }
                } else {
                    self.restoreClipboardIfNeeded(pendingRestore)
                }
            }
            return
        }
        performAfterShortcutReleased { [weak self] in
            guard let self, target?.identifier == self.textInsertionTargetID else { return }
            let finish: (String) -> Void = { [weak self] status in
                self?.statusText = status
                self?.scheduleReadyStatusReset(after: 3, matching: [status])
            }
            guard let target else {
                finish("Original field unavailable — use Paste Again")
                return
            }
            if target.isFocused {
                var pendingRestore: PendingClipboardRestore?
                let pasted: Bool
                if !target.allowsTextCapture, target.isSupportedTextControl {
                    if target.identifier == self.textInsertionTargetID, target.isFocused {
                        pendingRestore = self.writeTranscriptToPasteboard(transcript)
                        pasted = target.identifier == self.textInsertionTargetID && target.isFocused
                        if pasted { self.pasteAtCursor(processIdentifier: target.processIdentifier) }
                    } else {
                        pasted = false
                    }
                } else {
                    pasted = target.pasteIfUnchanged(
                        restoringSelection: false,
                        isCurrent: { target.identifier == self.textInsertionTargetID },
                        preparePaste: { pendingRestore = self.writeTranscriptToPasteboard(transcript) },
                        paste: { self.pasteAtCursor(processIdentifier: target.processIdentifier) }
                    )
                }
                guard pasted else {
                    self.restoreClipboardIfNeeded(pendingRestore)
                    if target.identifier == self.textInsertionTargetID {
                        finish("Original field changed or unavailable — use Paste Again")
                    }
                    return
                }
                finish(self.preserveClipboard ? "Pasted at cursor!" : "Copied to clipboard!")
                if shouldPressEnter {
                    self.pressEnterAfterPaste(target: target) { self.restoreClipboardIfNeeded(pendingRestore) }
                } else {
                    self.restoreClipboardIfNeeded(pendingRestore)
                }
                return
            }
            target.insert(
                self.transcriptTextForInsertion(transcript),
                isCurrent: { target.identifier == self.textInsertionTargetID }
            ) { insertionResult in
                guard target.identifier == self.textInsertionTargetID else { return }
                switch insertionResult {
                case .inserted:
                    if !self.preserveClipboard || self.keepDictationInClipboardHistory {
                        let pendingRestore = self.writeTranscriptToPasteboard(transcript)
                        self.restoreClipboardIfNeeded(pendingRestore)
                    }
                    finish("Inserted in original field")
                    if shouldPressEnter { self.pressEnterAfterPaste(target: target) }
                case .notInserted:
                    var pendingRestore: PendingClipboardRestore?
                    self.performAtTarget(target, action: {
                        target.pasteIfUnchanged(
                            restoringSelection: true,
                            isCurrent: { target.identifier == self.textInsertionTargetID },
                            preparePaste: { pendingRestore = self.writeTranscriptToPasteboard(transcript) },
                            paste: { self.pasteAtCursor(processIdentifier: target.processIdentifier) }
                        )
                    }) { pasted in
                        guard pasted else {
                            self.restoreClipboardIfNeeded(pendingRestore)
                            if target.identifier == self.textInsertionTargetID {
                                finish("Insertion unavailable — use Paste Again")
                            }
                            return
                        }
                        guard target.identifier == self.textInsertionTargetID else {
                            self.restoreClipboardIfNeeded(pendingRestore)
                            return
                        }
                        finish("Pasted in original field")
                        if shouldPressEnter {
                            self.pressEnterAfterPaste(target: target) { self.restoreClipboardIfNeeded(pendingRestore) }
                        } else {
                            self.restoreClipboardIfNeeded(pendingRestore)
                        }
                    }
                case .unverified:
                    // An uncertain AX write may already have inserted the text. Never paste it again.
                    finish("Insertion unconfirmed — use Paste Again")
                case .unavailable:
                    finish("Original field changed or unavailable — use Paste Again")
                }
            }
        }
    }

    /// Activates a current target only while input and destination focus still belong to this attempt.
    /// A newer user action cancels both the delayed operation and any later focus restoration.
    private func performAtTarget(
        _ target: AppTextInsertionTarget, action: @escaping () -> Bool, completion: @escaping (Bool) -> Void
    ) {
        guard target.identifier == textInsertionTargetID,
              let app = NSRunningApplication(processIdentifier: target.processIdentifier), !app.isTerminated else {
            completion(false)
            return
        }
        let inputBeforeActivation = Self.userInputEventCounts()
        let targetAppElement = AXUIElementCreateApplication(target.processIdentifier)
        let targetWindowBeforeActivation = accessibilityElement(
            from: targetAppElement, attribute: kAXFocusedWindowAttribute as CFString
        )
        let targetFieldBeforeActivation = accessibilityElement(
            from: targetAppElement, attribute: kAXFocusedUIElementAttribute as CFString
        )
        let previousApp = NSWorkspace.shared.frontmostApplication
        let previousAppElement = previousApp.map { AXUIElementCreateApplication($0.processIdentifier) }
        let previousWindow = previousAppElement.flatMap {
            accessibilityElement(from: $0, attribute: kAXFocusedWindowAttribute as CFString)
        }
        let previousField = previousAppElement.flatMap {
            accessibilityElement(from: $0, attribute: kAXFocusedUIElementAttribute as CFString)
        }
        let wasMinimized = target.isMinimized
        if wasMinimized { target.setMinimized(false) }
        guard target.identifier == textInsertionTargetID,
              Self.userInputEventCounts() == inputBeforeActivation else {
            completion(false)
            return
        }
        app.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let windowNow = self.accessibilityElement(
                from: targetAppElement, attribute: kAXFocusedWindowAttribute as CFString
            )
            let fieldNow = self.accessibilityElement(
                from: targetAppElement, attribute: kAXFocusedUIElementAttribute as CFString
            )
            guard target.identifier == self.textInsertionTargetID,
                  Self.userInputEventCounts() == inputBeforeActivation,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                  windowNow != nil,
                  (self.sameAccessibilityElement(windowNow, target.window)
                    || self.sameAccessibilityElement(windowNow, targetWindowBeforeActivation)),
                  (self.sameAccessibilityElement(fieldNow, target.element)
                    || self.sameAccessibilityElement(fieldNow, targetFieldBeforeActivation)) else {
                completion(false)
                return
            }
            guard target.focus(),
                  target.identifier == self.textInsertionTargetID,
                  Self.userInputEventCounts() == inputBeforeActivation,
                  target.isFocused,
                  (target.window == nil || self.sameAccessibilityElement(
                    self.accessibilityElement(from: targetAppElement, attribute: kAXFocusedWindowAttribute as CFString),
                    target.window
                  )) else {
                completion(false)
                return
            }
            let performed = action()
            let focusedElementAfterAttempt = self.accessibilityElement(
                from: targetAppElement, attribute: kAXFocusedUIElementAttribute as CFString
            )
            let focusedWindowAfterAttempt = self.accessibilityElement(
                from: targetAppElement, attribute: kAXFocusedWindowAttribute as CFString
            )
            completion(performed)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard target.identifier == self.textInsertionTargetID,
                      Self.userInputEventCounts() == inputBeforeActivation,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                      let focusedElementAfterAttempt, let focusedWindowAfterAttempt,
                      self.sameAccessibilityElement(
                        self.accessibilityElement(from: targetAppElement, attribute: kAXFocusedUIElementAttribute as CFString),
                        focusedElementAfterAttempt
                      ),
                      self.sameAccessibilityElement(
                        self.accessibilityElement(from: targetAppElement, attribute: kAXFocusedWindowAttribute as CFString),
                        focusedWindowAfterAttempt
                      ) else { return }
                if wasMinimized { target.setMinimized(true) }
                if let previousWindow { AXUIElementPerformAction(previousWindow, kAXRaiseAction as CFString) }
                if let previousField {
                    AXUIElementSetAttributeValue(previousField, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                }
                if previousApp?.processIdentifier != target.processIdentifier { previousApp?.activate() }
            }
        }
    }

    /// Compares AX identity, including a retained nil focus while a background editor is blurred.
    private func sameAccessibilityElement(_ first: AXUIElement?, _ second: AXUIElement?) -> Bool {
        guard let first, let second else { return first == nil && second == nil }
        return CFEqual(first, second)
    }

    /// Samples only hardware-event counters; no event contents, monitor, or persistent state is collected.
    private static func userInputEventCounts() -> [UInt32] {
        let types: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .flagsChanged, .scrollWheel]
        return types.map { CGEventSource.counterForEventType(.hidSystemState, eventType: $0) }
    }

    /// Posts Cmd-V to a PID, or globally when nil; this sender does not validate field identity.
    private func pasteAtCursor(processIdentifier: pid_t? = nil) {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyCode = keyCodeForCharacter("v") ?? 9

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        if let processIdentifier {
            keyDown?.postToPid(processIdentifier)
        } else {
            keyDown?.post(tap: .cgSessionEventTap)
        }

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand
        if let processIdentifier {
            keyUp?.postToPid(processIdentifier)
        } else {
            keyUp?.post(tap: .cgSessionEventTap)
        }
    }

    private func keyCodeForCharacter(_ character: String) -> CGKeyCode? {
        guard let char = character.lowercased().utf16.first else { return nil }
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let layoutDataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = unsafeBitCast(layoutDataRef, to: CFData.self) as Data
        return layoutData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> CGKeyCode? in
            guard let layout = ptr.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }
            for keyCode in UInt16(0)..<UInt16(128) {
                var chars = [UniChar](repeating: 0, count: 4)
                var charCount = 0
                var deadKeyState: UInt32 = 0
                let status = UCKeyTranslate(
                    layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState, 4, &charCount, &chars
                )
                if status == noErr, charCount > 0, chars[0] == char {
                    return CGKeyCode(keyCode)
                }
            }
            return nil
        }
    }

    /// Posts Return to a PID, or globally when nil; targeted callers must authorize the field/session.
    private func pressEnter(processIdentifier: pid_t? = nil) {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)
        if let processIdentifier {
            keyDown?.postToPid(processIdentifier)
        } else {
            keyDown?.post(tap: .cgSessionEventTap)
        }

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
        if let processIdentifier {
            keyUp?.postToPid(processIdentifier)
        } else {
            keyUp?.post(tap: .cgSessionEventTap)
        }
    }

    /// Keeps trailing-space behavior identical for clipboard paste and Accessibility insertion.
    private func transcriptTextForInsertion(_ transcript: String) -> String {
        guard let last = transcript.last, ".!?".contains(last) else { return transcript }
        return transcript + " "
    }

    /// Writes the final transcript to the system pasteboard.
    /// Also handles appending necessary trailing spaces, declaring transient
    /// types for clipboard managers, and saving the clipboard state for later restoration.
    /// - Parameter transcript: The text to be pasted.
    /// - Returns: A `PendingClipboardRestore` object if clipboard preservation is enabled, otherwise nil.
    private func writeTranscriptToPasteboard(_ transcript: String) -> PendingClipboardRestore? {
        let pasteboard = NSPasteboard.general
        let snapshot = preserveClipboard ? PreservedPasteboardSnapshot(pasteboard: pasteboard) : nil

        // Append a space when ending with sentence-ending punctuation so the
        // next dictation does not jam against the prior period.
        let textToWrite = transcriptTextForInsertion(transcript)

        if keepDictationInClipboardHistory {
            // Plain write so clipboard managers record the dictation in history.
            pasteboard.clearContents()
            pasteboard.setString(textToWrite, forType: .string)
        } else {
            // Declare standard transient types alongside .string so well-behaved
            // clipboard managers (Maccy, Raycast, Paste, Clipy, Flycut, etc.) skip
            // recording this entry in their history. The text still pastes normally
            // via Cmd-V — only clipboard history is affected.
            //
            // See: https://github.com/nicke5012/TransientPasteboardType
            let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
            let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
            let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
            let legacyTransientType = NSPasteboard.PasteboardType("de.petermaurer.TransientPasteboardType")

            pasteboard.declareTypes([
                .string,
                transientType,
                concealedType,
                autoGeneratedType,
                legacyTransientType
            ], owner: nil)

            pasteboard.setString(textToWrite, forType: .string)

            // Populate empty values for the marker types — some clipboard managers
            // check the data presence rather than just the declared type.
            pasteboard.setString("", forType: transientType)
            pasteboard.setString("", forType: concealedType)
            pasteboard.setString("", forType: autoGeneratedType)
            pasteboard.setString("", forType: legacyTransientType)
        }

        guard let snapshot else { return nil }
        return PendingClipboardRestore(
            snapshot: snapshot,
            expectedChangeCount: pasteboard.changeCount,
            writtenTranscript: textToWrite
        )
    }

    private func restoreClipboardIfNeeded(_ pendingRestore: PendingClipboardRestore?) {
        guard let pendingRestore else { return }

        // Some apps consume Cmd-V asynchronously, so restoring too quickly can paste
        // the pre-dictation clipboard instead of the transcript.
        DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay) {
            let pasteboard = NSPasteboard.general
            // A bare changeCount check is too strict: browsers, iCloud Universal
            // Clipboard sync, and other background apps bump the change count
            // without the user copying anything, which left the transcript
            // stranded on the clipboard. Restore when nothing changed, or when the
            // clipboard still holds exactly the transcript we wrote (so the user
            // has not deliberately copied something new that we would clobber).
            let clipboardStillHoldsTranscript =
                pasteboard.string(forType: .string) == pendingRestore.writtenTranscript
            guard pasteboard.changeCount == pendingRestore.expectedChangeCount
                || clipboardStillHoldsTranscript else { return }
            pendingRestore.snapshot.restore(to: pasteboard)
        }
    }

    private func performAfterShortcutReleased(attempt: Int = 0, action: @escaping () -> Void) {
        let maxAttempts = 24
        if hotkeyManager.hasPressedShortcutInputs && attempt < maxAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                self?.performAfterShortcutReleased(attempt: attempt + 1, action: action)
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + pasteAfterShortcutReleaseDelay) {
            action()
        }
    }

    private func pasteAtCursorWhenShortcutReleased(completion: (() -> Void)? = nil) {
        performAfterShortcutReleased { [weak self] in
            self?.pasteAtCursor()
            completion?()
        }
    }

    /// Waits for shortcut release; targeted Enter revalidates its destination at dispatch time.
    private func pressEnterWhenShortcutReleased(
        target: AppTextInsertionTarget? = nil, completion: (() -> Void)? = nil
    ) {
        performAfterShortcutReleased { [weak self] in
            if let target {
                self?.pressEnterAtTarget(target, completion: completion)
            } else {
                self?.pressEnter()
                completion?()
            }
        }
    }

    /// Allows paste consumption; a newer interaction cancels targeted Enter during this delay.
    private func pressEnterAfterPaste(target: AppTextInsertionTarget? = nil, completion: (() -> Void)? = nil) {
        let inputBeforeDelay = target.map { _ in Self.userInputEventCounts() }
        let appBeforeDelay = NSWorkspace.shared.frontmostApplication?.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + pressEnterAfterPasteDelay) { [weak self] in
            if let target {
                guard Self.userInputEventCounts() == inputBeforeDelay,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == appBeforeDelay else {
                    if let self, target.identifier == self.textInsertionTargetID {
                        let status = "Original field is not focused — Enter skipped"
                        self.statusText = status
                        self.scheduleReadyStatusReset(after: 3, matching: [status])
                    }
                    completion?()
                    return
                }
                self?.pressEnterAtTarget(target, completion: completion)
            } else {
                self?.pressEnter()
                completion?()
            }
        }
    }

    /// Sends Enter only for the current target; foreground text controls need no full-field capture.
    /// Refocusing is reserved for capture-eligible background targets; other failures skip Enter.
    private func pressEnterAtTarget(_ target: AppTextInsertionTarget, completion: (() -> Void)?) {
        guard target.identifier == textInsertionTargetID else {
            completion?()
            return
        }
        if target.canSendEnter || (target.isFocused && target.isSupportedTextControl) {
            pressEnter(processIdentifier: target.processIdentifier)
            completion?()
            return
        }
        guard target.allowsTextCapture,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier else {
            let status = "Original field is not focused — Enter skipped"
            statusText = status
            scheduleReadyStatusReset(after: 3, matching: [status])
            completion?()
            return
        }

        performAtTarget(target, action: { [weak self] in
            guard let self,
                  target.identifier == self.textInsertionTargetID,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                  target.canSendEnter else { return false }
            self.pressEnter(processIdentifier: target.processIdentifier)
            return true
        }) { [weak self] sent in
            if !sent, let self, target.identifier == self.textInsertionTargetID {
                let status = "Original field is not focused — Enter skipped"
                self.statusText = status
                self.scheduleReadyStatusReset(after: 3, matching: [status])
            }
            completion?()
        }
    }

    private func cancelRecordingInitializationTimer() {
        recordingInitializationTimer?.cancel()
        recordingInitializationTimer = nil
    }

    func scheduleReadyStatusReset(after delay: TimeInterval, matching statuses: Set<String>? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if let statuses, !statuses.contains(self.statusText) {
                return
            }
            self.statusText = "Ready"
        }
    }
}

/// A command from a schedule, a trigger or the phone, waiting for Rio to be free.
struct RioWaitingCommand {
    let text: String
    let source: RioCommandSource
    let since: Date
    /// Gets this command's own result (the phone texts it back); nil when it never ran.
    let reply: (@MainActor ((message: String, succeeded: Bool)?) -> Void)?
}
