import Foundation

/// Mac controls: volume, media, lock, screenshots, Do Not Disturb. All matching runs on the
/// simplified transcript (punctuation gone, apostrophes dropped) and is anchored on both ends,
/// so a stray word means "not a control" rather than a guess.
extension RioActionParser {
    /// "turn the volume down a little bit".
    private static let tail = #"(?:\s+(?:a\s+little\s+bit|a\s+tiny\s+bit|a\s+bit|a\s+little|a\s+lot|some|a\s+notch|slightly|a\s+tad))?"#

    static func parseVolume(_ s: String) -> RioAction? {
        if let level = volumeLevel(s) { return .volume(.set(RioVolume.clamp(level))) }

        let upPatterns = [
            "^(?:volume|sound|music)\\s+up\(tail)$",
            "^(?:turn|crank|bump|pump|raise|put|move)\\s+(?:(?:the|my)\\s+)?(?:(?:volume|sound|music)\\s+|it\\s+)?(?:way\\s+)?up\(tail)$",
            "^(?:turn|crank|bump|pump|raise)\\s+up\\s+(?:(?:the|my)\\s+)?(?:volume|sound|music)\(tail)$",
            "^(?:raise|increase|boost)\\s+(?:(?:the|my)\\s+)?(?:volume|sound)\(tail)$",
            "^(?:make\\s+(?:it|the\\s+music|the\\s+sound)\\s+)?(?:(?:a\\s+little\\s+bit|a\\s+bit|a\\s+little|much|slightly)\\s+)?(?:louder|higher)$",
        ]
        if upPatterns.contains(where: { RioText.matches($0, s) }) { return .volume(.up) }

        let downPatterns = [
            "^(?:volume|sound|music)\\s+down\(tail)$",
            "^(?:turn|bring|move|put)\\s+(?:(?:the|my)\\s+)?(?:(?:volume|sound|music)\\s+|it\\s+)?(?:way\\s+)?down\(tail)$",
            "^turn\\s+down\\s+(?:(?:the|my)\\s+)?(?:volume|sound|music)\(tail)$",
            "^(?:lower|decrease|reduce|drop)\\s+(?:(?:the|my)\\s+)?(?:volume|sound)\(tail)$",
            "^(?:make\\s+(?:it|the\\s+music|the\\s+sound)\\s+)?(?:(?:a\\s+little\\s+bit|a\\s+bit|a\\s+little|much|slightly)\\s+)?(?:quieter|softer|lower)$",
        ]
        if downPatterns.contains(where: { RioText.matches($0, s) }) { return .volume(.down) }

        if RioText.matches(#"^un\s?mute(?:\s+(?:the|my))?(?:\s+(?:volume|sound|audio|computer|mac|laptop|it|everything))?$"#, s)
            || RioText.matches(#"^turn\s+(?:(?:the|my)\s+)?(?:volume|sound|audio)\s+on$"#, s) {
            return .volume(.unmute)
        }
        if RioText.matches(#"^(?:mute|silence)(?:\s+(?:the|my))?(?:\s+(?:volume|sound|audio|computer|mac|laptop|it|everything))?$"#, s)
            || RioText.matches(#"^turn\s+(?:(?:the|my)\s+)?(?:volume|sound|audio)\s+off$"#, s)
            || RioText.matches(#"^(?:turn off|shut off)\s+(?:the\s+)?(?:volume|sound)$"#, s) {
            return .volume(.mute)
        }
        return nil
    }

    /// "volume 40", "set the volume to fifty percent", "max volume", "turn it all the way up".
    private static func volumeLevel(_ s: String) -> Int? {
        let setPattern = #"^(?:(?:set|put|change|make|turn|bring|take|adjust)\s+)?(?:(?:the|my)\s+)?(?:(?:system|computer|sound|mac|master|output)\s+)?(?:volume|sound level|sound)\s+(?:(?:to|at|on|up to|down to)\s+)?(.+?)(?:\s+percent)?$"#
        if let groups = RioText.firstMatch(setPattern, in: s), let word = groups[1]?.lowercased() {
            if let number = RioText.number(from: word) { return number }
            if ["max", "maximum", "full"].contains(word) { return 100 }
        }
        if let groups = RioText.firstMatch(#"^(?:set|turn|put)\s+(?:it|the\s+music)\s+(?:to|at)\s+(.+?)(?:\s+percent)?$"#, in: s),
           let number = RioText.number(from: groups[1] ?? "") {
            return number
        }
        if RioText.matches(#"^(?:max|maximum|full)\s+volume$"#, s)
            || RioText.matches(#"^(?:turn|crank)\s+it\s+(?:all\s+the\s+way\s+up|to\s+max)$"#, s) {
            return 100
        }
        return nil
    }

    static func parseMedia(_ s: String) -> RioAction? {
        let obj = #"(?:\s+(?:the|my|some))?\s+(?:music|song|track|audio|video|playback)"#
        // "Stop the music" pauses; it never cancels a timer (bare "stop" does, elsewhere).
        if RioText.matches(#"^stop\s+(?:(?:the|my|this|that)\s+)?(?:music|song|track|audio|playback|spotify)(?:\s+please)?$"#, s)
            || RioText.matches(#"^stop\s+playing(?:\s+(?:(?:the|my|this|that)\s+)?(?:music|songs?|track|this|that|it))?(?:\s+please)?$"#, s) {
            return .media(.pause)
        }
        // A blind toggle only when the words ask for one.
        if RioText.matches(#"^(?:play\s+pause|play\s+and\s+pause|toggle\s+(?:play|playback))$"#, s) {
            return .media(.playPause)
        }
        if RioText.matches("^pause(?:\(obj))?$", s) { return .media(.pause) }
        if RioText.matches("^(?:play|resume|continue|unpause)(?:\(obj))?$", s) { return .media(.play) }
        if RioText.matches(#"^(?:(?:play\s+)?(?:the\s+)?next(?:\s+(?:song|track|one))?|skip(?:\s+(?:this|the|that|it))?(?:\s+(?:song|track|one))?|skip\s+forward)$"#, s) {
            return .media(.next)
        }
        if RioText.matches(#"^(?:(?:play\s+)?(?:the\s+)?(?:previous|prior)(?:\s+(?:song|track|one))?|(?:play\s+)?(?:the\s+)?last\s+(?:song|track)|go\s+back\s+(?:a|one)\s+(?:song|track)|back\s+one\s+song)$"#, s) {
            return .media(.previous)
        }
        return nil
    }

    static func parseLock(_ s: String) -> RioAction? {
        RioText.matches(#"^lock(?:\s+(?:my|the|this))?\s+(?:screen|mac|computer|laptop|macbook)$"#, s) ? .lockScreen : nil
    }

    static func parseScreenshot(_ s: String) -> RioAction? {
        let patterns = [
            #"^(?:(?:take|grab|capture|make|get)\s+)?(?:(?:a|an|the|me\s+a)\s+)?(?:screen\s?shot|screen\s+capture|screen\s+grab)(?:\s+(?:of|for))?(?:\s+(.+))?$"#,
            #"^(?:capture|grab)\s+(.+)$"#,
        ]
        for (index, pattern) in patterns.enumerated() {
            guard let groups = RioText.firstMatch(pattern, in: s) else { continue }
            let target = (groups[1] ?? "").lowercased()
            if let kind = screenshotKind(target, requireTarget: index == 1) { return .screenshot(kind) }
        }
        return nil
    }

    private static func screenshotKind(_ target: String, requireTarget: Bool) -> ScreenshotKind? {
        let words = target.split(separator: " ").map(String.init)
        if words.isEmpty { return requireTarget ? nil : .fullScreen }
        let filler: Set<String> = ["the", "a", "an", "this", "my", "of", "whole", "entire", "full", "current", "front", "selected", "frontmost"]
        let content = words.filter { !filler.contains($0) }
        if content.isEmpty { return nil }
        if content == ["window"] { return .window }
        if content == ["screen"] || content == ["display"] || content == ["desktop"] || content == ["everything"] { return .fullScreen }
        let selectionWords: Set<String> = ["selection", "area", "region", "part", "portion", "section", "piece", "crop"]
        if content.count <= 3, content.allSatisfy({ selectionWords.contains($0) || $0 == "screen" }) {
            return .selection
        }
        return nil
    }

    static func parseDoNotDisturb(_ s: String) -> RioAction? {
        let mode = #"(?:do not disturb|dont disturb|dnd|focus)(?:\s+mode)?"#
        if let groups = RioText.firstMatch("^(?:turn|switch|put|set|flip)(?:\\s+the)?\\s+(on|off)\\s+(?:(?:the|my)\\s+)?\(mode)$", in: s),
           let state = groups[1] {
            return .doNotDisturb(isOn: state.lowercased() == "on")
        }
        if let groups = RioText.firstMatch("^(?:turn|switch|put|set|flip)(?:\\s+(?:the|my))?\\s+\(mode)\\s+(on|off)$", in: s),
           let state = groups[1] {
            return .doNotDisturb(isOn: state.lowercased() == "on")
        }
        if let groups = RioText.firstMatch("^\(mode)\\s+(on|off)$", in: s), let state = groups[1] {
            return .doNotDisturb(isOn: state.lowercased() == "on")
        }
        if let groups = RioText.firstMatch("^(enable|disable|activate|deactivate|start|stop|cancel|end)\\s+(?:(?:the|my)\\s+)?\(mode)$", in: s),
           let verb = groups[1]?.lowercased() {
            return .doNotDisturb(isOn: ["enable", "activate", "start"].contains(verb))
        }
        if RioText.matches("^(?:(?:go\\s+into|enter)\\s+)?\(mode)$", s) { return .doNotDisturb(isOn: true) }
        return nil
    }
}
