import Foundation

/// What Rio wears on the dictation pill while you speak a language with its own traditional
/// look. Only the talking pill uses it; moments and voice tricks keep the normal outfit.
enum SpokenLook: Equatable {
    /// The usual outfit (hoodie, or the suit in formal apps).
    case none
    /// Arabic: red-and-white shemagh held by a black igal, over a white thobe.
    case shemagh
    /// Hindi or Urdu: a saffron safa turban with a brooch, over a cream kurta.
    case turban

    /// From a Whisper language code or name ("ar", "arabic", "hi", "urdu"...).
    /// Returns nil for languages without a look, so the caller keeps the normal outfit.
    static func forLanguage(_ language: String) -> SpokenLook? {
        switch language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ar", "arabic": return .shemagh
        case "hi", "hindi", "ur", "urdu": return .turban
        default: return nil
        }
    }

    /// Share of letters that must be in one script before it counts as the spoken language,
    /// so an English sentence with one Arabic name stays English.
    static let scriptShareThreshold = 0.3

    /// Reads the language from the transcript's script. Returns nil when the text has no
    /// letters (nothing to go on); `.none` when it is in another script, such as English.
    /// Urdu is written in Arabic script, so letters only Urdu uses (ٹ ڈ ڑ ں ے ہ ھ) tell it apart.
    static func detect(in transcript: String) -> SpokenLook? {
        var letters = 0
        var arabicScript = 0
        var devanagari = 0
        var urduOnly = 0
        for scalar in transcript.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            if isDevanagari(scalar) {
                devanagari += 1
            } else if isArabicScript(scalar) {
                arabicScript += 1
                if urduOnlyLetters.contains(scalar) { urduOnly += 1 }
            }
        }
        guard letters > 0 else { return nil }
        let total = Double(letters)
        if Double(devanagari) / total >= scriptShareThreshold { return .turban }
        if Double(arabicScript) / total >= scriptShareThreshold {
            return urduOnly > 0 ? .turban : .shemagh
        }
        return SpokenLook.none
    }

    /// The look the pill starts a recording with: a language picked in Settings wins, otherwise
    /// the language of the last dictation (the transcript is not known until you stop).
    static func atRecordingStart(selectedLanguage: String, lastDetected: SpokenLook) -> SpokenLook {
        forLanguage(selectedLanguage) ?? lastDetected
    }

    private static let urduOnlyLetters: Set<Unicode.Scalar> = [
        "\u{0679}", // ٹ tteh
        "\u{0688}", // ڈ ddal
        "\u{0691}", // ڑ rreh
        "\u{06BA}", // ں noon ghunna
        "\u{06BE}", // ھ heh doachashmee
        "\u{06C1}", // ہ heh goal
        "\u{06D2}", // ے yeh barree
        "\u{06D3}", // ۓ yeh barree with hamza
    ]

    private static func isArabicScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF:
            return true
        default:
            return false
        }
    }

    private static func isDevanagari(_ scalar: Unicode.Scalar) -> Bool {
        (0x0900...0x097F).contains(scalar.value) || (0xA8E0...0xA8FF).contains(scalar.value)
    }
}
