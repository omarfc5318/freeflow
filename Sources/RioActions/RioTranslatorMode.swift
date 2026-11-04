import AppKit
import AVFoundation
import Combine
import Foundation

/// Live translator mode (#30). On by voice only ("Rio, translate what is being said"), visible the
/// whole time (the subtitle card, the bear's headphones from `isOn`), and off on "stop
/// translating", Esc, the Fn + Control + Option chord, the card's close button or 10 quiet minutes.
///
/// Privacy: while on, the microphone's sound is sent in short chunks to the transcription provider
/// and the text to the AI provider; the card says so. Nothing is saved or logged.
///
/// Pausing (the microphone is closed, so Rio never hears himself): while Rio or the translation
/// voice speaks (plus a short tail), while dictation or the action key is recording
/// (`RioVoice.isRioRecordingProvider`), for a few seconds after any command is heard
/// (`noteCommandHeard`, called by `RioCommandTranslator` for every action-key and conversation
/// command), and whenever the app calls `setBusy`.
@MainActor final class RioTranslatorMode: ObservableObject {
    static let shared = RioTranslatorMode()

    /// The corner bear wears headphones while this is true.
    @Published private(set) var isOn = false
    @Published private(set) var isPaused = false

    enum StopReason: Equatable {
        case voice, escape, chord, closeButton, idle
        case failure(String)
    }

    private static let tick: TimeInterval = 0.25
    private static let speakingTail: TimeInterval = 0.8
    /// After a command is heard: long enough for Rio to answer without the room picking it up.
    private static let commandWindow: TimeInterval = 5
    private static let escapeKeyCode: UInt16 = 53

    private var session = RioTranslatorSession()
    private let captions = RioTranslatorCaptionModel()
    private lazy var panel = RioTranslatorPanelController(model: captions) { [weak self] in self?.stop(.closeButton) }
    private let speaker = RioTranslatorSpeaker()
    private var board = RioSubtitleBoard() { didSet { captions.board = board } }
    private var tap: RioTranslatorAudioTap?
    private var pipeline: RioTranslatorPipeline?
    private var ticker: Timer?
    private var tickCount = 0
    private var escapeMonitor: Any?
    private var speakingUntil = Date.distantPast
    private var commandUntil = Date.distantPast

    /// True while the translation voice ("say it") is speaking, so conversation mode can pause
    /// for it too. Polled only for the few seconds it speaks, never while idle.
    @Published private(set) var translationVoiceActive = false
    var speakerIsSpeaking: AnyPublisher<Bool, Never> { $translationVoiceActive.eraseToAnyPublisher() }
    private var voiceWatch: Task<Void, Never>?

