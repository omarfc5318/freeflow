import Foundation

/// Builder I's phrases: system toggles, brightness, battery and Empty Trash here; keys, editing
/// shortcuts and browser control in `RioSystemPhrases+Keyboard.swift`. Pure, no AppKit. Every pattern
/// is anchored on both ends and runs on the simplified transcript, so "open Chrome", "close Spotify",
/// a bare "undo" or "stop" (G's) never match: anything not clearly ours returns nil.
enum RioSystemPhrases {
    static func parse(raw: String, simplified s: String) -> RioAction? {
        guard !s.isEmpty else { return nil }
        return parseShortcut(s) ?? parseBrowser(s) ?? parseToggle(s) ?? parseBrightness(s)
            ?? parseBattery(s) ?? parseTrash(s) ?? RioKeyCombos.parse(s).map(RioAction.pressKeys)
    }

    // MARK: Toggles

    private static let wifiName = #"(?:wi\s?fi|wireless(?:\s+internet)?|wlan|(?:the\s+)?internet|wireless\s+network)"#
    private static let bluetoothName = #"blue\s?tooth"#
    private static let darkName = #"dark\s+(?:mode|theme|appearance)"#
    private static let lightName = #"light\s+(?:mode|theme|appearance)"#
    private static let nightShiftName = #"night\s?shift"#

