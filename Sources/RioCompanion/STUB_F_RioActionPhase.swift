import Foundation

// STUB (builder F): AppState gets these `@Published` properties from other builders
// (`rioActionPhase` from builder A; speech, timer, celebrate and help from the later builders).
// The lead deletes this file at merge; until then the corner bear sees constant values.
extension AppState {
    var rioActionPhase: RioActionPhase { .idle }
    /// 0...1 loudness of Rio's spoken reply, for the bear's mouth.
    var rioSpeechLevel: Double { 0 }
    var isRioSpeaking: Bool { false }
    /// Seconds left on the running timer; nil with no timer.
    var rioTimerRemaining: TimeInterval? { nil }
    var rioTimerRinging: Bool { false }
    /// Counts up each time Rio should celebrate.
    var rioCelebrate: Int { 0 }
    var isRioHelpVisible: Bool { false }
}
