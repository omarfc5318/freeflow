import Foundation

/// ANSI virtual key codes for exactly the keys in `KeyCombo.allowedKeys`. A key without an entry
/// here can never be posted, so the allow list and this table are checked against each other in tests.
enum RioKeyCodes {
    private static let table: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "equal": 24, "9": 25, "7": 26, "minus": 27, "8": 28, "0": 29,
        "rightbracket": 30, "o": 31, "u": 32, "leftbracket": 33, "i": 34, "p": 35, "return": 36,
        "l": 37, "j": 38, "quote": 39, "k": 40, "semicolon": 41, "backslash": 42, "comma": 43,
        "slash": 44, "n": 45, "m": 46, "period": 47, "tab": 48, "space": 49, "backtick": 50,
        "delete": 51, "escape": 53, "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100, "f9": 101,
        "f11": 103, "f10": 109, "f12": 111, "home": 115, "pageup": 116, "forwarddelete": 117,
        "f4": 118, "end": 119, "f2": 120, "pagedown": 121, "f1": 122, "left": 123, "right": 124,
        "down": 125, "up": 126,
    ]

    /// The virtual key code, or nil when `key` is not an allowed key.
    static func code(for key: String) -> UInt16? {
        guard KeyCombo.allowedKeys.contains(key) else { return nil }
        return table[key]
    }

    private static let functionFlagKeys: Set<String> = [
        "up", "down", "left", "right", "home", "end", "pageup", "pagedown", "forwarddelete",
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
    ]

    /// Real keyboards set the Fn flag on navigation and function keys; some apps look for it.
    static func usesFunctionFlag(_ key: String) -> Bool { functionFlagKeys.contains(key) }

    static func isArrow(_ key: String) -> Bool { ["up", "down", "left", "right"].contains(key) }
}
