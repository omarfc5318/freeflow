import Foundation

// What the task agent may collect from a window and send to the AI provider (security M2).
// Pure, so the rules are tested without Accessibility.

enum RioTaskObservationPolicy {
    enum Decision: Equatable {
        /// A password manager, permission prompt or privacy pane: nothing is read or sent.
        case blocked
        /// The controls outline only.
        case outlineOnly
        case outlineAndScreenshot
    }

    /// The same checks screen questions use, plus both settings: a picture is sent only when
    /// "Let Rio look at my screen" and the task screenshot switch are both on.
    static func decide(
        bundleID: String?, windowTitle: String?, screenUnderstandingEnabled: Bool, screenshotsEnabled: Bool
    ) -> Decision {
        if RioClickSafety.isBlockedApp(bundleID: bundleID)
            || RioClickSafety.isSensitiveCaptureApp(bundleID: bundleID)
            || RioClickSafety.isBlockedWindow(bundleID: bundleID, title: windowTitle) {
            return .blocked
        }
        return screenUnderstandingEnabled && screenshotsEnabled ? .outlineAndScreenshot : .outlineOnly
    }

    static let maxFieldValueCharacters = 24

    private static let chromiumBundlePrefixes = [
        "com.google.chrome", "com.brave.browser", "com.microsoft.edgemac", "company.thebrowser", "com.vivaldi", "com.operasoftware",
    ]
    private static let browserBundleIDs: Set<String> = ["com.apple.safari", "com.apple.safaritechnologypreview", "org.mozilla.firefox"]

    /// Whether the front app is a web browser, so the browser-chrome rules apply to it.
    static func isBrowser(bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return browserBundleIDs.contains(id) || chromiumBundlePrefixes.contains { id.hasPrefix($0) }
    }

    /// The value of a text field as it may appear in the outline: never for a secure or sensitive
    /// field, never anything that looks like a card, password or personal detail, and short.
    static func fieldValue(label: String?, isSecure: Bool, isAddressField: Bool, value: String?) -> String? {
        guard !isSecure, !isAddressField, !RioTaskSafety.isSensitiveLabel(label),
              let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              !RioTaskSafety.containsSensitiveValue(value), !RioTaskSafety.hasPersonalDetails(value) else { return nil }
        return String(value.prefix(maxFieldValueCharacters))
    }

    /// The sentence Settings shows next to the task switches.
    static func disclosure(providerName: String) -> String {
        "Each step sends a picture of the front window and its controls to \(providerName)."
    }
}
