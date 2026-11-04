import Foundation

/// Follow-ups and pronouns, history search ranking and the local style profile (builder N).
/// Synthetic data only; the provider is built with in-memory closures so no preference is written.
enum RioContextMemoryTests {
    private static let now = Date(timeIntervalSince1970: 1_793_714_709) // a fixed instant
    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private static func parse(_ text: String, _ context: RioFollowUpContext?) -> RioAction? {
        RioContextMemoryPhrases.parse(raw: text, simplified: RioText.simplify(text), context: context, now: now)
    }

    private static func context(_ actions: [RioAction]) -> RioFollowUpContext {
        let memory = RioFollowUpMemory()
        for action in actions { memory.record(action, now: now) }
        return memory.snapshot(now: now)!
    }

    /// A context whose actions ran `age` seconds ago, with `front` as the frontmost app.
    private static func context(_ actions: [RioAction], front: String?, age: TimeInterval = 2) -> RioFollowUpContext {
        let memory = RioFollowUpMemory()
        for action in actions { memory.record(action, now: now.addingTimeInterval(-age)) }
        memory.setEnvironmentProvider { RioFollowUpEnvironment(frontApp: front) }
        return memory.snapshot(now: now)!
    }

    static func run() {
        followUpRewriter()
        followUpCloseNeedsAFreshFrontApp()
        followUpSameForUsesTheParser()
        followUpRepeatAndSendable()
        followUpNotStealing()
        followUpMemoryBehaviour()
        historyPhrases()
        historyRanking()
        historyAnswers()
        styleExtraction()
        styleSafety()
        promptBudget()
        providerBehaviour()
        throughTheRealParser()
    }

    // MARK: Follow-ups

    private static func followUpRewriter() {
        let afterOpen = context([.openApp(name: "Spotify")])
        let afterOpenFront = context([.openApp(name: "Spotify")], front: "Spotify")
        ETest.eq(parse("open it again", afterOpen), .openApp(name: "Spotify"))
        ETest.eq(parse("open that again", afterOpen), .openApp(name: "Spotify"))
        ETest.eq(parse("open it", afterOpen), .openApp(name: "Spotify"))
        ETest.eq(parse("close that", afterOpenFront), .quitApp(name: "Spotify"))
        ETest.eq(parse("quit it", afterOpenFront), .quitApp(name: "Spotify"))
        ETest.eq(parse("hide that", afterOpenFront), .hideApp(name: "Spotify"))
        ETest.eq(parse("go back to it", afterOpen), .switchToApp(name: "Spotify"))
        // "Again" re-runs the whole previous command in the coordinator, not here.
        ETest.eq(parse("do that again", afterOpen), nil)
        ETest.eq(parse("again", afterOpen), nil)

        ETest.eq(parse("do the same for Safari", afterOpen), .openApp(name: "Safari"))
        ETest.eq(parse("do the same thing with Safari", afterOpen), .openApp(name: "Safari"))
        ETest.eq(parse("same for Safari", afterOpen), .openApp(name: "Safari"))
        ETest.eq(parse("do that for Safari", afterOpen), .openApp(name: "Safari"))
        ETest.eq(parse("do the same for Safari", context([.quitApp(name: "Spotify")])), .quitApp(name: "Safari"))
        ETest.eq(parse("do the same for Notes", context([.window(WindowCommand(appName: "Chrome", placement: .leftHalf))])),
                 .window(WindowCommand(appName: "Notes", placement: .leftHalf)))
        ETest.eq(parse("do the same for cats", context([.webSearch(query: "dogs")])), .webSearch(query: "cats"))

        ETest.eq(parse("make it bigger", afterOpen), .window(WindowCommand(appName: "Spotify", placement: .maximize)))

        let sent = context([.sendMessage(to: "Sara", body: "running ten minutes late")])
        ETest.eq(parse("send that to Ali too", sent), .sendMessage(to: "Ali", body: "running ten minutes late"))
        ETest.eq(parse("send it to Ali as well", sent), .sendMessage(to: "Ali", body: "running ten minutes late"))
        ETest.eq(parse("forward that to Ali", sent), .sendMessage(to: "Ali", body: "running ten minutes late"))
        ETest.eq(parse("do the same for Ali", sent), .sendMessage(to: "Ali", body: "running ten minutes late"))
        ETest.eq(parse("send that to Ali", context([.answer("Doha is three hours ahead of New York in summer")])),
                 .sendMessage(to: "Ali", body: "Doha is three hours ahead of New York in summer"))
        ETest.eq(parse("and Ali too", sent), .sendMessage(to: "Ali", body: "running ten minutes late"))
        // App context survives a later non-app action for opening, but "close that" no longer
        // means the app: the last thing Rio did was the volume.
        let mixed = context([.openApp(name: "Chrome"), .volume(.up)], front: "Chrome")
        ETest.eq(parse("open it again", mixed), .openApp(name: "Chrome"))
        ETest.eq(parse("close that", mixed), .pressKeys(cmdW))
    }

