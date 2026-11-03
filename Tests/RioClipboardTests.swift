import Foundation

/// Clipboard classification, the concealed-type filter, history buffer rules and matching.
/// Synthetic strings only: nothing reads the real pasteboard.
enum RioClipboardTests {
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private static func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    static func run() {
        classification()
        filter()
        buffer()
        matching()
        speech()
    }

    private static func classification() {
        let cases: [(String, RioClipboardKind)] = [
            ("https://github.com/zachlatta/freeflow", .link),
            ("  http://example.com/a?b=c  ", .link),
            ("www.haladiscover.com", .link),
            ("haladiscover.com/privacy", .link),
            ("ali@example.com", .email),
            ("mailto:ali@example.com", .email),
            ("+1 (415) 555-0132", .phone),
            ("415-555-0132", .phone),
            ("+974 5555 0132", .phone),
            ("1600 Amphitheatre Parkway, Mountain View, CA 94043", .address),
            ("42 Wallaby Way\nSydney", .address),
            ("12 Elm Street", .address),
            ("123456", .number),
            ("3.14159", .number),
            ("1,234.50", .number),
            ("Meeting notes for Thursday", .text),
            ("see https://example.com for details", .text),
            ("MAT108 homework 6", .text),
            ("", .text),
        ]
        for (text, expected) in cases {
            TestSupport.expectEqual(RioClipboardKind.classify(text), expected)
        }
    }

    private static func filter() {
        TestSupport.expect(RioClipboardFilter.shouldSkip(types: ["org.nspasteboard.ConcealedType", "public.utf8-plain-text"]), "concealed")
        TestSupport.expect(RioClipboardFilter.shouldSkip(types: ["org.nspasteboard.TransientType"]), "transient")
        TestSupport.expect(RioClipboardFilter.shouldSkip(types: ["public.utf8-plain-text", "com.agilebits.onepassword"]), "1password type")
        TestSupport.expect(RioClipboardFilter.shouldSkip(types: ["de.petermaurer.TransientPasteboardType"]), "transient (legacy)")
        TestSupport.expect(!RioClipboardFilter.shouldSkip(types: ["public.utf8-plain-text", "public.html"]), "plain text is kept")
        TestSupport.expect(!RioClipboardFilter.shouldSkip(types: []), "no types is not secret by itself")
        TestSupport.expect(RioClipboardFilter.shouldSkip(sourceBundleID: "com.1password.1password"), "1password app")
        TestSupport.expect(RioClipboardFilter.shouldSkip(sourceBundleID: "com.bitwarden.desktop"), "bitwarden")
        TestSupport.expect(RioClipboardFilter.shouldSkip(sourceBundleID: "com.apple.keychainaccess"), "keychain access")
        TestSupport.expect(RioClipboardFilter.shouldSkip(sourceBundleID: "com.apple.Passwords"), "passwords app")
        TestSupport.expect(!RioClipboardFilter.shouldSkip(sourceBundleID: "com.google.Chrome"), "chrome is fine")
        TestSupport.expect(!RioClipboardFilter.shouldSkip(sourceBundleID: nil), "unknown source is fine")
        TestSupport.expect(RioClipboardFilter.isStorable(text: "hello"), "normal text")
        TestSupport.expect(!RioClipboardFilter.isStorable(text: "   \n"), "blank")
        TestSupport.expect(!RioClipboardFilter.isStorable(text: String(repeating: "a", count: RioClipboardFilter.maxCharacters + 1)), "huge")
    }

    private static func buffer() {
        var buffer = RioClipboardBuffer()
        buffer = buffer.adding("one", at: at(0))
        buffer = buffer.adding("two", at: at(1))
        TestSupport.expectEqual(buffer.items.map(\.text), ["two", "one"])
        // The same text again moves to the front instead of duplicating.
        let again = buffer.adding("one", at: at(2))
        TestSupport.expectEqual(again.items.map(\.text), ["one", "two"])
        TestSupport.expectEqual(again.items.first?.date, at(2))
        // Value semantics: the original is unchanged.
        TestSupport.expectEqual(buffer.items.map(\.text), ["two", "one"])
        // Blank and oversized text is ignored.
        TestSupport.expectEqual(buffer.adding("  ", at: at(3)).items.count, 2)
        // Capped at 20, newest first.
        var full = RioClipboardBuffer()
        for index in 0..<25 { full = full.adding("item \(index)", at: at(Double(index))) }
        TestSupport.expectEqual(full.items.count, RioClipboardBuffer.capacity)
        TestSupport.expectEqual(RioClipboardBuffer.capacity, 20)
        TestSupport.expectEqual(full.items.first?.text, "item 24")
        TestSupport.expectEqual(full.items.last?.text, "item 5")
        // Items carry their kind.
        TestSupport.expectEqual(buffer.adding("https://example.com", at: at(4)).items.first?.kind, .link)
        TestSupport.expectEqual(RioClipboardBuffer().cleared().items.count, 0)
        TestSupport.expectEqual(buffer.cleared().items.count, 0)
    }

    private static func sample() -> RioClipboardBuffer {
        var buffer = RioClipboardBuffer()
        for (index, text) in [
            "https://haladiscover.com/deck",         // oldest
            "ali@example.com",
            "Meeting notes for the MAT108 review",
            "+1 415 555 0132",
            "12 Elm Street",
            "https://github.com/zachlatta/freeflow",
            "ECS119 homework 3 solutions",            // newest
        ].enumerated() {
            buffer = buffer.adding(text, at: at(Double(index)))
        }
        return buffer
    }

