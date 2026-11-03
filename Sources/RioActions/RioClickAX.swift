import AppKit
import ApplicationServices

/// A window's controls as `RioClickElement`s plus the live handles behind them, so a match can
/// be pressed. Index-aligned: `handles[element.index]`. Built fresh for every command and
/// dropped afterwards; labels are never logged or stored.
struct RioClickSnapshot {
    let app: NSRunningApplication
    let windowTitle: String?
    let elements: [RioClickElement]
    let handles: [AXUIElement]
}

/// The Accessibility side of click by voice (builder J): walk the front window within a budget,
/// turn what it finds into plain values, press the chosen one. Pure matching lives in
/// `RioClickMatcher`; the safety lists in `RioClickSafety`.
@MainActor
enum RioClickAX {
    static let maxNodes = 3_000
    static let maxDepth = 50
    static let walkSeconds: TimeInterval = 0.9
    /// A tree smaller than this probably hasn't been built yet (Chromium, Electron).
    private static let sparseTree = 8

    private static var enabledPIDs = Set<pid_t>()

    // MARK: Snapshot

    static func snapshot(of app: NSRunningApplication) async -> RioClickSnapshot? {
        let appElement = RioAX.appElement(app)
        let isThirdParty = !(app.bundleIdentifier ?? "").hasPrefix("com.apple.")
        var freshlyEnabled = false
        if isThirdParty, !enabledPIDs.contains(app.processIdentifier) {
            // Chromium and Electron build their tree only when an assistive client asks.
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            enabledPIDs.insert(app.processIdentifier)
            freshlyEnabled = true
        }
        var result = walk(app, appElement)
        if (result?.elements.count ?? 0) < sparseTree, isThirdParty {
            if freshlyEnabled { try? await Task.sleep(nanoseconds: 450_000_000); result = walk(app, appElement) }
            if (result?.elements.count ?? 0) < sparseTree {
                result = await walkWithEnhancedInterface(app, appElement) ?? result
            }
        }
        return result
    }

    /// Some apps only expose controls with AXEnhancedUserInterface on; it is put back afterwards.
    private static func walkWithEnhancedInterface(_ app: NSRunningApplication, _ appElement: AXUIElement) async -> RioClickSnapshot? {
        let key = "AXEnhancedUserInterface" as CFString
        let before = (RioAX.value(appElement, key as String) as? Bool) ?? false
        AXUIElementSetAttributeValue(appElement, key, kCFBooleanTrue)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let result = walk(app, appElement)
        if !before { AXUIElementSetAttributeValue(appElement, key, kCFBooleanFalse) }
        return result
    }

    private static func frontWindow(_ appElement: AXUIElement) -> AXUIElement? {
        RioAX.element(appElement, kAXFocusedWindowAttribute as String)
            ?? RioAX.element(appElement, kAXMainWindowAttribute as String)
            ?? (RioAX.value(appElement, kAXWindowsAttribute as String) as? [AXUIElement])?.first
    }

    static func windowTitle(of app: NSRunningApplication) -> String? {
        frontWindow(RioAX.appElement(app)).flatMap { RioAX.string($0, kAXTitleAttribute as String) }
    }

    private static func walk(_ app: NSRunningApplication, _ appElement: AXUIElement) -> RioClickSnapshot? {
        guard let window = frontWindow(appElement) else { return nil }
        var state = WalkState(deadline: Date().addingTimeInterval(walkSeconds))
        visit(window, depth: 0, state: &state)
        return RioClickSnapshot(
            app: app,
            windowTitle: RioAX.string(window, kAXTitleAttribute as String),
            elements: state.elements,
            handles: state.handles
        )
    }

    private struct WalkState {
        let deadline: Date
        var nodes = 0
        var elements: [RioClickElement] = []
        var handles: [AXUIElement] = []
    }

    private static let attributeNames: [CFString] = [
        kAXRoleAttribute as CFString, kAXSubroleAttribute as CFString, kAXTitleAttribute as CFString,
        kAXDescriptionAttribute as CFString, kAXValueAttribute as CFString, kAXEnabledAttribute as CFString,
        kAXPositionAttribute as CFString, kAXSizeAttribute as CFString, kAXHelpAttribute as CFString,
        "AXPlaceholderValue" as CFString,
    ]

    private static let pressableByAction: Set<String> = ["AXImage", "AXGroup", "AXStaticText", "AXCell", "AXUnknown", "AXList"]

    private static func visit(_ element: AXUIElement, depth: Int, state: inout WalkState) {
        guard state.nodes < maxNodes, depth <= maxDepth, Date() < state.deadline else { return }
        state.nodes += 1
        // A hung app must not hold the walk: every element gets a short reply budget.
        AXUIElementSetMessagingTimeout(element, 0.4)
        let attrs = attributes(of: element)
        if let candidate = makeElement(element, attrs, index: state.elements.count) {
            state.elements.append(candidate)
            state.handles.append(element)
        }
        for child in RioAX.children(element) {
            visit(child, depth: depth + 1, state: &state)
        }
    }

    private static func attributes(of element: AXUIElement) -> [CFTypeRef?] {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributeNames as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let list = values as? [CFTypeRef] else {
            return Array(repeating: nil, count: attributeNames.count)
        }
        return list.map { item in
            if CFGetTypeID(item) == AXValueGetTypeID(), AXValueGetType(item as! AXValue) == .axError { return nil }
            return item
        }
    }