    private static let cmdW = KeyCombo(key: "w", command: true, shift: false, option: false, control: false)

    /// K45, K33, F35: "close this" quit the last app Rio touched up to 15 minutes ago.
    private static func followUpCloseNeedsAFreshFrontApp() {
        let fresh = context([.openApp(name: "Google Chrome")], front: "Google Chrome", age: 5)
        ETest.eq(parse("close this", fresh), .quitApp(name: "Google Chrome"))
        ETest.eq(parse("hide this", fresh), .hideApp(name: "Google Chrome"))
        // Stale: closes the front window instead of quitting, and never quits or hides by pronoun.
        let stale = context([.openApp(name: "Google Chrome")], front: "Google Chrome", age: RioFollowUpRewriter.quitReferentLifetime + 1)
        for text in ["close this", "close it", "close that"] {
            ETest.eq(parse(text, stale), .pressKeys(cmdW), "stale: \(text)")
        }
        ETest.eq(parse("quit it", stale), nil)
        ETest.eq(parse("hide this", stale), nil)
        ETest.eq(parse("close the app", stale), nil)
        ETest.eq(parse("open it again", stale), .openApp(name: "Google Chrome"), "reopening is harmless")
        // Not in front any more.
        let behind = context([.openApp(name: "Google Chrome")], front: "Claude", age: 3)
        ETest.eq(parse("close it", behind), .pressKeys(cmdW))
        ETest.eq(parse("quit that", behind), nil)
        // A tab or window action since: "close it" is about the window, not the app.
        let afterTab = context([.openApp(name: "Google Chrome"), .browser(.newTab)], front: "Google Chrome", age: 3)
        ETest.eq(parse("close this", afterTab), .pressKeys(cmdW))
        ETest.eq(parse("close the app", afterTab), nil)
        // F35: the referent was quit already; Stickies is in front.
        let afterQuit = context([.openApp(name: "Stickies"), .quitApp(name: "Chess")], front: "Stickies", age: 3)
        ETest.eq(parse("close that", afterQuit), .pressKeys(cmdW))
        // Unknown front app fails closed.
        ETest.eq(parse("quit it", context([.openApp(name: "Spotify")])), nil)
        // A named window move counts as app-level.
        let moved = context([.window(WindowCommand(appName: "Notes", placement: .leftHalf))], front: "Notes", age: 3)
        ETest.eq(parse("close it", moved), .quitApp(name: "Notes"))
    }

