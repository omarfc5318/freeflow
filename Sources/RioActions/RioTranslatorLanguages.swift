import Foundation

/// A language the translator can speak or show. `voiceLocale` picks the system voice for "say it".
struct RioTranslatorLanguage: Equatable, Hashable {
    let code: String
    let name: String
    let voiceLocale: String

    static let english = RioTranslatorLanguage(code: "en", name: "English", voiceLocale: "en-US")
    static let arabic = RioTranslatorLanguage(code: "ar", name: "Arabic", voiceLocale: "ar-SA")

    /// The languages offered as "my other language" (English is always the other side).
    static let all: [RioTranslatorLanguage] = [
        arabic,
        RioTranslatorLanguage(code: "fr", name: "French", voiceLocale: "fr-FR"),
        RioTranslatorLanguage(code: "es", name: "Spanish", voiceLocale: "es-ES"),
        RioTranslatorLanguage(code: "de", name: "German", voiceLocale: "de-DE"),
        RioTranslatorLanguage(code: "it", name: "Italian", voiceLocale: "it-IT"),
        RioTranslatorLanguage(code: "pt", name: "Portuguese", voiceLocale: "pt-BR"),
        RioTranslatorLanguage(code: "hi", name: "Hindi", voiceLocale: "hi-IN"),
        RioTranslatorLanguage(code: "ur", name: "Urdu", voiceLocale: "ur-PK"),
        RioTranslatorLanguage(code: "fa", name: "Persian", voiceLocale: "fa-IR"),
        RioTranslatorLanguage(code: "tr", name: "Turkish", voiceLocale: "tr-TR"),
        RioTranslatorLanguage(code: "ru", name: "Russian", voiceLocale: "ru-RU"),
        RioTranslatorLanguage(code: "zh", name: "Chinese", voiceLocale: "zh-CN"),
        RioTranslatorLanguage(code: "ja", name: "Japanese", voiceLocale: "ja-JP"),
        RioTranslatorLanguage(code: "ko", name: "Korean", voiceLocale: "ko-KR"),
    ]

    /// By ISO code or English name, as Whisper reports it ("ar", "arabic"). nil when unknown.
    static func named(_ value: String?) -> RioTranslatorLanguage? {
        guard let key = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !key.isEmpty else {
            return nil
        }
        return ([english] + all).first { $0.code == key || $0.name.lowercased() == key }
    }
}

enum RioTranslationRoute: Equatable {
    /// `from` is whatever the detector said (nil when it said nothing), `to` the language to produce.
    case translate(from: String?, to: RioTranslatorLanguage)
    /// Nothing worth translating.
    case skip
}

/// Which way a heard sentence is translated: anything that isn't English goes to English, and
/// English goes to the owner's other language (Arabic unless changed in Settings).
enum RioTranslationDirection {
    static func route(detected: String?, text: String, other: RioTranslatorLanguage) -> RioTranslationRoute {
        guard text.unicodeScalars.contains(where: { $0.properties.isAlphabetic }) else { return .skip }
        let target = other == .english ? RioTranslatorLanguage.arabic : other
        if let detected = detected?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !detected.isEmpty {
            let isEnglish = detected == "en" || detected == "english"
            return .translate(from: detected, to: isEnglish ? target : .english)
        }
        return .translate(from: nil, to: RioArabicText.needsTranslation(text) ? .english : target)
    }
}
