import Foundation

/// What click by voice and screen reading must never touch (builder J). Pure, so it is tested.
enum RioClickSafety {
    /// Apps whose windows Rio never clicks in: password prompts and system permission alerts.
    private static let blockedApps: Set<String> = [
        "com.apple.securityagent", "com.apple.usernotificationcenter", "com.apple.coreservices.uiagent",
    ]

    private static let settingsApps: Set<String> = ["com.apple.systempreferences", "com.apple.systemsettings"]

    /// Settings panes that grant permissions. Matched as whole words in the window title; an
    /// untitled Settings window is treated as blocked because Rio can't tell which pane it is.
    private static let privacyTitle = #"(?i)\b(?:privacy|security|accessibility|screen\s*(?:&|and)?\s*(?:system\s*audio\s*)?recording|full disk access|microphone|camera|input monitoring|automation|files and folders|location services|developer tools|app management|contacts|calendars|reminders|photos|passwords?|touch id|login items|profiles)\b"#

    static func isBlockedApp(bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return blockedApps.contains(id)
    }

    static func isBlockedWindow(bundleID: String?, title: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        if blockedApps.contains(id) { return true }
        guard settingsApps.contains(id) else { return false }
        let name = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return true }
        return RioText.matches(privacyTitle, name)
    }

    /// A field Rio will not type into: passwords, codes, card numbers.
    static func isSensitiveFieldLabel(_ label: String) -> Bool {
        let pattern = #"(?i)\b(?:password|passwords|passcode|passphrase|pin|otp|cvv|cvc|csc|2fa|mfa|one[- ]time|verification code|security code|auth(?:entication)? code|card number|credit card|debit card|card no|ssn|social security|secret)\b"#
        return RioText.matches(pattern, label)
    }

    /// Windows of these apps are never captured and sent to the AI.
    private static let noCapturePrefixes = [
        "com.apple.securityagent", "com.apple.keychainaccess", "com.apple.passwords", "com.1password",
        "com.agilebits", "com.bitwarden", "com.lastpass", "com.dashlane", "org.keepassxc", "com.apple.usernotificationcenter",
    ]

    static func isSensitiveCaptureApp(bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return noCapturePrefixes.contains { id.hasPrefix($0) }
    }
}