    private static func followUpSameForUsesTheParser() {
        let afterOpen = context([.openApp(name: "Google Chrome")])
        ETest.eq(RioFollowUpRewriter.commandText("do the same for Slack", context: afterOpen), "open Slack")
        ETest.eq(RioFollowUpRewriter.commandText("and now Warp", context: afterOpen), "open Warp")
        ETest.eq(RioFollowUpRewriter.commandText("and Warp too", context: afterOpen), "open Warp")
        ETest.eq(RioFollowUpRewriter.commandText("and Warp as well", context: afterOpen), "open Warp")
        ETest.eq(RioFollowUpRewriter.commandText("and now open Spotify", context: afterOpen), nil)
        ETest.eq(RioFollowUpRewriter.commandText("and thank you too", context: afterOpen), nil)
        ETest.eq(RioFollowUpRewriter.commandText("Warp too", context: afterOpen), nil, "a bare \"X too\" is left alone")
        ETest.eq(RioFollowUpRewriter.commandText("and volume up too", context: afterOpen), nil)
        ETest.eq(RioFollowUpRewriter.commandText("open Chrome", context: afterOpen), nil)
        ETest.eq(RioFollowUpRewriter.commandText("do the same for Safari", context: context([.quitApp(name: "Notes")])), "quit Safari")
        ETest.eq(RioFollowUpRewriter.commandText("do the same for Warp", context: context([.openURL(URL(string: "https://app.slack.com")!)])), "open Warp")
        let sent = context([.sendMessage(to: "Sara", body: "running late")])
        ETest.eq(RioFollowUpRewriter.commandText("do the same for Ali", context: sent), nil)
        // A messaging app is not a contact: the brain decides.
        for app in ["Slack", "WhatsApp", "Telegram", "Discord"] {
            ETest.eq(parse("do the same for \(app)", sent), nil, "\(app) is not a contact")
        }
        ETest.eq(parse("do the same on Slack", sent), nil)
        ETest.eq(parse("do the same for Ali", sent), .sendMessage(to: "Ali", body: "running late"))
    }

    private static func followUpRepeatAndSendable() {
        for text in ["again", "try that again", "do it one more time", "repeat the last command", "do that again please", "redo that"] {
            ETest.eq(RioFollowUpRewriter.isRepeatRequest(text), true, "repeat: \(text)")
        }
        for text in ["again and again please no", "open it again", "try again later"] {
            ETest.eq(RioFollowUpRewriter.isRepeatRequest(text), false, "not a repeat: \(text)")
        }
        ETest.eq(RioFollowUpRewriter.isRepeatable([.openApp(name: "Notes"), .volume(.up)]), true)
        ETest.eq(RioFollowUpRewriter.isRepeatable([.typeText("x")]), false)
        ETest.eq(RioFollowUpRewriter.isRepeatable([.undoLast]), false)
        let memory = RioFollowUpMemory()
        memory.record(.answer("Paris"), now: now)
        ETest.eq(memory.snapshot(now: now)?.sendableBody, "Paris")
        memory.noteUnresolved()
        ETest.eq(memory.snapshot(now: now)?.sendableBody, nil, "an older answer is not the reply to a failed command")
        memory.record(.answer("Rome"), now: now)
        ETest.eq(memory.snapshot(now: now)?.sendableBody, "Rome")
    }

    private static func followUpNotStealing() {
        let afterOpen = context([.openApp(name: "Spotify")])
        for other in ["open Chrome", "open it up", "close the tab", "close tab", "quit Spotify", "send Ali hello", "send it",
                      "make it work", "make it rain", "do the dishes", "what is that", "same", "again and again please no",
                      "put it in the fridge", "put it on the left", "move it to the next screen", "maximize that", "send that", "hide it from them", "open it in a new window", "volume up"] {
            ETest.eq(parse(other, afterOpen), nil, "follow-ups must not claim '\(other)'")
        }
        // With no context at all nothing is claimed.
        for text in ["open it again", "close that", "make it bigger", "do the same for Spotify", "send that to Ali too", "again"] {
            ETest.eq(parse(text, nil), nil, "no context, no claim: '\(text)'")
        }
        // "send that" needs something sendable; an app open is not.
        ETest.eq(parse("send that to Ali", afterOpen), nil)
        // Pronoun targets are never an app name.
        ETest.eq(parse("do the same for it", afterOpen), nil)
        ETest.eq(parse("do the same for them", afterOpen), nil)
        // Never repeat undo or typing.
        ETest.eq(parse("do that again", context([.undoLast])), nil)
        ETest.eq(parse("do that again", context([.typeText("hello")])), nil)
    }

