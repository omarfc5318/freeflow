import AppKit
import ApplicationServices
import Foundation

/// After a dictation is pasted, briefly watches the focused text field and reports
/// vocabulary-style fixes the user makes to the dictated words ("Jon" → "John").
/// Field contents are read through Accessibility, held only in memory while watching,
/// and never logged, persisted or sent anywhere; only corrected terms are reported.
/// Main-thread only, like the rest of the insertion pipeline.
final class CorrectionWatcher {
    /// How long to look for the pasted text before giving up (paste is asynchronous).
    static let locateTimeout: TimeInterval = 4
    /// How long after the paste corrections are still learned.
    static let watchDuration: TimeInterval = 90
    /// A field value must stay unchanged this long before it counts, so half-typed words are skipped.
    static let settleDelay: TimeInterval = 1.0
    static let pollInterval: TimeInterval = 0.5
    /// Large documents are skipped to keep polling cheap.
    static let maxFieldLength = 50_000

    private let onLearned: ([LearnedCorrection]) -> Void
    private var generation = UUID()
    private var transcript = ""
    private var startedAt = Date()
    private var element: AXUIElement?
    private var session: CorrectionLearningSession?
    private var pendingValue: String?
    private var pendingSince = Date()
    private var isPendingSettled = true
    private static var accessibilityEnabledPIDs = Set<pid_t>()

    init(onLearned: @escaping ([LearnedCorrection]) -> Void) {
        self.onLearned = onLearned
    }

    func start(transcript: String) {
        stop()
        guard AXIsProcessTrusted(), !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        self.transcript = transcript
        startedAt = Date()
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            Self.enableAccessibility(processIdentifier: pid)
        }
        schedule(generation)
    }

    /// Learns from the last settled edit, then drops all captured field text.
    func stop() {
        let corrections = session?.finalCorrections() ?? []
        cancel()
        if !corrections.isEmpty { onLearned(corrections) }
    }

    /// Drops all captured field text without learning anything.
    func cancel() {
        generation = UUID()
        transcript = ""
        element = nil
        session = nil
        pendingValue = nil
        isPendingSettled = true
    }

    private func schedule(_ token: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pollInterval) { [weak self] in
            self?.tick(token)
        }
    }

    private func tick(_ token: UUID) {
        guard token == generation else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        let shouldContinue: Bool
        if session == nil {
            shouldContinue = elapsed < Self.locateTimeout
            if shouldContinue { locatePastedText() }
        } else {
            shouldContinue = elapsed < Self.watchDuration && watchForEdits()
        }
        guard shouldContinue else { return stop() }
        schedule(token)
    }

    private func locatePastedText() {
        guard let focused = Self.focusedElement(),
              Self.isReadableTextControl(focused),
              let value = Self.textValue(of: focused),
              value.utf16.count <= Self.maxFieldLength,
              let caret = Self.selection(of: focused), caret.length == 0 else { return }
        session = CorrectionLearningSession(
            transcript: transcript, fieldValue: value, caretLocation: caret.location,
            isKnownWord: Self.isKnownWord
        )
        if session != nil {
            element = focused
            pendingValue = nil
            isPendingSettled = true
        }
    }

    /// Returns false once watching should end.
    private func watchForEdits() -> Bool {
        guard let element else { return false }
        // Focus moved on: stop and learn from the last settled value, never a half-typed one.
        guard let focused = Self.focusedElement(), CFEqual(focused, element) else { return false }
        guard Self.isReadableTextControl(element),
              let value = Self.textValue(of: element),
              value.utf16.count <= Self.maxFieldLength else { return false }
        guard var session else { return false }
        let now = Date()
        if value != pendingValue {
            // Track every change so a fix made just before Send is seen; learning from it still
            // waits for the value to settle unless the span is destroyed (see finalCorrections).
            pendingValue = value
            pendingSince = now
            isPendingSettled = false
            let outcome = session.track(value)
            self.session = session
            return outcome == .watching
        }
        if !isPendingSettled, now.timeIntervalSince(pendingSince) >= Self.settleDelay {
            session.markSettled()
            self.session = session
            isPendingSettled = true
        }
        return true
    }

    // MARK: Accessibility

    /// Electron/Chromium apps build their accessibility tree only after an assistive client sets
    /// `AXManualAccessibility` on the app element (unlike AXEnhancedUserInterface, it has no
    /// window-animation side effects). Once per pid; errors are ignored, and the tree appears
    /// shortly after, so the repeated locate polls pick the field up.
    static func enableAccessibility(processIdentifier pid: pid_t) {
        guard accessibilityEnabledPIDs.insert(pid).inserted else { return }
        _ = AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue
        )
    }

    private static func isKnownWord(_ word: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound
    }

    private static func focusedElement() -> AXUIElement? {
        guard let value = attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    /// Uses the same stricter read eligibility as original-field insertion; never secure fields.
    private static func isReadableTextControl(_ element: AXUIElement) -> Bool {
        AppTextInsertionCore.canCapture(
            role: attribute(element, kAXRoleAttribute) as? String,
            subrole: attribute(element, kAXSubroleAttribute) as? String
        )
    }

    private static func textValue(of element: AXUIElement) -> String? {
        guard let value = attribute(element, kAXValueAttribute) else { return nil }
        if let text = value as? String { return text }
        return (value as? NSAttributedString)?.string
    }

    private static func selection(of element: AXUIElement) -> NSRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
