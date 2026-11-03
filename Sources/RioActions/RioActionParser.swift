import Foundation

/// Deterministic transcript -> [RioAction]. Pure: no AppKit, no I/O. Everything it can emit is in
/// the closed `RioAction` set, and it never emits the smart-only actions. When any part of a
/// transcript is not understood the whole thing is `.unknown`: it never runs half a command.
struct RioActionParser {
    let installedApps: [InstalledApp]

    init(installedApps: [InstalledApp]) {
        self.installedApps = installedApps
    }

    func parse(_ transcript: String) -> RioActionParse {
        let body = Self.stripEnvelope(transcript)
        guard !body.isEmpty else { return .empty }

        var clauses = Self.splitClauses(body)
        if let last = clauses.last, !Self.startsGreedyCommand(last) {
            let trimmed = Self.stripTrailingFiller(last)
            if trimmed.isEmpty { clauses.removeLast() } else { clauses[clauses.count - 1] = trimmed }
        }
        guard !clauses.isEmpty else { return .empty }

        var actions: [RioAction] = []
        var inheritedVerb: String?
        for clause in clauses {
            guard let parsed = parseClause(clause, inheritedVerb: inheritedVerb) else {
                return .unknown(unknownText(body, lastWasGreedy: clauses.last.map(Self.startsGreedyCommand) ?? false))
            }
            actions.append(parsed.action)
            inheritedVerb = parsed.verb
        }
        return .actions(actions)
    }