    private static func followUpMemoryBehaviour() {
        let memory = RioFollowUpMemory()
        ETest.eq(memory.snapshot(now: now) == nil, true)
        memory.record(.openApp(name: "Notes"), now: now)
        ETest.eq(memory.snapshot(now: now)?.lastApp, "Notes")
        ETest.eq(memory.snapshot(now: now.addingTimeInterval(RioFollowUpMemory.lifetime + 1)) == nil, true, "context expires")
        memory.record(.window(WindowCommand(appName: nil, placement: .center)), now: now)
        ETest.eq(memory.snapshot(now: now)?.lastApp, "Notes", "a window action without a name keeps the app")
        memory.record(.window(WindowCommand(appName: "Chrome", placement: .center)), now: now)
        ETest.eq(memory.snapshot(now: now)?.lastApp, "Chrome")
        memory.clear()
        ETest.eq(memory.snapshot(now: now) == nil, true)
    }

    // MARK: History phrases

    private static func historyPhrases() {
        let cases: [(String, String)] = [
            ("what did I say about the budget", "the budget"),
            ("What did I say about the budget?", "the budget"),
            ("what was I saying about the visa", "the visa"),
            ("when did I mention the dentist", "the dentist"),
            ("when did I say yalla", "yalla"),
            ("what did I dictate regarding the trip", "the trip"),
            ("what did I say on Monday", "monday"),
            ("what did I say yesterday", "yesterday"),
            ("look through my dictations for the invoice", "the invoice"),
            ("search through my history for the invoice", "the invoice"),
        ]
        for (input, query) in cases { ETest.eq(parse(input, nil), .searchHistory(query: query), input) }
        for other in ["what did I tell you about my locker", "what did I say", "what did I say to you", "what's my locker code",
                      "what did you say", "what did he say about the budget", "when is my next meeting", "what did I miss",
                      "search for the budget", "open the budget"] {
            ETest.eq(parse(other, nil), nil, "history must not claim '\(other)'")
        }
    }

    // MARK: History ranking

    private static func entry(_ text: String, daysAgo: Double) -> RioHistoryEntry {
        RioHistoryEntry(id: UUID(), date: now.addingTimeInterval(-daysAgo * 86_400), text: text)
    }

    private static func historyRanking() {
        let budgetNew = entry("We need to cut the marketing budget by ten percent before the board meeting.", daysAgo: 1)
        let budgetOld = entry("The budget review is scheduled for the end of the quarter.", daysAgo: 60)
        let unrelated = entry("Remind me to buy oat milk and bananas on the way home.", daysAgo: 0.1)
        let partial = entry("Budget numbers are not ready yet.", daysAgo: 2)
        let entries = [unrelated, budgetOld, partial, budgetNew]

        let hits = RioHistorySearch.rank(query: "marketing budget", entries: entries, now: now, calendar: calendar)
        ETest.eq(hits.first?.entry.id, budgetNew.id, "full match with recency wins")
        ETest.eq(hits.contains { $0.entry.id == unrelated.id }, false, "unrelated entries are never returned")
        ETest.eq(RioHistorySearch.rank(query: "budget", entries: entries, now: now, calendar: calendar).map(\.entry.id),
                 [budgetNew.id, partial.id, budgetOld.id], "recency orders equal matches")
        ETest.eq(RioHistorySearch.rank(query: "the budget", entries: entries, now: now, calendar: calendar).first?.entry.id, budgetNew.id,
                 "stopwords are ignored")

        let exactPhrase = entry("I think the oat milk budget is fine.", daysAgo: 30)
        let scattered = entry("Milk is cheap but the budget is tight and oat is sold out.", daysAgo: 3)
        let ranked = RioHistorySearch.rank(query: "oat milk budget", entries: [scattered, exactPhrase], now: now, calendar: calendar)
        ETest.eq(ranked.first?.entry.id, exactPhrase.id, "an exact phrase beats scattered words")

        ETest.eq(RioHistorySearch.rank(query: "visa", entries: entries, now: now, calendar: calendar).isEmpty, true, "no match, no hits")
        ETest.eq(RioHistorySearch.rank(query: "the", entries: entries, now: now, calendar: calendar).isEmpty, true, "only stopwords, no hits")
        ETest.eq(RioHistorySearch.rank(query: "budget", entries: [], now: now, calendar: calendar).isEmpty, true)
        ETest.eq(RioHistorySearch.rank(query: "budgets", entries: entries, now: now, calendar: calendar).first?.entry.id, budgetNew.id,
                 "plural matches singular")
        ETest.eq(RioHistorySearch.rank(query: "budget", entries: entries, now: now, calendar: calendar, limit: 1).count, 1)

        // Arabic and mixed text.
        let arabic = entry("لازم أخلص الميزانية قبل يوم الخميس", daysAgo: 2)
        ETest.eq(RioHistorySearch.rank(query: "الميزانية", entries: [unrelated, arabic], now: now, calendar: calendar).first?.entry.id, arabic.id)

        // Day words filter instead of matching text.
        let yesterday = entry("Call the plumber about the leak.", daysAgo: 1)
        let lastMonth = entry("Call the plumber about the invoice.", daysAgo: 40)
        let dayHits = RioHistorySearch.rank(query: "plumber yesterday", entries: [lastMonth, yesterday], now: now, calendar: calendar)
        ETest.eq(dayHits.map(\.entry.id), [yesterday.id], "'yesterday' limits the window")
        let dayOnly = RioHistorySearch.rank(query: "yesterday", entries: [lastMonth, yesterday, unrelated], now: now, calendar: calendar)
        ETest.eq(dayOnly.first?.entry.id, yesterday.id, "a day alone lists that day's dictations")

        // The snippet is the best sentence, and is clipped.
        let long = entry("Nothing here. The marketing budget changes are described in a very long sentence that keeps going "
                         + String(repeating: "and going ", count: 40) + "until the end. Another unrelated sentence.", daysAgo: 1)
        let snippet = RioHistorySearch.rank(query: "marketing budget", entries: [long], now: now, calendar: calendar).first?.snippet ?? ""
        ETest.eq(snippet.contains("marketing budget"), true)
        ETest.eq(snippet.count <= RioHistorySearch.maxSnippetLength + 1, true, "snippet is clipped")
    }