    private func watchTranslationVoice() {
        voiceWatch?.cancel()
        translationVoiceActive = true
        voiceWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self else { return }
                if !self.speaker.isSpeaking { break }
            }
            self?.translationVoiceActive = false
        }
    }

    private init() {}

    // MARK: Start and stop

    func start() -> RioActionResult {
        if isOn { return .done(summary: "Already translating") }
        guard let whisper = RioTranslatorSettings.whisperConfig() else {
            return .failed(message: "Translating needs your transcription API key. Add it in Settings")
        }
        guard NetworkMonitor.shared.isOnline else { return .failed(message: "I need the internet to translate") }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return .failed(message: "Rio needs microphone access to translate")
        }
        let pipeline = RioTranslatorPipeline(
            whisper: whisper,
            llm: RioSmartLLMClient(config: { RioSmartSettings.llmConfig() }, timeout: 8),
            other: { RioTranslatorSettings.otherLanguage }
        )
        wire(pipeline)
        let sink = pipeline.chunkSink
        let tap = RioTranslatorAudioTap(
            onChunk: { sink.submit($0) },
            onConfigurationChange: { Task { @MainActor in RioTranslatorMode.shared.audioConfigurationChanged() } }
        )
        do {
            try tap.start()
        } catch {
            return .failed(message: "I couldn't open the microphone")
        }
        self.pipeline = pipeline
        self.tap = tap
        pipeline.start()
        session = RioTranslatorSession().starting(now: Date())
        board = RioSubtitleBoard()
        captions.isPaused = false
        captions.status = nil
        captions.otherLanguage = RioTranslatorSettings.otherLanguage
        captions.providerHost = whisper.endpoint.host ?? "your transcription provider"
        isOn = true
        isPaused = false
        speakingUntil = .distantPast
        panel.show()
        installStopTriggers()
        ticker = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickOnce() }
        }
        return .done(summary: "Translating. Subtitles are next to me")
    }

    func stop(_ reason: StopReason) {
        guard isOn else { return }
        ticker?.invalidate()
        ticker = nil
        removeStopTriggers()
        tap?.stop()
        tap = nil
        pipeline?.stop()
        pipeline = nil
        panel.hide()
        session = session.stopping()
        board = board.clearing()
        isOn = false
        isPaused = false
        if case .failure(let message) = reason { RioVoice.shared.speak(message) }
        if reason == .idle { RioVoice.shared.speak("Translator off. It's been quiet") }
    }

    /// "Say it": speaks the newest translation in its own language, also after captions fade or
    /// translating has stopped.
    func speakLast() -> RioActionResult {
        guard let last = board.lastTranslation else {
            // No translation to repeat: "say that again" means his own last line. He says it here
            // and the outcome stays silent (an empty summary), so nothing cuts it off. When he may
            // not speak (someone else on the microphone, Rio recording), the line is the result
            // text instead, so the action key never ends in silence (finding 94). It is a line he
            // already said, and history keeps only a fixed label for this action.
            guard let line = RioVoice.shared.lastSpokenText else { return .failed(message: "I haven't translated anything yet") }
            return .done(summary: RioVoice.shared.speak(line) ? "" : line)
        }
        if RioVoice.shared.isRioRecordingProvider() { return .failed(message: "I'm listening right now, ask again in a second") }
        switch speaker.speak(last.text, in: last.language) {
        case .speaking:
            watchTranslationVoice()
            return .done(summary: "Saying it in \(last.language.name)")
        case .noVoice:
            return .failed(message: "No \(last.language.name) voice is installed. Add one in System Settings, Accessibility, Spoken Content")
        }
    }

    // MARK: Pausing

    /// A command was just heard (action key or conversation mode): step aside while Rio answers.
    func noteCommandHeard() {
        guard isOn else { return }
        commandUntil = Date().addingTimeInterval(Self.commandWindow)
        apply(.commandWindow, active: true)
    }

    /// Lets the app mark a pause of its own, for example while conversation mode runs a command.
    func setBusy(_ reason: RioTranslatorPauseReason, _ active: Bool) {
        guard isOn else { return }
        apply(reason, active: active)
    }

    private func apply(_ reason: RioTranslatorPauseReason, active: Bool) {
        session = session.setting(reason, active: active, now: Date())
        guard session.isPaused != isPaused else { return }
        isPaused = session.isPaused
        captions.isPaused = isPaused
        if isPaused {
            tap?.stop()
        } else {
            do { try tap?.start() } catch { stop(.failure("I couldn't open the microphone again, so I stopped translating")) }
        }
    }

    private func tickOnce() {
        guard isOn else { return }
        let now = Date()
        if RioVoice.shared.isSpeaking || speaker.isSpeaking { speakingUntil = now.addingTimeInterval(Self.speakingTail) }
        apply(.rioSpeaking, active: now < speakingUntil)
        apply(.dictation, active: RioVoice.shared.isRioRecordingProvider())
        if now >= commandUntil { apply(.commandWindow, active: false) }
        tickCount += 1
        if tickCount % 4 == 0 { board = board.pruned(now: now) }
        if session.shouldAutoStop(now: now) { stop(.idle) }
    }

    private func audioConfigurationChanged() {
        guard isOn, !isPaused else { return }
        tap?.stop()
        do { try tap?.start() } catch { stop(.failure("I lost the microphone, so I stopped translating")) }
    }

    // MARK: Pipeline results

    private func wire(_ pipeline: RioTranslatorPipeline) {
        pipeline.onHeard = { [weak self] text, language, target in
            guard let self, self.isOn else { return 0 }
            let now = Date()
            self.session = self.session.speechHeard(now: now)
            let step = self.board.adding(original: text, language: language, target: target, now: now)
            self.board = step.board
            self.captions.status = nil
            return step.id
        }
        pipeline.onTranslation = { [weak self] id, text in
            guard let self, self.isOn else { return }
            if let text {
                self.board = self.board.settingTranslation(id: id, text: text)
            } else {
                self.captions.status = "Couldn't translate that one"
            }
        }
        pipeline.onProblem = { [weak self] message, isFatal in
            if isFatal { self?.stop(.failure(message)) } else { self?.captions.status = message }
        }
    }

    // MARK: Stop triggers

    private func installStopTriggers() {
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == Self.escapeKeyCode else { return }
            Task { @MainActor in RioTranslatorMode.shared.stop(.escape) }
        }
    }

    private func removeStopTriggers() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }
}
