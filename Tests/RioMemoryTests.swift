import Foundation

/// Memory phrases, notes phrases and the local memory store (builder L). Temp directories only.
enum RioMemoryTests {
    private static func parse(_ text: String) -> RioAction? {
        RioMemoryPhrases.parse(raw: text, simplified: RioText.simplify(text))
    }

    static func run() {
        rememberPhrases()
        recallPhrases()
        forgetPhrases()
        notePhrases()
        notStealing()
        throughTheRealParser()
        storeRoundTrip()
        storeMatching()
        storeRobustness()
        secondPerson()
    }

    private static func rememberPhrases() {
        let cases: [(String, String)] = [
            ("remember my locker code is 4321", "my locker code is 4321"),
            ("Remember that my locker code is 4321.", "my locker code is 4321"),
            ("remember: my wifi password is Blue-Sky 42", "my wifi password is Blue-Sky 42"),
            ("please remember my mom's birthday is March 3", "my mom's birthday is March 3"),
            ("keep in mind that I'm allergic to peanuts", "I'm allergic to peanuts"),
            ("memorize my passport number is X123456", "my passport number is X123456"),
            ("remember my locker code is 4321 and my pin is 99", "my locker code is 4321 and my pin is 99"),
            ("remember my keys are in the drawer please", "my keys are in the drawer"),
            ("Remember, my parking spot is B12", "my parking spot is B12"),
        ]
        for (input, fact) in cases { ETest.eq(parse(input), .remember(fact: fact), input) }
    }

    private static func recallPhrases() {
        let cases: [(String, String)] = [
            ("what's my locker code", "locker code"), ("what is my locker code?", "locker code"),
            ("what was my locker code", "locker code"), ("do you remember my locker code", "locker code"),
            ("what did I tell you about my locker", "locker"), ("tell me my locker code", "locker code"),
            ("what do you remember about me", ""), ("what do you know about me", ""),
            ("what have I told you", ""), ("what do you remember", ""),
            ("what do you remember about my locker code", "locker code"), ("whats my wifi password", "wifi password"),
        ]
        for (input, query) in cases { ETest.eq(parse(input), .recall(query: query), input) }
    }

    private static func forgetPhrases() {
        ETest.eq(parse("forget my locker code"), .forget(query: "locker code"))
        ETest.eq(parse("Forget about my locker code."), .forget(query: "locker code"))
        ETest.eq(parse("forget that my locker code is 4321"), .forget(query: "locker code is 4321"))
        for refused in ["forget it", "forget everything", "forget about it", "forget the meeting", "forget what you know about me",
                        "forget all my memories", "forget", "forget my"] {
            ETest.eq(parse(refused), nil, "must not claim '\(refused)'")
        }
    }

    private static func notePhrases() {
        let cases: [(String, String)] = [
            ("note: ask Ali about the deck", "Ask Ali about the deck"), ("Note, buy milk", "Buy milk"),
            ("take a note: call the dentist", "Call the dentist"), ("take a note call the dentist", "Call the dentist"),
            ("make a note that the meeting moved", "The meeting moved"), ("add to my notes: milk and eggs", "Milk and eggs"),
            ("add milk to my notes", "Milk"), ("jot down buy a charger", "Buy a charger"),
            ("note to self: bring the charger", "Bring the charger"), ("note that Ali is out Friday", "Ali is out Friday"),
            ("note down the wifi is fast", "The wifi is fast"), ("note: buy milk, eggs and bread", "Buy milk, eggs and bread"),
            ("Rio note: ask Ali about the deck.", "Ask Ali about the deck"),
        ]
        for (input, text) in cases { ETest.eq(parse(input.replacingOccurrences(of: "Rio ", with: "")), .addNote(text: text), input) }
    }

    private static func notStealing() {
        for other in ["remember to call mom", "remember when we met", "remember me", "remember", "I remember my locker code",
                      "remind me to call mom", "remind me my locker code is 4321", "note", "notes", "note the time",
                      "take a note", "take notes", "open my notes", "show my notes", "what's my battery",
                      "what's my next meeting", "what's my volume", "what's my schedule today", "what is my clipboard",
                      "what's my timer", "what's my brightness", "what's my ip address", "what's the weather",
                      "open Chrome", "volume 40", "10 minute timer", "what's on my calendar"] {
            ETest.eq(parse(other), nil, "memory must not claim '\(other)'")
        }
    }

    private static func throughTheRealParser() {
        let parser = RioActionParser(installedApps: [])
        func first(_ text: String) -> RioActionParse { parser.parse(text) }
        ETest.eq(first("Rio, remember my locker code is 4321"), .actions([.remember(fact: "my locker code is 4321")]))
        ETest.eq(first("what's my locker code"), .actions([.recall(query: "locker code")]))
        ETest.eq(first("forget my locker code"), .actions([.forget(query: "locker code")]))
        ETest.eq(first("note: buy milk, eggs and bread"), .actions([.addNote(text: "Buy milk, eggs and bread")]))
        ETest.eq(first("remember my pin is 99 and my locker is 12"), .actions([.remember(fact: "my pin is 99 and my locker is 12")]))
        // Reminders stay with the reminder path (smart resolver), never become memories.
        if case .actions(let list) = first("remind me to call mom") { TestSupport.expect(!list.contains { if case .remember = $0 { return true } else { return false } }, "reminder stolen") }
        ETest.eq(first("remember to call mom"), .unknown("remember to call mom"))
    }