    private static func historyAnswers() {
        func answer(daysAgo: Double, text: String = "Cut the budget.") -> String {
            let e = entry(text, daysAgo: daysAgo)
            let hit = RioHistorySearch.rank(query: "budget", entries: [e], now: now, calendar: calendar)[0]
            return RioHistorySearch.answer(for: hit, now: now, calendar: calendar)
        }
        ETest.eq(answer(daysAgo: 0.01).hasPrefix("Today you said: "), true)
        ETest.eq(answer(daysAgo: 1).hasPrefix("Yesterday you said: "), true)
        let weekday = answer(daysAgo: 3)
        ETest.eq(weekday.hasPrefix("On ") && weekday.contains(" you said: "), true, weekday)
        let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        ETest.eq(weekdays.contains { weekday.hasPrefix("On \($0) you said") }, true, weekday)
        let older = answer(daysAgo: 20)
        ETest.eq(weekdays.contains { older.hasPrefix("On \($0) you said") }, false, "older than a week uses a date: \(older)")
        ETest.eq(older.contains("\u{201C}Cut the budget\u{201D}"), true, older)
    }

    // MARK: Style profile

    private static let casualSamples = [
        "hey man yalla let's grab food later 😂", "no worries bro sounds good 😂", "lol that's wild, let me know 😂 cheers",
        "yeah gonna be late sorry man, let me know", "ok sounds good cheers", "hey wanna come over tonight, let me know",
        "nah i'm good bro cheers", "gonna send it tomorrow sounds good 🔥", "haha for sure, let me know cheers",
        "yo what's up let me know", "btw i think the game is on at eight cheers", "lol ok sounds good",
    ]

    private static let formalSamples = [
        "Dear Dr. Haddad, I would like to request a meeting next week. Best regards", "Please find the report attached. Kind regards",
        "Thank you for your time. I would appreciate your feedback. Best regards", "Could you please confirm the schedule? Best regards",
        "I would like to follow up on my earlier request. Kind regards", "Kindly let me know if the timeline works. Best regards",
        "Thank you for the update. Please advise on the next steps.", "Dear Ms. Karim, I am writing regarding the invoice. Sincerely",
    ]

