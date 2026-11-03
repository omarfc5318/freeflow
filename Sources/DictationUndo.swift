import AppKit
import ApplicationServices
import Foundation

/// Removes the last dictation from the text field it went into.
///
/// Right after a paste lands, `locate` records the focused field, the dictation's range and
/// a fingerprint of the field's contents (a hash and length, never the text). `undo` acts
/// only if that same field still holds exactly those contents, so anything typed, sent or
/// edited since then cancels it. It then selects the range, confirms both the range and the
/// selected text read back exactly, and presses Delete, so the app records an ordinary edit
/// and Cmd+Z brings the text back. Field text is read through Accessibility, held only for
/// the comparison, and never logged or stored.
enum DictationUndo {
    struct Insertion {
        let id = UUID()
        let processIdentifier: pid_t
        let element: AXUIElement
        let range: NSRange
        let text: String
        let fieldHash: Int
        let fieldLength: Int
    }

    enum Outcome: Equatable {
        case removed
        case differentApp
        case changed
        case unreadableField

        var statusText: String {
            switch self {
            case .removed: return "Removed last dictation"
            case .differentApp: return "Switch back to the app you dictated into to undo"
            case .changed: return "Text changed since the dictation — press ⌘Z instead"
            case .unreadableField: return "Can't undo in this field — press ⌘Z instead"
            }
        }
    }

    private static let deleteKeyCode: CGKeyCode = 51
    /// Large documents are skipped to keep the comparison cheap, as in CorrectionWatcher.
    private static let maxFieldLength = 50_000

    /// Main thread only. Returns nil until the pasted text is in the focused field and ends at
    /// the cursor; fields that can't be read through Accessibility never qualify.
    static func locate(text: String, processIdentifier: pid_t) -> Insertion? {
        // Electron apps expose no field until asked (cached per pid; the tree builds asynchronously).
        CorrectionWatcher.enableAccessibility(processIdentifier: processIdentifier)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier,
              let (element, value) = readableFocusedField(),
              let range = UndoDictationCore.rangeEndingAtCursor(
                  inserted: text, fieldValue: value, selection: selection(of: element)
              ) else { return nil }
        return Insertion(
            processIdentifier: processIdentifier, element: element, range: range,
            text: (value as NSString).substring(with: range),
            fieldHash: value.hashValue, fieldLength: value.utf16.count
        )
    }

    /// Main thread only.
    static func undo(_ insertion: Insertion) -> Outcome {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == insertion.processIdentifier else {
            return .differentApp
        }
        guard let (element, value) = readableFocusedField() else { return .unreadableField }
        guard CFEqual(element, insertion.element),
              value.utf16.count == insertion.fieldLength,
              value.hashValue == insertion.fieldHash else { return .changed }
        guard select(insertion.range, in: element),
              selectedText(of: element) == insertion.text else { return .unreadableField }
        pressDelete(processIdentifier: insertion.processIdentifier)
        return .removed
    }

    private static func readableFocusedField() -> (AXUIElement, String)? {
        guard AXIsProcessTrusted(),
              let element = focusedElement(),
              AppTextInsertionCore.canObserveDictation(
                  role: attribute(element, kAXRoleAttribute) as? String,
                  subrole: attribute(element, kAXSubroleAttribute) as? String
              ),
              let value = textValue(of: element),
              value.utf16.count <= maxFieldLength else { return nil }
        return (element, value)
    }

    private static func pressDelete(processIdentifier: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: deleteKeyCode, keyDown: isDown)
            event?.flags = []
            event?.postToPid(processIdentifier)
        }
    }

    /// Requires exact readback, like original-field insertion, rather than trusting the setter.
    private static func select(_ range: NSRange, in element: AXUIElement) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success else {
            return false
        }
        return selection(of: element) == range
    }

    private static func focusedElement() -> AXUIElement? {
        guard let value = attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func textValue(of element: AXUIElement) -> String? {
        guard let value = attribute(element, kAXValueAttribute) else { return nil }
        if let text = value as? String { return text }
        return (value as? NSAttributedString)?.string
    }

    private static func selectedText(of element: AXUIElement) -> String? {
        attribute(element, kAXSelectedTextAttribute) as? String
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