    private static func matching() {
        let buffer = sample()
        // By type, newest first.
        TestSupport.expectEqual(RioClipboardMatcher.match(hint: "link", in: buffer)?.text, "https://github.com/zachlatta/freeflow")
        TestSupport.expectEqual(RioClipboardMatcher.match(hint: "the link", in: buffer)?.text, "https://github.com/zachlatta/freeflow")
        TestSupport.expectEqual(RioClipboardMatcher.match(hint: "url", in: buffer)?.text, "https://github.com/zachlatta/freeflow")
        TestSupport.expectEqual(RioClipboardMatcher.match(hint: "website", in: buffer)?.text, "https://github.com/zachlatta/freeflow")
        TestSupport.expectEqual(RioClipboardMatcher.match(hint: "email", in: buffer)?.text, "ali@example.com")
        TestSupport.expectEqual(RioClipboardMatcher.match(hint: "email address", in: buffer)?.text, "ali@example.com")
        TestSupport.expectEqual(RioClipboardMatcher.match(hint: "phone", in: buffer)?.text, "+1 415 555 0132")
        TestSupport.expectEqual(RioClipboardMatcher.match(hint: "phone number", in: buffer)?.text, "+1 415 555 0132")
        TestSupport.expectEqual(RioClipboardMatcher.match(hint: "address", in: buffer)?.text, "12 Elm Street")
        // By words.
        TestSupport.expectEqual(RioClipboardMatcher.match(hint: "MAT108", in: buffer)?.text, "Meeting notes for the MAT108 review")
        TestSupport.expectEqual(RioClipboardMatcher.match(hint: "homework", in: buffer)?.text, "ECS119 homework 3 solutions")
        TestSupport.expectEqual(RioClipboardMatcher.match(hint: "meeting notes", in: buffer)?.text, "Meeting notes for the MAT108 review")
        TestSupport.expect(RioClipboardMatcher.match(hint: "pizza", in: buffer) == nil, "no word match")
        TestSupport.expect(RioClipboardMatcher.match(hint: "number", in: buffer) == nil, "no bare number item")
        // No hint: the previous item (the newest is "what I have now").
        TestSupport.expectEqual(RioClipboardMatcher.match(hint: nil, in: buffer)?.text, "https://github.com/zachlatta/freeflow")
        TestSupport.expectEqual(RioClipboardMatcher.match(hint: "", in: buffer)?.text, "https://github.com/zachlatta/freeflow")
        let single = RioClipboardBuffer().adding("only", at: at(0))
        TestSupport.expectEqual(RioClipboardMatcher.match(hint: nil, in: single)?.text, "only")
        TestSupport.expect(RioClipboardMatcher.match(hint: nil, in: RioClipboardBuffer()) == nil, "empty history")
        TestSupport.expect(RioClipboardMatcher.match(hint: "link", in: RioClipboardBuffer()) == nil, "empty history with a hint")
    }

    private static func speech() {
        TestSupport.expectEqual(RioClipboardSpeech.describe(.init(text: "https://github.com/x/y", date: t0)), "a link to github.com")
        TestSupport.expectEqual(RioClipboardSpeech.describe(.init(text: "www.example.org/page", date: t0)), "a link to example.org")
        TestSupport.expectEqual(RioClipboardSpeech.describe(.init(text: "ali@example.com", date: t0)), "an email address, ali@example.com")
        TestSupport.expectEqual(RioClipboardSpeech.describe(.init(text: "+1 415 555 0132", date: t0)), "a phone number, +1 415 555 0132")
        TestSupport.expectEqual(RioClipboardSpeech.describe(.init(text: "hello there", date: t0)), "\u{201C}hello there\u{201D}")
        let long = String(repeating: "word ", count: 80)
        let described = RioClipboardSpeech.describe(.init(text: long, date: t0))
        TestSupport.expect(described.count <= RioClipboardSpeech.maxSnippet + 8, "long text is cut")
        TestSupport.expect(described.hasSuffix("\u{2026}\u{201D}"), "cut text ends with an ellipsis")
        TestSupport.expectEqual(RioClipboardSpeech.current(nil, hasConcealed: false, hasNonText: false), "Your clipboard is empty.")
        TestSupport.expectEqual(RioClipboardSpeech.current(nil, hasConcealed: true, hasNonText: false), "Your clipboard has something private, so I won't read it out.")
        TestSupport.expectEqual(RioClipboardSpeech.current(nil, hasConcealed: false, hasNonText: true), "Your clipboard has something that isn't text.")
        TestSupport.expectEqual(
            RioClipboardSpeech.current(.init(text: "ali@example.com", date: t0), hasConcealed: false, hasNonText: false),
            "Your clipboard has an email address, ali@example.com."
        )
        TestSupport.expectEqual(RioClipboardSpeech.history(sample()), "You have 7 recent copies. Latest: \u{201C}ECS119 homework 3 solutions\u{201D}, a link to github.com, \u{201C}12 Elm Street\u{201D}.")
        TestSupport.expectEqual(RioClipboardSpeech.history(RioClipboardBuffer()), "Nothing in your clipboard history yet.")
        TestSupport.expectEqual(
            RioClipboardSpeech.history(RioClipboardBuffer().adding("solo", at: t0)),
            "You have 1 recent copy: \u{201C}solo\u{201D}."
        )
    }
}