    private static func styleExtraction() {
        let casual = RioStyleProfile.extract(from: casualSamples)
        ETest.eq(casual.sampleCount, casualSamples.count)
        ETest.eq(casual.casing, .lowercase)
        ETest.eq(casual.formality, .casual)
        ETest.eq(casual.endsWithPeriod, false)
        ETest.eq(casual.topEmoji.first, "😂")
        ETest.eq(casual.emojiRate > 0.2, true)
        ETest.eq(casual.signOffs.first, "cheers")
        ETest.eq(casual.phrasings.contains("let me know"), true)
        ETest.eq(casual.phrasings.contains("sounds good"), true)
        ETest.eq(casual.isUsable, true)

        let formal = RioStyleProfile.extract(from: formalSamples.map { $0.hasSuffix(".") ? $0 : $0 + "." })
        ETest.eq(formal.casing, .sentence)
        ETest.eq(formal.formality, .formal)
        ETest.eq(formal.endsWithPeriod, true)
        ETest.eq(formal.topEmoji.isEmpty, true)
        ETest.eq(formal.signOffs.first, "best regards")

        let mixed = RioStyleProfile.extract(from: [
            "يلا خلاص let's meet at eight", "مرحبا I sent the file اليوم", "طيب send me the link", "ok تمام بكرة",
            "شكرا for the help يا صديقي", "the meeting خلص early", "يلا let me know", "تمام I'll be there",
        ])
        ETest.eq(mixed.mixesLanguages, true)
        ETest.eq(mixed.arabicShare > 0.2 && mixed.arabicShare < 0.8, true)
        let arabicOnly = RioStyleProfile.extract(from: Array(repeating: "ان شاء الله نتقابل بكرة الساعة ثمانية", count: 9))
        ETest.eq(arabicOnly.mixesLanguages, false)
        ETest.eq(arabicOnly.arabicShare > 0.95, true)
        ETest.eq(arabicOnly.casing, .unknown)

        // Too little data: no profile to apply.
        let few = RioStyleProfile.extract(from: Array(casualSamples.prefix(3)))
        ETest.eq(few.isUsable, false)
        ETest.eq(few.cleanupPrompt(), "")
        ETest.eq(few.writingGuidance(), "")
        ETest.eq(RioStyleProfile.extract(from: []).isUsable, false)
        // One-word samples carry no style.
        ETest.eq(RioStyleProfile.extract(from: Array(repeating: "ok", count: 20)).isUsable, false)

        // Eligibility: after a reset only newer dictations count; the newest are used; blanks are dropped.
        let entries = [entry("one two three four", daysAgo: 10), entry("five six seven eight", daysAgo: 1),
                       entry("   ", daysAgo: 0.5), entry("nine ten eleven twelve", daysAgo: 0.2)]
        let all = RioStyleProfile.eligibleSamples(from: entries, after: nil, limit: 10)
        ETest.eq(all.count, 3)
        ETest.eq(all.first, "nine ten eleven twelve", "newest first")
        ETest.eq(RioStyleProfile.eligibleSamples(from: entries, after: now.addingTimeInterval(-2 * 86_400), limit: 10).count, 2)
        ETest.eq(RioStyleProfile.eligibleSamples(from: entries, after: nil, limit: 1), ["nine ten eleven twelve"])
    }

    /// Everything the profile learns comes from fixed vocabularies or counts, so a private sentence
    /// can never be quoted into a prompt.
    private static func styleSafety() {
        let secret = "my bank pin is 4455 and my wife is called Layla"
        let samples = Array(repeating: secret, count: 12) + casualSamples
        let profile = RioStyleProfile.extract(from: samples)
        let everything = [profile.cleanupPrompt(), profile.writingGuidance(), profile.learnedLines().joined(separator: "\n")].joined(separator: "\n")
        for fragment in ["4455", "Layla", "bank", "pin", "wife"] {
            ETest.eq(everything.lowercased().contains(fragment.lowercased()), false, "profile leaked '\(fragment)'")
        }
    }

