import AppKit
import ApplicationServices
import Foundation

// Rio writing actions (builder O): gives the handler the last dictation and a safe in-place
// replace. Uses only AppState's non-private members.
extension AppState {
    /// Call once at launch, before the first Rio command.
    @MainActor func installRioWritingHost() {
        let host = RioWritingHost.shared
        host.lastDictation = { [weak self] in self?.rioWritingLastDictation() }
        host.replaceLast = { [weak self] original, text in
            await self?.rioReplaceLastDictation(expecting: original, with: text) ?? .unreadable
        }
    }

    @MainActor private func rioWritingLastDictation() -> RioWritingLastDictation? {
        guard let insertion = lastDictationInsertion else { return nil }
        let app = NSRunningApplication(processIdentifier: insertion.processIdentifier)
        let role = Self.rioWritingAttribute(insertion.element, kAXRoleAttribute) as? String
        return RioWritingLastDictation(
            text: insertion.text, bundleIdentifier: app?.bundleIdentifier,
            isSingleLine: role == "AXTextField" || role == "AXComboBox"
        )
    }

    /// Selects the dictation's range, checks it reads back exactly, and pastes over it. Fails
    /// closed if the field changed since the dictation (same fingerprint rule as Undo Last Dictation).
    @MainActor private func rioReplaceLastDictation(
        expecting original: String, with text: String
    ) async -> RioWritingReplaceOutcome {
        guard let insertion = lastDictationInsertion, insertion.text == original else { return .changed }
        guard let app = NSRunningApplication(processIdentifier: insertion.processIdentifier),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == insertion.processIdentifier else {
            return .differentApp
        }
        guard AXIsProcessTrusted(),
              let focusedRef = Self.rioWritingAttribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute),
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return .unreadable }
        let focused = unsafeBitCast(focusedRef, to: AXUIElement.self)
        guard CFEqual(focused, insertion.element),
              let value = Self.rioWritingAttribute(focused, kAXValueAttribute) as? String else { return .unreadable }
        guard value.utf16.count == insertion.fieldLength, value.hashValue == insertion.fieldHash else { return .changed }
        var range = CFRange(location: insertion.range.location, length: insertion.range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, rangeValue) == .success,
              Self.rioWritingAttribute(focused, kAXSelectedTextAttribute) as? String == original else { return .unreadable }
        // The rewrite must not be learned as the owner's correction.
        correctionWatcher.cancel()
        guard await RioAX.paste(text, into: app) else { return .differentApp }
        // So a second edit ("now make it shorter") can find what is there now.
        lastDictationInsertion = DictationUndo.locate(text: text, processIdentifier: insertion.processIdentifier)
        return .replaced
    }

    private static func rioWritingAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
