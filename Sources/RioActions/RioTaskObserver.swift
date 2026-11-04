import AppKit
import ApplicationServices

/// Settings for the multi-step task agent. Both default ON; the lead can surface them.
enum RioTaskSettings {
    static let enabledKey = "rio_task_agent_enabled"
    static let screenshotsKey = "rio_task_agent_screenshots"

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    /// Off means only the text outline of the window is sent to the model, never a picture.
    static var sendsScreenshots: Bool { UserDefaults.standard.object(forKey: screenshotsKey) as? Bool ?? true }
}

/// What Rio sees of the front window each step: a compact Accessibility outline plus, when
/// allowed, a downscaled screenshot. Nothing here is logged or stored. Rio's own windows are
/// never read (the frontmost app is never Rio), and private fields are reported as private
/// without their contents.
@MainActor
final class RioTaskObserver: RioTaskObserving {
    private static let maxElements = 600
    private static let maxDepth = 14
    private static let maxLines = 120
    private static let timeBudget: TimeInterval = 0.5
    private static let screenshotMaxDimension: CGFloat = 1_024

    private static let roleNames: [String: String] = [
        "AXButton": "button", "AXLink": "link", "AXTextField": "textfield", "AXTextArea": "textarea",
        "AXCheckBox": "checkbox", "AXRadioButton": "radio", "AXPopUpButton": "popup", "AXComboBox": "combobox",
        "AXMenuItem": "menuitem", "AXTab": "tab", "AXHeading": "heading", "AXStaticText": "text",
    ]
    private static let fieldRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField"]

    func currentProcessID() -> Int32? { RioAX.frontmostApp()?.processIdentifier }

    func observe() async -> RioTaskObservation {
        guard let app = RioAX.frontmostApp() else {
            return RioTaskObservation(appName: nil, windowTitle: nil, outline: "(no window to look at)", focusedField: nil, imageDataURL: nil)
        }
        let appElement = RioAX.appElement(app)
        let window = RioAX.element(appElement, kAXFocusedWindowAttribute as String)
        let title = window.flatMap { RioAX.string($0, kAXTitleAttribute as String) }
        let decision = RioTaskObservationPolicy.decide(
            bundleID: app.bundleIdentifier, windowTitle: title,
            screenUnderstandingEnabled: RioScreenSettings.isEnabled, screenshotsEnabled: RioTaskSettings.sendsScreenshots
        )
        // A window Rio must not read: collect and send nothing at all.
        guard decision != .blocked else {
            return RioTaskObservation(
                appName: nil, windowTitle: nil, outline: "(a private window, so nothing was read)",
                focusedField: nil, imageDataURL: nil, processID: app.processIdentifier, isRestricted: true
            )
        }
        let read = window.map { Self.outline(of: $0) } ?? Outline(text: "(no window to look at)", pageURL: nil)
        let image = decision == .outlineAndScreenshot ? Self.screenshot(of: app.processIdentifier) : nil
        let focus = Self.focusFacts(of: appElement)
        return RioTaskObservation(
            appName: app.localizedName, windowTitle: title, outline: read.text,
            focusedField: Self.focusedField(of: appElement), imageDataURL: image,
            pageURL: read.pageURL, focusedInWebArea: focus.inWebArea, focusedIsAddressField: focus.isAddressField,
            processID: app.processIdentifier
        )
    }

    // MARK: Browser chrome facts

    private static let webAreaRole = "AXWebArea"
    private static let maxAncestors = 40

    /// Whether the focused element is inside a page (it or an ancestor is an AXWebArea) and whether
    /// it is a browser address field. Nothing focused counts as not in a page.
    private static func focusFacts(of appElement: AXUIElement) -> (inWebArea: Bool, isAddressField: Bool) {
        guard let focused = RioAX.element(appElement, kAXFocusedUIElementAttribute as String) else { return (false, false) }
        var node: AXUIElement? = focused
        var depth = 0
        while let current = node, depth < maxAncestors {
            if RioAX.role(current) == webAreaRole { return (true, false) }
            node = RioAX.element(current, kAXParentAttribute as String)
            depth += 1
        }
        let texts = [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute]
            .compactMap { RioAX.string(focused, $0 as String) }
        return (false, RioBrowserChrome.isAddressField(identifier: RioAX.string(focused, "AXIdentifier"), texts: texts))
    }

