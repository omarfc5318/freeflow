import Foundation

/// Spoken key combos ("press command T", "command shift 4") to `KeyCombo`. Matching is anchored and
/// whitelist-only: every word must be a known modifier or key name, so extra words, repeated
/// modifiers or shell-looking text mean "not a key press" rather than a guess.
enum RioKeyCombos {
    private static let modifierNames: [String: WritableKeyPath<ModifierSet, Bool>] = [
        "command": \.command, "cmd": \.command,
        "control": \.control, "ctrl": \.control,
        "option": \.option, "opt": \.option, "alt": \.option,
        "shift": \.shift,
    ]

    private struct ModifierSet {
        var command = false
        var shift = false
        var option = false
        var control = false
    }

    private static let digitWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
    ]

    /// Key names after the modifiers, as one string of words.
    private static let namedKeys: [String: String] = [
        "enter": "return", "return": "return", "escape": "escape", "esc": "escape", "tab": "tab",
        "space": "space", "spacebar": "space", "space bar": "space",
        "delete": "delete", "backspace": "delete", "back space": "delete",
        "forward delete": "forwarddelete", "forwarddelete": "forwarddelete",
        "up": "up", "up arrow": "up", "arrow up": "up",
        "down": "down", "down arrow": "down", "arrow down": "down",
        "left": "left", "left arrow": "left", "arrow left": "left",
        "right": "right", "right arrow": "right", "arrow right": "right",
        "home": "home", "end": "end", "page up": "pageup", "pageup": "pageup",
        "page down": "pagedown", "pagedown": "pagedown",
        "comma": "comma", "period": "period", "dot": "period", "full stop": "period",
        "slash": "slash", "forward slash": "slash", "semicolon": "semicolon", "quote": "quote",
        "left bracket": "leftbracket", "open bracket": "leftbracket",
        "right bracket": "rightbracket", "close bracket": "rightbracket",
        "minus": "minus", "dash": "minus", "hyphen": "minus",
        "equals": "equal", "equal": "equal", "plus": "equal",
        "backtick": "backtick", "grave": "backtick",
        "backslash": "backslash", "back slash": "backslash",
    ]

    private static let verbs: Set<String> = ["press", "hit", "push", "tap"]

    /// `simplified` is `RioText.simplify` output. A verb ("press", "hit") makes the modifiers
    /// optional; without one a combo needs at least one modifier, so a lone word is never a key.
    static func parse(_ simplified: String) -> KeyCombo? {
        var words = simplified.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        var hadVerb = false
        if verbs.contains(words[0]) {
            hadVerb = true
            words.removeFirst()
            if words.first == "the" { words.removeFirst() }
        }
        if hadVerb, ["key", "button"].contains(words.last ?? "") { words.removeLast() }

        var modifiers = ModifierSet()
        while let first = words.first, let path = modifierNames[first] {
            guard !modifiers[keyPath: path] else { return nil }
            modifiers[keyPath: path] = true
            words.removeFirst()
        }
        let hasModifier = modifiers.command || modifiers.shift || modifiers.option || modifiers.control
        guard hadVerb || hasModifier, !words.isEmpty, let key = key(from: words) else { return nil }
        let combo = KeyCombo(key: key, command: modifiers.command, shift: modifiers.shift,
                             option: modifiers.option, control: modifiers.control)
        return isAllowed(combo) ? combo : nil
    }

    private static func key(from words: [String]) -> String? {
        let joined = words.joined(separator: " ")
        if let named = namedKeys[joined] { return named }
        guard words.count == 1, let word = words.first else { return nil }
        if word.count == 1, let scalar = word.unicodeScalars.first, scalar.isASCII,
           (scalar.properties.isAlphabetic || ("0"..."9").contains(word)) {
            return word
        }
        if let digit = digitWords[word] { return digit }
        if RioText.matches(#"^f(?:[1-9]|1[0-2])$"#, word) { return word }
        return nil
    }

    /// The only gate for posting a key: a known key name and a key code for it.
    static func isAllowed(_ combo: KeyCombo) -> Bool {
        KeyCombo.allowedKeys.contains(combo.key) && RioKeyCodes.code(for: combo.key) != nil
    }

    private static let spokenKeyNames: [String: String] = [
        "up": "up arrow", "down": "down arrow", "left": "left arrow", "right": "right arrow",
        "leftbracket": "left bracket", "rightbracket": "right bracket", "pageup": "page up",
        "pagedown": "page down", "forwarddelete": "forward delete", "backtick": "backtick",
    ]

    /// "shift command 4", "control up arrow": modifiers in macOS order, key as a person says it.
    static func describe(_ combo: KeyCombo) -> String {
        var parts: [String] = []
        if combo.control { parts.append("control") }
        if combo.option { parts.append("option") }
        if combo.shift { parts.append("shift") }
        if combo.command { parts.append("command") }
        let key = spokenKeyNames[combo.key] ?? (combo.key.count == 1 ? combo.key.uppercased() : combo.key)
        parts.append(key)
        return parts.joined(separator: " ")
    }
}
