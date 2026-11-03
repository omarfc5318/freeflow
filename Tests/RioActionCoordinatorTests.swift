import Foundation

/// Pure tests for the Rio action pipeline (parse, execute, shrug) with fake collaborators.
enum RioActionCoordinatorTests {
    private struct FakeParser: RioActionParsing {
        let result: RioActionParse
        func parse(_ transcript: String) -> RioActionParse { result }
    }

    /// Records every parsed string so name stripping can be checked.
    private final class RecordingParser: RioActionParsing, @unchecked Sendable {
        private(set) var received: [String] = []
        let result: RioActionParse
        init(result: RioActionParse) { self.result = result }
        func parse(_ transcript: String) -> RioActionParse {
            received.append(transcript)
            return result
        }
    }

    @MainActor private final class FakeExecutor: RioActionExecuting {
        var executed: [RioAction] = []
        var results: [RioActionResult]
        init(results: [RioActionResult]) { self.results = results }
        func execute(_ action: RioAction) async -> RioActionResult {
            executed.append(action)
            return results.isEmpty ? .done(summary: "ok") : results.removeFirst()
        }
    }

    private struct FakeResolver: RioSmartResolving {
        let actions: [RioAction]
        let shouldThrow: Bool
        func resolve(_ text: String) async throws -> [RioAction] {
            if shouldThrow { throw NSError(domain: "fake", code: 1) }
            return actions
        }
    }

    @MainActor static func run() async {
        testStripName()
        testWorkingText()
        await testRunsActionsInOrder()
        await testStopsAtFirstFailure()
        await testCancelledStops()
        await testUnknownWithoutResolverShrugs()
        await testUnknownUsesResolver()
        await testResolverFailureAndEmptyResult()
        await testEmptyDoesNothing()
        await testNameOnlyTranscriptDoesNothing()
        await testParserReceivesStrippedText()
        await testProgressIsReported()
    }

    private static func testStripName() {
        let cases: [(String, String)] = [
            ("Rio, open Chrome", "open Chrome"),
            ("rio open chrome.", "open chrome."),
            ("Yo Rio, open Chrome", "open Chrome"),
            ("yorio open chrome", "open chrome"),
            ("Hey Rio open Chrome", "open Chrome"),
            ("open Chrome", "open Chrome"),
            ("Open Chrome bro", "Open Chrome"),
            ("Rio open Chrome bro.", "open Chrome"),
            ("Ryo, lock my screen", "lock my screen"),
            ("Rio", ""),
            ("Rio.", ""),
            ("  ", ""),
            ("Riot police", "Riot police"),
            ("open Rio Grande", "open Rio Grande")
        ]
        for (input, expected) in cases {
            TestSupport.expectEqual(RioActionTranscript.stripName(from: input), expected)
        }
    }

    private static func testWorkingText() {
        TestSupport.expectEqual(RioActionText.working(for: .openApp(name: "Google Chrome")), "Opening Google Chrome")
        TestSupport.expectEqual(RioActionText.working(for: .quitApp(name: "Notes")), "Quitting Notes")
        TestSupport.expectEqual(RioActionText.working(for: .lockScreen), "Locking the screen")
        TestSupport.expectEqual(
            RioActionText.working(for: .window(WindowCommand(appName: "Warp", placement: .leftHalf))),
            "Arranging Warp"
        )
        TestSupport.expectEqual(
            RioActionText.working(for: .window(WindowCommand(appName: nil, placement: .center))),
            "Arranging the window"
        )
    }

    @MainActor private static func testRunsActionsInOrder() async {
        let actions: [RioAction] = [.openApp(name: "Chrome"), .openApp(name: "Spotify")]
        let executor = FakeExecutor(results: [.done(summary: "Opened Google Chrome"), .done(summary: "Opened Spotify")])
        let coordinator = RioActionCoordinator(parser: FakeParser(result: .actions(actions)), executor: executor)
        let outcome = await coordinator.run("open Chrome and Spotify")
        TestSupport.expectEqual(executor.executed, actions)
        TestSupport.expectEqual(outcome, .succeeded("Opened Google Chrome, Opened Spotify"))
    }