    private static func kind(role: String?, subrole: String?, element: AXUIElement) -> RioClickKind? {
        guard let role else { return nil }
        let sub = subrole ?? ""
        switch role {
        case "AXButton", "AXDisclosureTriangle": return .button
        case "AXLink": return .link
        case "AXCheckBox": return .checkbox
        case "AXRadioButton": return sub.contains("Tab") ? .tab : .radio
        case "AXTab": return .tab
        case "AXMenuItem", "AXMenuBarItem", "AXMenuButton": return .menuItem
        case "AXPopUpButton": return .popUp
        case "AXRow": return .row
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField": return .textField
        default:
            guard pressableByAction.contains(role) else { return nil }
            var names: CFArray?
            guard AXUIElementCopyActionNames(element, &names) == .success,
                  (names as? [String])?.contains(kAXPressAction as String) == true else { return nil }
            return .other
        }
    }

    private static func makeElement(_ element: AXUIElement, _ attrs: [CFTypeRef?], index: Int) -> RioClickElement? {
        let role = attrs[0] as? String
        let subrole = attrs[1] as? String
        guard subrole != "AXSecureTextField", let kind = kind(role: role, subrole: subrole, element: element),
              let frame = frame(position: attrs[6], size: attrs[7]), frame.width > 1, frame.height > 1 else { return nil }
        var texts = [attrs[2] as? String, attrs[3] as? String, attrs[8] as? String, attrs[9] as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let value = attrs[4] as? String, value.count <= 60, kind != .textField {
            texts.append(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if subrole == "AXSearchField" || role == "AXSearchField" { texts.append("search") }
        if texts.isEmpty { texts = childTexts(of: element) }
        if texts.isEmpty, kind == .textField { texts = labelTexts(of: element) }
        let checked: Bool? = (kind == .checkbox || kind == .radio) ? (attrs[4] as? NSNumber).map { $0.intValue != 0 } : nil
        return RioClickElement(
            index: index, kind: kind, texts: texts, frame: frame,
            isEnabled: (attrs[5] as? Bool) ?? true, isChecked: checked
        )
    }

    private static func frame(position: CFTypeRef?, size: CFTypeRef?) -> CGRect? {
        guard let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    /// The text of a control that has none of its own: a link or button wrapping a label.
    private static func childTexts(of element: AXUIElement) -> [String] {
        var found: [String] = []
        var budget = 8
        func collect(_ node: AXUIElement, depth: Int) {
            guard budget > 0, depth < 3, found.count < 2 else { return }
            for child in RioAX.children(node) {
                budget -= 1
                guard budget > 0 else { return }
                if RioAX.role(child) == kAXStaticTextRole as String,
                   let text = (RioAX.string(child, kAXValueAttribute as String) ?? RioAX.string(child, kAXTitleAttribute as String))?
                       .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    found.append(text)
                } else {
                    collect(child, depth: depth + 1)
                }
            }
        }
        collect(element, depth: 0)
        return found
    }

    /// A native text field is usually labelled by a neighbouring static text (AXTitleUIElement).
    private static func labelTexts(of element: AXUIElement) -> [String] {
        guard let label = RioAX.element(element, kAXTitleUIElementAttribute as String),
              let text = (RioAX.string(label, kAXValueAttribute as String) ?? RioAX.string(label, kAXTitleAttribute as String))?
                  .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return [] }
        return [text]
    }

    // MARK: Acting

    /// Presses an element. AXPress first; a plain mouse click at its centre only when the element
    /// has no press action and nothing of Rio's covers that point.
    static func press(_ element: RioClickElement, handle: AXUIElement, app: NSRunningApplication) -> Bool {
        if AXUIElementPerformAction(handle, kAXPressAction as CFString) == .success { return true }
        if element.kind == .row,
           AXUIElementSetAttributeValue(handle, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success { return true }
        return mouseClick(element, app: app)
    }

    /// Focuses a text field: AXFocused, else a press, else a mouse click.
    static func focus(_ element: RioClickElement, handle: AXUIElement, app: NSRunningApplication) -> Bool {
        if AXUIElementSetAttributeValue(handle, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
           let focused = RioAX.focusedElement(of: app), CFEqual(focused, handle) { return true }
        if AXUIElementPerformAction(handle, kAXPressAction as CFString) == .success { return true }
        return mouseClick(element, app: app)
    }

    /// Selects everything in a field so the next paste replaces it. Best effort.
    static func selectAll(in handle: AXUIElement) {
        guard let text = RioAX.string(handle, kAXValueAttribute as String), !text.isEmpty else { return }
        var range = CFRange(location: 0, length: (text as NSString).length)
        guard let value = AXValueCreate(.cfRange, &range) else { return }
        AXUIElementSetAttributeValue(handle, kAXSelectedTextRangeAttribute as CFString, value)
    }

    static func isChecked(_ handle: AXUIElement) -> Bool? {
        (RioAX.value(handle, kAXValueAttribute as String) as? NSNumber).map { $0.intValue != 0 }
    }

    private static func mouseClick(_ element: RioClickElement, app: NSRunningApplication) -> Bool {
        guard let frame = element.frame else { return false }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        // The topmost window under the point must belong to the app: never click Rio's own panels.
        guard topWindowOwner(at: point) == app.processIdentifier else { return false }
        let previous = CGEvent(source: nil)?.location
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        if let previous { CGWarpMouseCursorPosition(previous) }
        return true
    }

    private static func topWindowOwner(at point: CGPoint) -> pid_t? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in windows {
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"],
                  CGRect(x: x, y: y, width: width, height: height).contains(point),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05 else { continue }
            return (info[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) }
        }
        return nil
    }
}