    private static func pageURL(of webArea: AXUIElement) -> URL? {
        guard let value = RioAX.value(webArea, kAXURLAttribute as String) else { return nil }
        if let url = value as? URL { return url }
        return (value as? String).flatMap(URL.init(string:))
    }

    // MARK: Focused field

    private static func focusedField(of appElement: AXUIElement) -> RioTaskFieldInfo? {
        guard let focused = RioAX.element(appElement, kAXFocusedUIElementAttribute as String),
              let role = RioAX.role(focused) else { return nil }
        let subrole = RioAX.string(focused, kAXSubroleAttribute as String)
        guard fieldRoles.contains(role) || subrole == "AXSecureTextField" else { return nil }
        return RioTaskFieldInfo(label: label(of: focused), isSecure: role == "AXSecureTextField" || subrole == "AXSecureTextField")
    }

    // MARK: Outline

    private static func label(of element: AXUIElement) -> String? {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute] {
            if let text = RioAX.string(element, attribute as String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return String(text.prefix(80))
            }
        }
        return nil
    }

    private struct Outline {
        let text: String
        let pageURL: URL?
    }

    private static func outline(of window: AXUIElement) -> Outline {
        let deadline = Date().addingTimeInterval(timeBudget)
        var lines: [String] = []
        var pageURL: URL?
        var queue: [(element: AXUIElement, depth: Int, inWeb: Bool)] = [(window, 0, false)]
        var index = 0
        var visited = 0
        while index < queue.count, visited < maxElements, lines.count < maxLines, Date() < deadline {
            let (element, depth, inWeb) = queue[index]
            index += 1
            visited += 1
            let isWebArea = RioAX.role(element) == webAreaRole
            if isWebArea, pageURL == nil { pageURL = Self.pageURL(of: element) }
            let insideWeb = inWeb || isWebArea
            if let line = line(for: element, inWebArea: insideWeb) { lines.append(line) }
            if depth < maxDepth { queue.append(contentsOf: RioAX.children(element).map { ($0, depth + 1, insideWeb) }) }
        }
        return Outline(text: lines.isEmpty ? "(nothing readable in this window)" : lines.joined(separator: "\n"), pageURL: pageURL)
    }

    private static func line(for element: AXUIElement, inWebArea: Bool) -> String? {
        guard let role = RioAX.role(element), let name = roleNames[role] else { return nil }
        if role == "AXStaticText" {
            guard let text = RioAX.string(element, kAXValueAttribute as String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, text.count <= 80 else { return nil }
            return "[text] \(text)"
        }
        let label = label(of: element)
        if fieldRoles.contains(role) {
            let secure = RioAX.string(element, kAXSubroleAttribute as String) == "AXSecureTextField"
            if secure || RioTaskSafety.isSensitiveLabel(label) { return "[\(name)] \(label ?? "unlabelled") (private, do not type)" }
            let texts = [label].compactMap { $0 }
            let isAddress = !inWebArea && RioBrowserChrome.isAddressField(identifier: RioAX.string(element, "AXIdentifier"), texts: texts)
            if isAddress { return "[\(name)] \(label ?? "address bar") (browser toolbar, not the page: do not type)" }
            let value = RioTaskObservationPolicy.fieldValue(
                label: label, isSecure: false, isAddressField: false, value: RioAX.string(element, kAXValueAttribute as String)
            )
            let suffix = value.map { " value=\"\($0)\"" } ?? ""
            return "[\(name)] \(label ?? "unlabelled")\(suffix)"
        }
        guard let label else { return nil }
        return "[\(name)] \(label)"
    }

    // MARK: Screenshot

    /// The largest normal window of `pid`, scaled down and JPEG-compressed; nil without Screen
    /// Recording permission (Rio never prompts for it here).
    private static func screenshot(of pid: pid_t) -> String? {
        guard CGPreflightScreenCaptureAccess(),
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let candidates = list.compactMap { info -> (id: CGWindowID, area: Double)? in
            guard (info[kCGWindowOwnerPID as String] as? Int) == Int(pid), (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double else { return nil }
            return (CGWindowID(number), width * height)
        }
        guard let best = candidates.max(by: { $0.area < $1.area }),
              let image = CGWindowListCreateImage(.null, .optionIncludingWindow, best.id, [.bestResolution]) else { return nil }
        let scale = min(1, screenshotMaxDimension / CGFloat(max(image.width, image.height)))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(origin: .zero, size: size))
        guard let scaled = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.5])
        else { return nil }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }
}