    @MainActor private static func testStopsAtFirstFailure() async {
        let actions: [RioAction] = [.openApp(name: "Crome"), .openApp(name: "Spotify")]
        let executor = FakeExecutor(results: [.failed(message: "I couldn't find an app called Crome")])
        let coordinator = RioActionCoordinator(parser: FakeParser(result: .actions(actions)), executor: executor)
        let outcome = await coordinator.run("open crome and spotify")
        TestSupport.expectEqual(executor.executed, [.openApp(name: "Crome")])
        TestSupport.expectEqual(outcome, .failed("I couldn't find an app called Crome"))
    }

    @MainActor private static func testCancelledStops() async {
        let executor = FakeExecutor(results: [.cancelled])
        let coordinator = RioActionCoordinator(
            parser: FakeParser(result: .actions([.lockScreen, .lockScreen])), executor: executor
        )
        let outcome = await coordinator.run("lock")
        TestSupport.expectEqual(executor.executed.count, 1)
        TestSupport.expectEqual(outcome, .cancelled)
    }

    @MainActor private static func testUnknownWithoutResolverShrugs() async {
        let executor = FakeExecutor(results: [])
        let coordinator = RioActionCoordinator(parser: FakeParser(result: .unknown("do a backflip")), executor: executor)
        let outcome = await coordinator.run("do a backflip")
        TestSupport.expectEqual(outcome, .unknown)
        TestSupport.expectEqual(executor.executed, [])
        TestSupport.expectEqual(RioActionText.unknownMessage, "I don't know how to do that yet")
    }

    @MainActor private static func testUnknownUsesResolver() async {
        let executor = FakeExecutor(results: [.done(summary: "Opened Notes")])
        let coordinator = RioActionCoordinator(
            parser: FakeParser(result: .unknown("jot something down")),
            executor: executor,
            smartResolver: FakeResolver(actions: [.openApp(name: "Notes")], shouldThrow: false)
        )
        let outcome = await coordinator.run("jot something down")
        TestSupport.expectEqual(executor.executed, [.openApp(name: "Notes")])
        TestSupport.expectEqual(outcome, .succeeded("Opened Notes"))
    }

    @MainActor private static func testResolverFailureAndEmptyResult() async {
        let executor = FakeExecutor(results: [])
        let throwing = RioActionCoordinator(
            parser: FakeParser(result: .unknown("x")), executor: executor,
            smartResolver: FakeResolver(actions: [], shouldThrow: true)
        )
        let result_throwing = await throwing.run("x")
        TestSupport.expectEqual(result_throwing, .failed(RioActionText.resolverFailedMessage))
        let empty = RioActionCoordinator(
            parser: FakeParser(result: .unknown("x")), executor: executor,
            smartResolver: FakeResolver(actions: [], shouldThrow: false)
        )
        let result_empty = await empty.run("x")
        TestSupport.expectEqual(result_empty, .unknown)
        TestSupport.expectEqual(executor.executed, [])
    }

    @MainActor private static func testEmptyDoesNothing() async {
        let executor = FakeExecutor(results: [])
        let coordinator = RioActionCoordinator(parser: FakeParser(result: .empty), executor: executor)
        let result_coordinator = await coordinator.run("uh")
        TestSupport.expectEqual(result_coordinator, .nothing)
        TestSupport.expectEqual(executor.executed, [])
    }

    @MainActor private static func testNameOnlyTranscriptDoesNothing() async {
        let parser = RecordingParser(result: .unknown("never"))
        let coordinator = RioActionCoordinator(parser: parser, executor: FakeExecutor(results: []))
        let result_coordinator = await coordinator.run("Rio.")
        TestSupport.expectEqual(result_coordinator, .nothing)
        TestSupport.expectEqual(parser.received, [])
    }

    @MainActor private static func testParserReceivesStrippedText() async {
        let parser = RecordingParser(result: .empty)
        let coordinator = RioActionCoordinator(parser: parser, executor: FakeExecutor(results: []))
        _ = await coordinator.run("Yo Rio, open Chrome bro")
        TestSupport.expectEqual(parser.received, ["open Chrome"])
    }

    @MainActor private static func testProgressIsReported() async {
        var messages: [String] = []
        let coordinator = RioActionCoordinator(
            parser: FakeParser(result: .actions([.openApp(name: "Notes"), .quitApp(name: "Notes")])),
            executor: FakeExecutor(results: [])
        )
        _ = await coordinator.run("open then quit notes") { messages.append($0) }
        TestSupport.expectEqual(messages, ["Opening Notes", "Quitting Notes"])
    }
}