    private static func promptBudget() {
        let profile = RioStyleProfile.extract(from: casualSamples)
        let cleanup = profile.cleanupPrompt()
        ETest.eq(cleanup.isEmpty, false)
        ETest.eq(cleanup.count <= RioStyleProfile.cleanupBudget, true, "cleanup prompt within budget (\(cleanup.count))")
        ETest.eq(cleanup.contains("never"), true, "cleanup prompt forbids adding content")
        let writing = profile.writingGuidance()
        ETest.eq(writing.count <= RioStyleProfile.writingBudget, true, "writing guidance within budget (\(writing.count))")
        ETest.eq(writing.contains("😂"), true)
        ETest.eq(writing.contains("cheers"), true)
        // A tiny budget is honoured, and never cuts a line in half.
        let tiny = profile.cleanupPrompt(maxCharacters: 120)
        ETest.eq(tiny.count <= 120, true, "tiny budget honoured (\(tiny.count))")
        ETest.eq(profile.cleanupPrompt(maxCharacters: 10), "")
        // A maximal profile still fits.
        var big = profile
        big.phrasings = Array(repeating: "let me know let me know let me know", count: 40)
        big.signOffs = Array(repeating: "best regards best regards", count: 20)
        big.topEmoji = Array(repeating: "😂", count: 30)
        ETest.eq(big.writingGuidance().count <= RioStyleProfile.writingBudget, true)
        ETest.eq(big.cleanupPrompt().count <= RioStyleProfile.cleanupBudget, true)
    }

    private final class Box: @unchecked Sendable { var resetAt: Date?; var enabled = true }

    private static func providerBehaviour() {
        let box = Box()
        let provider = RioStyleProfileProvider(isEnabled: { box.enabled }, resetAt: { box.resetAt }, setResetAt: { box.resetAt = $0 })
        ETest.eq(provider.cleanupPromptSection(), "", "nothing before any dictations are seen")
        let entries = casualSamples.enumerated().map { entry($1, daysAgo: Double($0) * 0.1 + 0.1) }
        provider.refresh(entries: entries, now: now)
        ETest.eq(provider.cleanupPromptSection().isEmpty, false)
        ETest.eq(provider.writingGuidance().isEmpty, false)
        ETest.eq(provider.current?.casing, .lowercase)
        box.enabled = false
        ETest.eq(provider.cleanupPromptSection(), "", "off switch")
        ETest.eq(provider.writingGuidance(), "")
        ETest.eq(provider.current == nil, true)
        box.enabled = true
        provider.reset(now: now)
        ETest.eq(provider.current == nil, true, "reset clears the profile")
        ETest.eq(box.resetAt, now)
        provider.refresh(entries: entries, now: now)
        ETest.eq(provider.current == nil, true, "dictations from before the reset are not used again")
        let later = casualSamples.enumerated().map { RioHistoryEntry(id: UUID(), date: now.addingTimeInterval(Double($0 + 1)), text: $1) }
        provider.refresh(entries: later, now: now.addingTimeInterval(100))
        ETest.eq(provider.current != nil, true, "new dictations build it again")
        // Turned off: refresh keeps nothing.
        box.enabled = false
        provider.refresh(entries: later, now: now)
        box.enabled = true
        ETest.eq(provider.current != nil, true)
    }

    // MARK: Real parser

    private static func throughTheRealParser() {
        let memory = RioFollowUpMemory.shared
        memory.clear()
        memory.setEnvironmentProvider { RioFollowUpEnvironment(frontApp: "Spotify") }
        defer {
            memory.clear()
            memory.setEnvironmentProvider(nil)
        }
        let parser = RioActionParser(installedApps: [InstalledApp(name: "Spotify", bundleIdentifier: nil, url: URL(fileURLWithPath: "/Applications/Spotify.app"))])
        ETest.eq(parser.parse("what did I say about the budget"), .actions([.searchHistory(query: "the budget")]))
        ETest.eq(parser.parse("what did I say on Monday"), .actions([.searchHistory(query: "monday")]))
        ETest.eq(parser.parse("close that"), .unknown("close that"), "no context, still unknown")
        memory.record(.openApp(name: "Spotify"), now: Date())
        ETest.eq(parser.parse("close that"), .actions([.quitApp(name: "Spotify")]))
        ETest.eq(parser.parse("open it again"), .actions([.openApp(name: "Spotify")]))
        ETest.eq(parser.parse("open Spotify"), .actions([.openApp(name: "Spotify")]), "real app names still win")
    }
}
