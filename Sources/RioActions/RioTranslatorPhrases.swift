import Foundation

/// Phrases for the live translator (builder M): "translate what is being said", "stop
/// translating", "say it". Pure, anchored on both ends, and run before E's selection tasks, so it
/// never claims "translate this to French" (that needs a target language and "this"): the start
/// phrases only match when the object is the room, not a selection.
enum RioTranslatorPhrases {
    static func parse(raw: String, simplified: String) -> RioAction? {
        let text = simplified.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!?,"))
        guard !text.isEmpty else { return nil }
        if matchesAny(stopPatterns, text) { return .stopTranslation }
        if matchesAny(startPatterns, text) { return .startTranslation }
        if matchesAny(sayPatterns, text) { return .speakLastTranslation }
        return nil
    }

    private static func matchesAny(_ patterns: [String], _ text: String) -> Bool {
        patterns.contains { RioText.matches($0, text) }
    }

    private static let please = #"(?:(?:please|can you|could you)\s+)?"#
    private static let tail = #"(?:\s+please)?"#

    /// Words that name text on screen (a selection's job), never a speaker: "what the email says".
    private static let textNoun = #"(?:text|email|e\s?mail|message|messages|page|screen|document|doc|article|sign|label|post|tweet|paragraph|sentence|selection|word|words|letter|note|notes|menu|website|site|line|caption|captions|subtitles?|book|file|pdf|slide|slides|chat|comment|it|its)"#
    /// "the doctor", "my professor", "this guy", "Ahmed": a short noun phrase for whoever is
    /// speaking (one to three words), never a text noun, a bare "this"/"that", or "I"/"you" (what
    /// was said to or by Rio).
    private static let speaker = "(?!(?:this|that|these|those)\\s+(?:says|said|is|are|means)\\b)(?!(?:i|we|you|u)\\s)"
        + "(?!(?:[a-z]+\\s+){0,3}\(textNoun)\\b)(?:[a-z]+\\s+){0,2}[a-z]+"
    /// The verb of speech after the speaker: "is saying", "says", "said", "keeps saying".
    private static let speechVerb = #"(?:(?:is|are|was|were|keeps|kept)\s+)?(?:saying|says|say|said|talking\s+about|speaking\s+about|explaining)"#

    /// What is being translated when it is "the room" rather than a selection.
    private static let room = #"(?:what(?:s|\s+is|\s+are)?\s+(?:being\s+)?(?:said|spoken|going\s+on)(?:\s+around\s+me)?"#
        + #"|what\s+(?:(?:they|he|she|people|everyone|everybody)(?:\s+(?:are|is))?|theyre|hes|shes)\s+(?:saying|say|talking\s+about)"#
        + "|what\\s+\(speaker)\\s+\(speechVerb)"
        + "|everything\\s+\(speaker)\\s+\(speechVerb)"
        + #"|what\s+(?:i\s+hear|i\s+am\s+hearing|im\s+hearing|you\s+hear)"#
        + #"|everything(?:\s+(?:said|thats\s+said|being\s+said))?"#
        + #"|(?:the|this)\s+(?:conversation|room|speech|audio|talking|people|lecture|meeting|video|call|talk|class|lesson|presentation|sermon|khutbah|podcast|interview|movie|show|seminar)|them|him|her)"#

    private static let startPatterns = [
        "^\(please)(?:translate|interpret)(?:(?:\\s+for\\s+me)?\\s+\(room)(?:\\s+(?:to|into|in)\\s+[a-z]+)?|\\s+for\\s+me)?\(tail)$",
        "^\(please)(?:start|begin|resume)\\s+(?:the\\s+)?(?:live\\s+)?(?:translating|translation|interpreting)(?:\\s+mode)?\(tail)$",
        "^\(please)(?:turn\\s+on|enable|activate|go\\s+into|enter|start|switch\\s+to)\\s+(?:the\\s+)?(?:live\\s+)?(?:translator|translation|interpreter)(?:\\s+mode)?\(tail)$",
        #"^(?:live\s+)?(?:translator|translation|interpreter)\s+mode(?:\s+on)?$"#,
        #"^live\s+(?:translation|translate|translating|interpreting)$"#,
        #"^be\s+my\s+(?:translator|interpreter)$"#,
    ]

    private static let stopPatterns = [
        "^\(please)(?:stop|end|quit|cancel|disable|exit|finish|kill|turn\\s+off|switch\\s+off|shut\\s+off|leave)\\s+(?:the\\s+)?(?:live\\s+)?(?:translating|translation|translator|interpreting|interpreter|translate)(?:\\s+mode)?\(tail)$",
        #"^(?:live\s+)?(?:translator|translation|interpreter)\s+mode\s+off$"#,
        #"^(?:thats\s+enough|enough|no\s+more)\s+(?:translating|translation)$"#,
    ]

    private static let sayPatterns = [
        "^\(please)(?:say|speak)\\s+(?:it|that|this|the\\s+(?:last\\s+)?(?:translation|one|line|sentence))(?:\\s+(?:out\\s+loud|aloud|again|back(?:\\s+to\\s+me)?|to\\s+me))?\(tail)$",
    ]
}