    /// The text handed to the smart resolver: the command without the name or trailing filler.
    private func unknownText(_ body: String, lastWasGreedy: Bool) -> String {
        let text = lastWasGreedy ? body : Self.stripTrailingFiller(body)
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " .!,;:"))
    }

    // MARK: Clause parsing

    struct ParsedClause {
        let action: RioAction
        /// The verb a following verb-less clause may reuse ("open Chrome and Spotify").
        let verb: String?
    }

    private func parseClause(_ raw: String, inheritedVerb: String?) -> ParsedClause? {
        if let direct = parseDirect(raw) { return direct }
        guard let verb = inheritedVerb else { return nil }
        return parseInherited(verb: verb, rest: RioText.simplify(raw))
    }

    private func parseDirect(_ raw: String) -> ParsedClause? {
        if let action = Self.parseType(raw) { return ParsedClause(action: action, verb: nil) }
        if let action = parseSearch(raw) { return ParsedClause(action: action, verb: nil) }
        let s = RioText.simplify(raw)
        guard !s.isEmpty else { return nil }
        if Self.isStopListening(s) { return ParsedClause(action: .stopListening, verb: nil) }
        if let action = Self.parseVolume(s) ?? Self.parseMedia(s) ?? Self.parseLock(s)
            ?? Self.parseScreenshot(s) ?? Self.parseDoNotDisturb(s) {
            return ParsedClause(action: action, verb: nil)
        }
        if let window = parseWindow(s, inherited: false) { return window }
        return parseAppVerb(s, inherited: false)
    }

    /// "Warp on the right" after "put Chrome on the left"; "Spotify" after "open Chrome".
    private func parseInherited(verb: String, rest: String) -> ParsedClause? {
        guard !rest.isEmpty else { return nil }
        let combined = "\(verb) \(rest)"
        if let window = parseWindow(combined, inherited: true) { return window }
        return parseAppVerb(combined, inherited: true)
    }

    // MARK: Type

    private static func parseType(_ raw: String) -> RioAction? {
        guard let groups = RioText.firstMatch(#"^(type|write)\s*[:,]?\s+(.+)$"#, in: raw),
              let verb = groups[1]?.lowercased(), let rest = groups[2] else { return nil }
        var text = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // "write a poem about the sea" is a request for the smart resolver, not dictation.
        if verb == "write", RioText.matches(#"^(?:a|an|me|us|up|to|my|something|it|him|her|them|the|some)\b"#, text) {
            return nil
        }
        return .typeText(text)
    }

    // MARK: Stop listening

    private static func isStopListening(_ s: String) -> Bool {
        RioText.matches(
            #"^(?:(?:ok|okay|alright|all right|so)\s+)?(?:you can\s+)?(?:stop listening|go to sleep|thats all(?: for now)?|that is all|stop conversation mode|end conversation mode|conversation mode off|turn off conversation mode|stop the conversation)$"#,
            s
        )
    }

    // MARK: Search

    private func parseSearch(_ raw: String) -> RioAction? {
        var text = raw.trimmingCharacters(in: CharacterSet(charactersIn: " .!,;:"))
        // A polite tail never belongs to the query.
        text = RioText.replacing(#"[,\s]+(?:please|bro)$"#, with: "", in: text)

        let youtubePatterns = [
            #"^(?:search|look)\s+(?:on\s+|in\s+)?(?:youtube|you\s?tube)\s+(?:for\s+)?(.+)$"#,
            #"^(?:search|look)\s+(?:up\s+|for\s+)?(.+?)\s+(?:on|in)\s+(?:youtube|you\s?tube)$"#,
            #"^(?:find|search)\s+(.+?)\s+on\s+(?:youtube|you\s?tube)$"#,
            #"^(?:youtube|you\s?tube)\s+search\s+(?:for\s+)?(.+)$"#,
        ]
        for pattern in youtubePatterns {
            if let groups = RioText.firstMatch(pattern, in: text), let query = Self.cleanQuery(groups[1]) {
                return RioWebURLs.youtubeSearchURL(query: query).map(RioAction.openURL)
            }
        }
        if RioText.matches(#"^google\b"#, text) {
            let whole = RioText.simplify(text)
            if RioWebURLs.isKnownSite(spoken: whole) { return nil }
            if AppNameMatcher.match(for: whole, in: installedApps)?.kind.isStrong == true { return nil }
            if RioText.compact(whole) == "googlechrome" { return nil }
        }
        let webPatterns = [
            #"^search\s+(?:(?:the\s+web|google|online|the\s+internet|bing)\s+)?(?:for\s+|up\s+)?(.+)$"#,
            #"^look\s+up\s+(.+)$"#,
            #"^look\s+(.+?)\s+up$"#,
            #"^google\s+(?:for\s+)?(.+)$"#,
        ]
        for pattern in webPatterns {
            if let groups = RioText.firstMatch(pattern, in: text), let query = Self.cleanQuery(groups[1]) {
                return .webSearch(query: query)
            }
        }
        return nil
    }

    private static func cleanQuery(_ raw: String?) -> String? {
        guard var query = raw?.trimmingCharacters(in: CharacterSet(charactersIn: " .!;:\"")) else { return nil }
        query = RioText.collapseWhitespace(query)
        if RioText.matches(#"^(?:for|up|the web|google|youtube)$"#, query) { return nil }
        return query.isEmpty ? nil : query
    }

    // MARK: Envelope: name, greetings, fillers

    private static let nameVariants = "rio|ryo|reo|rhio|riyo|ryoh|rioh"

    /// Removes a leading name/greeting/filler ("yo Rio, can you ...") and returns the rest.
    static func stripEnvelope(_ transcript: String) -> String {
        var text = transcript.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t\"\u{201C}\u{201D}"))
        let leading = [
            #"^(?:hey|yo|yoo|okay|ok|alright|all right|so|well|um|uh|erm|hmm|mm|please)\b[\s,.!?:;-]*"#,
            "^(?:hi|hello)\\b[\\s,.!?:;-]*(?=(?:\(nameVariants))\\b)",
            "^(?:\(nameVariants))\\b[\\s,.!?:;-]*",
            "^yo(?:\(nameVariants))\\b[\\s,.!?:;-]*",
            #"^(?:can|could|would|will)\s+you\s+(?:please\s+)?"#,
            #"^(?:i\s+(?:want|need)\s+you\s+to|i\s*(?:'|\x{2019})?d\s+like\s+you\s+to|go\s+ahead\s+and|just)\s+"#,
        ]
        var changed = true
        while changed {
            changed = false
            for pattern in leading {
                let next = RioText.replacing(pattern, with: "", in: text)
                if next != text {
                    text = next
                    changed = true
                }
            }
        }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-\n\t"))
    }

    static func stripTrailingFiller(_ text: String) -> String {
        var result = text
        let pattern = #"[\s,.!?;:]+(?:please|bro|bruh|dude|man|buddy|thanks|thank you|for me|now|real quick|quickly)\s*[.!?]*$"#
        while true {
            let next = RioText.replacing(pattern, with: "", in: result)
            if next == result { break }
            result = next
        }
        // A bare filler word is the whole clause.
        if RioText.matches(#"^(?:please|bro|bruh|dude|man|buddy|thanks|thank you|now)[\s.!?,]*$"#, result) { return "" }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " ,.!;:\n\t"))
    }

    // MARK: Clause splitting

    private static let greedyStart = #"^(?:type|write|search|google|look\s+up|youtube\s+search|you\s?tube\s+search)\b"#

    static func startsGreedyCommand(_ clause: String) -> Bool {
        RioText.matches(greedyStart, clause)
    }

    /// Splits on "and", "then", "plus", commas and semicolons. Once a type/search clause starts
    /// it keeps the rest of the sentence, so "search for cats and dogs" stays one query.
    static func splitClauses(_ text: String) -> [String] {
        let pattern = #"\s*,?\s*\b(?:and\s+then|and\s+also|after\s+that|then|and|plus|also)\b\s*|\s*[,;]\s*|\s+&\s+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [text] }
        let full = NSRange(text.startIndex..., in: text)
        var pieces: [(text: String, separator: String)] = []
        var cursor = text.startIndex
        var pendingSeparator = ""
        for match in regex.matches(in: text, options: [], range: full) {
            guard let range = Range(match.range, in: text) else { continue }
            pieces.append((String(text[cursor..<range.lowerBound]), pendingSeparator))
            pendingSeparator = String(text[range])
            cursor = range.upperBound
        }
        pieces.append((String(text[cursor...]), pendingSeparator))

        var clauses: [String] = []
        var index = 0
        while index < pieces.count {
            let piece = pieces[index].text.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.!"))
            if startsGreedyCommand(piece) {
                var merged = pieces[index].text
                for later in pieces[(index + 1)...] { merged += later.separator + later.text }
                clauses.append(merged.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:\n\t")))
                break
            }
            if !piece.isEmpty { clauses.append(piece) }
            index += 1
        }
        return clauses
    }
}