    // MARK: Store

    private static func makeStore(_ directory: URL? = nil) -> (RioMemoryStore, URL) {
        let url = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("rio-memory-test-\(UUID().uuidString)", isDirectory: true)
        return (RioMemoryStore(directory: url, now: { Date(timeIntervalSince1970: 1_793_714_709) }), url)
    }

    private static func storeRoundTrip() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        ETest.eq(store.add("my locker code is 4321"), .added)
        ETest.eq(store.recall("locker code"), .facts(["my locker code is 4321"]))
        ETest.eq(store.add("my locker code is 4321"), .alreadyKnown)
        ETest.eq(store.add("my locker code is 1234"), .updated(previous: "my locker code is 4321"))
        ETest.eq(store.facts.count, 1)
        ETest.eq(store.recall("what's my locker code"), .facts(["my locker code is 1234"]))

        // A second store on the same folder sees the same facts, file is private JSON.
        let (again, _) = makeStore(url)
        ETest.eq(again.facts.map(\.text), ["my locker code is 1234"])
        let file = url.appendingPathComponent("memory.json")
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        ETest.eq((attributes?[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let json = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        ETest.eq(json?["version"] as? Int, 1)
        ETest.eq((json?["facts"] as? [[String: Any]])?.first?["text"] as? String, "my locker code is 1234")

        ETest.eq(store.forget("locker code"), .removed("my locker code is 1234"))
        ETest.eq(store.facts.count, 0)
        ETest.eq(store.forget("locker code"), .notFound)
        ETest.eq(RioMemoryStore(directory: url).facts.count, 0)
    }

    private static func storeMatching() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = store.add("my gym locker is 12")
        _ = store.add("my school locker is 34")
        _ = store.add("my wifi password is Blue-Sky 42")
        _ = store.add("I'm allergic to peanuts")
        ETest.eq(store.forget("locker"), .ambiguous(["my gym locker is 12", "my school locker is 34"]))
        ETest.eq(store.facts.count, 4, "ambiguous forget must delete nothing")
        ETest.eq(store.recall("gym locker"), .facts(["my gym locker is 12"]))
        ETest.eq(store.recall("wifi pasword"), .facts(["my wifi password is Blue-Sky 42"]))
        ETest.eq(store.recall("lokcer"), .facts(["my gym locker is 12", "my school locker is 34"]))
        ETest.eq(store.recall("what am I allergic to"), .facts(["I'm allergic to peanuts"]))
        ETest.eq(store.recall("favourite colour"), .none)
        ETest.eq(store.recall("the"), .none)
        if case .facts(let all) = store.recall(""), all.count == 4 {} else { TestSupport.expect(false, "empty query lists everything") }
        ETest.eq(store.forget("gym locker"), .removed("my gym locker is 12"))
        ETest.eq(store.facts.count, 3)
        store.removeAll()
        ETest.eq(store.facts.count, 0)
        ETest.eq(store.recall(""), .none)
    }

    private static func storeRobustness() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        ETest.eq(store.add("   "), .rejected)
        ETest.eq(store.add(String(repeating: "a", count: RioMemoryStore.maxFactLength + 1)), .rejected)
        ETest.eq(store.add("line one\nline two"), .added)
        ETest.eq(store.facts.first?.text, "line one line two", "facts are single line")
        for index in 0..<RioMemoryStore.maxFacts + 5 { _ = store.add("my item number \(index) is \(index)") }
        ETest.eq(store.facts.count, RioMemoryStore.maxFacts, "the store is capped")

        // A corrupt file loads as empty and doesn't crash; the next write repairs it.
        let (broken, brokenURL) = makeStore()
        defer { try? FileManager.default.removeItem(at: brokenURL) }
        try? FileManager.default.createDirectory(at: brokenURL, withIntermediateDirectories: true)
        try? Data("{ not json".utf8).write(to: brokenURL.appendingPathComponent("memory.json"))
        _ = broken
        let reloaded = RioMemoryStore(directory: brokenURL)
        ETest.eq(reloaded.facts.count, 0)
        ETest.eq(reloaded.add("my pin is 99"), .added)
        ETest.eq(RioMemoryStore(directory: brokenURL).facts.count, 1)
    }

    private static func secondPerson() {
        ETest.eq(RioMemoryVoice.secondPerson("my locker code is 4321"), "Your locker code is 4321")
        ETest.eq(RioMemoryVoice.secondPerson("I'm allergic to peanuts"), "You're allergic to peanuts")
        ETest.eq(RioMemoryVoice.secondPerson("I live in Davis"), "You live in Davis")
        ETest.eq(RioMemoryVoice.secondPerson("I am 20"), "You are 20")
        ETest.eq(RioMemoryVoice.secondPerson("Ali's number is 555"), "Ali's number is 555")
        ETest.eq(RioMemoryVoice.secondPerson("my mom's birthday is March 3"), "Your mom's birthday is March 3")
        ETest.eq(RioMemoryVoice.secondPerson("the key is under me"), "The key is under you")
        ETest.eq(RioMemoryVoice.recallSentence(["my locker code is 4321", "my pin is 99"]), "Your locker code is 4321. Your pin is 99.")
        ETest.eq(RioMemoryVoice.overview(["a one", "b two"]), "I remember 2 things. a one. b two.")
        ETest.eq(RioMemoryVoice.overview((1...8).map { "my fact \($0) is x" }).hasSuffix("and 3 more."), true)
    }
}