    private static func parseToggle(_ s: String) -> RioAction? {
        for (name, setting, inverted) in [
            (wifiName, SystemSetting.wifi, false), (bluetoothName, .bluetooth, false),
            (darkName, .darkMode, false), (lightName, .darkMode, true), (nightShiftName, .nightShift, false),
        ] {
            if let isOn = toggleState(s, name: name) { return .systemToggle(setting, isOn: inverted ? !isOn : isOn) }
        }
        if RioText.matches("^\(darkName)$", s) { return .systemToggle(.darkMode, isOn: true) }
        if RioText.matches("^\(lightName)$", s) { return .systemToggle(.darkMode, isOn: false) }
        if RioText.matches("^toggle\\s+(?:the\\s+|my\\s+)?(?:\(darkName)|\(lightName))$", s) {
            return .systemToggle(.darkMode, isOn: !darkModeProbe())
        }
        if let groups = RioText.firstMatch(#"^(?:(?:switch|go|change|flip)\s+to|use|go)\s+(dark|light)\s+(?:mode|theme|appearance)$"#, in: s),
           let which = groups[1]?.lowercased() {
            return .systemToggle(.darkMode, isOn: which == "dark")
        }
        return nil
    }

    /// Whether the Mac is in dark mode right now, for "toggle dark mode". Replaced in tests.
    nonisolated(unsafe) static var darkModeProbe: () -> Bool = {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
    }

    private static func toggleState(_ s: String, name: String) -> Bool? {
        let article = #"(?:(?:the|my)\s+)?"#
        // "turn the wifi back on", "enable wifi again": the state words may say back or again.
        let back = #"(?:back\s+)?"#
        let again = #"(?:\s+again)?"#
        var patterns: [(String, Bool)] = [
            ("^(?:turn|switch|flip|put|set)\\s+\(back)(on|off)\\s+\(article)\(name)\(again)$", false),
            ("^(?:turn|switch|flip|put|set)\\s+\(article)\(name)\\s+\(back)(on|off)\(again)$", false),
            ("^\(article)\(name)\\s+\(back)(on|off)\(again)$", false),
            ("^(enable|disable|activate|deactivate|reenable|re\\s+enable)\\s+\(article)\(name)\(again)$", true),
        ]
        // Joining a network is Wi-Fi only: "connect to wifi", "reconnect the wifi", "disconnect wifi".
        if name == wifiName {
            patterns.append(("^(connect|reconnect|disconnect)\\s+(?:(?:to|from)\\s+)?\(article)\(name)\(again)$", true))
        }
        for (pattern, isVerb) in patterns {
            guard let word = RioText.firstMatch(pattern, in: s)?[1]?.lowercased() else { continue }
            if isVerb { return !["disable", "deactivate", "disconnect"].contains(word) }
            return word == "on"
        }
        return nil
    }

    // MARK: Brightness

    private static let screenWord = #"(?:(?:screen|display|monitor|laptop|mac)\s+)?"#
    private static let article = #"(?:(?:the|my)\s+)?"#
    private static let amount = #"(?:\s+(?:a\s+bit|a\s+little|a\s+lot|some|a\s+notch))?"#

    private static func parseBrightness(_ s: String) -> RioAction? {
        if let level = brightnessLevel(s) { return .brightness(.set(RioBrightness.clampSpoken(level))) }
        let up = [
            "^brightness\\s+up\(amount)$",
            "^(?:turn|bring|crank|bump|raise|put|move)\\s+\(article)\(screenWord)brightness\\s+up\(amount)$",
            "^(?:turn|bring|crank|bump)\\s+up\\s+\(article)\(screenWord)brightness\(amount)$",
            "^(?:increase|raise|boost)\\s+\(article)\(screenWord)brightness\(amount)$",
            "^(?:make\\s+(?:it|the\\s+screen)\\s+)?(?:(?:a\\s+bit|a\\s+little|much)\\s+)?brighter$",
        ]
        if up.contains(where: { RioText.matches($0, s) }) { return .brightness(.up) }
        let down = [
            "^brightness\\s+down\(amount)$",
            "^(?:turn|bring|move|put)\\s+\(article)\(screenWord)brightness\\s+down\(amount)$",
            "^turn\\s+down\\s+\(article)\(screenWord)brightness\(amount)$",
            "^(?:lower|decrease|reduce|drop)\\s+\(article)\(screenWord)brightness\(amount)$",
            "^(?:dim|darken)\\s+\(article)(?:screen|display|monitor|brightness)\(amount)$",
            "^(?:make\\s+(?:it|the\\s+screen)\\s+)?(?:(?:a\\s+bit|a\\s+little|much)\\s+)?(?:dimmer|darker)$",
        ]
        if down.contains(where: { RioText.matches($0, s) }) { return .brightness(.down) }
        return nil
    }

    /// "brightness to 50", "set the screen brightness to fifty percent", "max brightness".
    private static func brightnessLevel(_ s: String) -> Int? {
        let setPattern = "^(?:(?:set|put|change|make|turn|bring|adjust)\\s+)?\(article)\(screenWord)brightness\\s+(?:(?:to|at|on)\\s+)?(.+?)(?:\\s+percent)?$"
        if let word = RioText.firstMatch(setPattern, in: s)?[1]?.lowercased() {
            if let number = RioText.number(from: word) { return number }
            if ["max", "maximum", "full"].contains(word) { return 100 }
            if ["min", "minimum", "lowest"].contains(word) { return 5 }
        }
        if let word = RioText.firstMatch(#"^(max|maximum|full|min|minimum|lowest)\s+(?:screen\s+)?brightness$"#, in: s)?[1]?.lowercased() {
            return ["max", "maximum", "full"].contains(word) ? 100 : 5
        }
        return nil
    }

    // MARK: Battery

    private static func parseBattery(_ s: String) -> RioAction? {
        let patterns = [
            #"^how\s+much\s+(?:battery|charge)(?:\s+(?:life|power))?(?:\s+(?:do\s+i\s+have|have\s+i\s+got|is\s+left|is\s+remaining|is\s+there|remaining|am\s+i\s+at))?(?:\s+left)?$"#,
            #"^(?:whats|what\s+is)\s+(?:my\s+|the\s+)?(?:(?:mac|laptop)\s+)?battery(?:\s+(?:level|percentage|percent|status|life))?(?:\s+at)?$"#,
            #"^(?:hows|how\s+is)\s+(?:my\s+|the\s+)?battery(?:\s+(?:doing|looking))?$"#,
            #"^(?:check|show|tell\s+me|get|read)\s+(?:me\s+)?(?:my\s+|the\s+)?battery(?:\s+(?:level|percentage|percent|status|life))?$"#,
            #"^(?:my\s+|the\s+)?battery(?:\s+(?:level|percentage|percent|status|life))?$"#,
            #"^(?:am\s+i|is\s+(?:my\s+(?:mac|laptop|macbook)|it|the\s+mac))\s+(?:charging|plugged\s+in)$"#,
        ]
        return patterns.contains(where: { RioText.matches($0, s) }) ? .batteryStatus : nil
    }

    // MARK: Trash

    private static func parseTrash(_ s: String) -> RioAction? {
        let pattern = #"^(?:empty|clear|clean\s+out|flush)\s+(?:out\s+)?(?:(?:the|my)\s+)?(?:trash(?:\s+can)?|bin|recycle\s+bin)$"#
        return RioText.matches(pattern, s) ? .emptyTrash : nil
    }
}
